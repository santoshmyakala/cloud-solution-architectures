data "aws_organizations_organization" "this" {}

locals {
  root_id = data.aws_organizations_organization.this.roots[0].id

  # OU structure follows the AWS multi-account guidance (Security, Infrastructure, Workloads, Sandbox).
  top_level_ous = ["Security", "Infrastructure", "Workloads", "Sandbox", "Suspended"]
  workload_ous  = ["Prod", "NonProd"]
}

resource "aws_organizations_organizational_unit" "top" {
  for_each  = toset(local.top_level_ous)
  name      = each.key
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "workloads" {
  for_each  = toset(local.workload_ous)
  name      = each.key
  parent_id = aws_organizations_organizational_unit.top["Workloads"].id
}

# ------------------------------------------------------------------ guardrails (SCPs)
# SCPs are plain JSON built with jsonencode(): no provider round-trip, and tests can assert on content.
locals {
  scp_baseline = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "DenyLeavingOrganization", Effect = "Deny", Action = "organizations:LeaveOrganization", Resource = "*" },
      {
        Sid = "ProtectSecurityServices", Effect = "Deny", Resource = "*"
        Action = [
          "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
          "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount", "guardduty:UpdateDetector",
          "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
          "securityhub:DisableSecurityHub",
        ]
      },
      {
        Sid       = "DenyRootUser", Effect = "Deny", Action = "*", Resource = "*"
        Condition = { StringLike = { "aws:PrincipalArn" = "arn:aws:iam::*:root" } }
      },
      {
        Sid       = "RequireIMDSv2", Effect = "Deny", Action = "ec2:RunInstances", Resource = "arn:aws:ec2:*:*:instance/*"
        Condition = { StringNotEquals = { "ec2:MetadataHttpTokens" = "required" } }
      },
    ]
  })

  scp_region_restriction = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "DenyOutsideAllowedRegions", Effect = "Deny", Resource = "*"
      # Global services are exempt: they are served from us-east-1 regardless of where you work.
      NotAction = [
        "iam:*", "organizations:*", "sts:*", "route53:*", "route53domains:*", "cloudfront:*",
        "waf:*", "wafv2:*", "globalaccelerator:*", "support:*", "budgets:*", "ce:*", "health:*",
        "trustedadvisor:*", "account:*", "s3:GetBucketLocation", "s3:ListAllMyBuckets",
      ]
      Condition = { StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions } }
    }]
  })

  scp_deny_all = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Sid = "DenyAll", Effect = "Deny", Action = "*", Resource = "*" }]
  })
}

resource "aws_organizations_policy" "scp" {
  for_each = {
    baseline           = { doc = local.scp_baseline, desc = "Protect the organisation, root user and security services; require IMDSv2" }
    region-restriction = { doc = local.scp_region_restriction, desc = "Deny non-global actions outside the approved regions" }
    deny-all           = { doc = local.scp_deny_all, desc = "Quarantine for suspended accounts" }
  }
  name        = each.key
  description = each.value.desc
  type        = "SERVICE_CONTROL_POLICY"
  content     = each.value.doc
}

locals {
  attachments = merge(
    { "baseline:root" = { policy = "baseline", target = local.root_id } },
    { for ou in ["Workloads", "Sandbox", "Infrastructure"] : "region-restriction:${ou}" => {
      policy = "region-restriction", target = aws_organizations_organizational_unit.top[ou].id
    } },
    { "deny-all:Suspended" = { policy = "deny-all", target = aws_organizations_organizational_unit.top["Suspended"].id } },
  )
}

resource "aws_organizations_policy_attachment" "scp" {
  for_each  = local.attachments
  policy_id = aws_organizations_policy.scp[each.value.policy].id
  target_id = each.value.target
}

# ------------------------------------------------------------------ organisation-wide audit trail
resource "aws_s3_bucket" "trail" {
  bucket = var.trail_bucket_name
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration { status = "Enabled" }
}

# Customer-managed key for audit logs: key policy limits who can decrypt the organisation's trail.
resource "aws_kms_key" "trail" {
  description         = "Organization CloudTrail log encryption"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdmin", Effect = "Allow", Action = "kms:*", Resource = "*"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      },
      {
        Sid       = "CloudTrailEncrypt", Effect = "Allow", Action = ["kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Condition = { StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*" } }
      },
      {
        Sid       = "AuditorsDecrypt", Effect = "Allow", Action = ["kms:Decrypt", "kms:ReEncryptFrom"], Resource = "*"
        Principal = { AWS = "*" }
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = data.aws_organizations_organization.this.id }
          Null         = { "kms:EncryptionContext:aws:cloudtrail:arn" = "false" }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "trail" {
  name          = "alias/organization-trail"
  target_key_id = aws_kms_key.trail.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.trail.arn
    }
    bucket_key_enabled = true
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "AclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
  statement {
    sid     = "OrgWrite"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
      "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_organizations_organization.this.id}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

resource "aws_cloudtrail" "org" {
  name                          = "organization-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.trail.arn
  depends_on                    = [aws_s3_bucket_policy.trail]
}
