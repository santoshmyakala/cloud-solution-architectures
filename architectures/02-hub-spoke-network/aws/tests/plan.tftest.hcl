mock_provider "aws" {
  mock_resource "aws_networkfirewall_rule_group" {
    defaults = { arn = "arn:aws:network-firewall:eu-north-1:111111111111:stateful-rulegroup/egress-domain-allowlist" }
  }
  mock_resource "aws_networkfirewall_firewall_policy" {
    defaults = { arn = "arn:aws:network-firewall:eu-north-1:111111111111:firewall-policy/hub-egress" }
  }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["eu-north-1a", "eu-north-1b", "eu-north-1c"] }
  }
  override_resource {
    target = aws_networkfirewall_firewall.this
    values = {
      arn = "arn:aws:network-firewall:eu-north-1:111111111111:firewall/hub-firewall"
      firewall_status = [{
        sync_states = [
          { availability_zone = "eu-north-1a", attachment = [{ endpoint_id = "vpce-aaa", subnet_id = "subnet-a", status = "READY", status_message = "" }] },
          { availability_zone = "eu-north-1b", attachment = [{ endpoint_id = "vpce-bbb", subnet_id = "subnet-b", status = "READY", status_message = "" }] },
        ]
        capacity_usage_summary                 = []
        status                                 = "READY"
        configuration_sync_state_summary       = "IN_SYNC"
        transit_gateway_attachment_sync_states = []
      }]
    }
  }
}

run "spokes_have_no_internet_path" {
  command = plan

  assert {
    condition     = alltrue([for rt in aws_route_table.spoke : alltrue([for r in rt.route : r.gateway_id == null || r.gateway_id == ""])])
    error_message = "Spoke route tables must not route to an internet gateway."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.spoke : s.map_public_ip_on_launch == false])
    error_message = "Spoke subnets must be private."
  }
  assert {
    condition     = length(aws_subnet.spoke) == 4
    error_message = "Two spokes x two AZs = four subnets."
  }
}

run "all_traffic_is_inspected" {
  command = apply # offline against the mock provider, so computed firewall endpoints are resolved

  assert {
    condition     = aws_ec2_transit_gateway_route.spokes_default.destination_cidr_block == "0.0.0.0/0"
    error_message = "Spoke TGW route table must send everything (incl. east-west) to inspection."
  }
  assert {
    condition     = aws_ec2_transit_gateway.this.default_route_table_propagation == "disable"
    error_message = "Default TGW propagation would let spokes talk directly."
  }
  assert {
    condition     = aws_ec2_transit_gateway_vpc_attachment.inspection.appliance_mode_support == "enable"
    error_message = "Appliance mode keeps flows symmetric through one firewall endpoint."
  }
  assert {
    condition     = output.firewall_endpoints_by_az == { "eu-north-1a" = "vpce-aaa", "eu-north-1b" = "vpce-bbb" }
    error_message = "Each AZ must be steered through its own firewall endpoint."
  }
}

run "egress_is_allowlisted" {
  command = plan

  assert {
    condition     = aws_networkfirewall_rule_group.egress_allowlist.rule_group[0].rules_source[0].rules_source_list[0].generated_rules_type == "ALLOWLIST"
    error_message = "Egress must be an allowlist."
  }
}
