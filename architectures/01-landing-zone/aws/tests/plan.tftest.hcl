mock_provider "aws" {
  override_during = plan
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-north-1:111111111111:key/11111111-2222-3333-4444-555555555555" }
  }
  override_data {
    target = data.aws_organizations_organization.this
    values = { id = "o-abc123", roots = [{ id = "r-root", arn = "arn:aws:organizations::111111111111:root/o-abc123/r-root", name = "Root", policy_types = [] }] }
  }
  override_data {
    target = data.aws_iam_policy_document.trail_bucket
    values = { json = "{}" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111" }
  }
}

variables {
  trail_bucket_name = "example-org-trail"
}

run "structure_and_guardrails" {
  command = plan

  assert {
    condition     = length(aws_organizations_organizational_unit.top) == 5 && length(aws_organizations_organizational_unit.workloads) == 2
    error_message = "Expected 5 top-level OUs and Prod/NonProd under Workloads."
  }
  assert {
    condition     = aws_organizations_policy_attachment.scp["baseline:root"].target_id == "r-root"
    error_message = "The baseline SCP must be attached at the organisation root."
  }
  assert {
    condition     = length([for k, _ in aws_organizations_policy_attachment.scp : k if startswith(k, "region-restriction:")]) == 3
    error_message = "Region restriction must cover Workloads, Sandbox and Infrastructure."
  }
  assert {
    condition     = !contains(keys(aws_organizations_policy_attachment.scp), "region-restriction:Security")
    error_message = "Security OU is exempt from region restriction (security tooling may run in any region)."
  }
  assert {
    condition     = contains([for st in jsondecode(aws_organizations_policy.scp["baseline"].content).Statement : st.Sid], "RequireIMDSv2")
    error_message = "Baseline SCP must enforce IMDSv2."
  }
  assert {
    condition     = jsondecode(aws_organizations_policy.scp["region-restriction"].content).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"] == ["eu-north-1", "eu-west-1"]
    error_message = "Region restriction must use the allowed_regions variable."
  }
  assert {
    condition     = contains(jsondecode(aws_organizations_policy.scp["region-restriction"].content).Statement[0].NotAction, "iam:*")
    error_message = "Global services (IAM) must be exempt from region restriction."
  }
}

run "audit_trail" {
  command = plan

  assert {
    condition     = aws_cloudtrail.org.is_organization_trail && aws_cloudtrail.org.is_multi_region_trail && aws_cloudtrail.org.enable_log_file_validation
    error_message = "Organisation trail must be multi-region with log-file validation."
  }
  assert {
    condition     = aws_cloudtrail.org.kms_key_id == aws_kms_key.trail.arn && aws_kms_key.trail.enable_key_rotation
    error_message = "Audit logs must be encrypted with a rotating customer-managed key."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.trail.restrict_public_buckets
    error_message = "Trail bucket must block public access."
  }
}

run "rejects_empty_region_list" {
  command = plan
  variables {
    allowed_regions = []
  }
  expect_failures = [var.allowed_regions]
}
