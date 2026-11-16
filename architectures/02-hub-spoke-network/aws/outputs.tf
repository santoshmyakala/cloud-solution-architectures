output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.this.id
}

output "spoke_vpc_ids" {
  value = { for k, v in aws_vpc.spoke : k => v.id }
}

output "firewall_arn" {
  value = aws_networkfirewall_firewall.this.arn
}

output "firewall_endpoints_by_az" {
  description = "Firewall endpoint each AZ's traffic is steered through."
  value       = local.firewall_endpoints
}
