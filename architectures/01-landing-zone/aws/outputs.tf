output "organizational_units" {
  value = merge(
    { for k, ou in aws_organizations_organizational_unit.top : k => ou.id },
    { for k, ou in aws_organizations_organizational_unit.workloads : "Workloads/${k}" => ou.id },
  )
}

output "scp_ids" {
  value = { for k, p in aws_organizations_policy.scp : k => p.id }
}

output "trail_arn" {
  value = aws_cloudtrail.org.arn
}
