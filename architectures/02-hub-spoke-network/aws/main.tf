data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  # Inspection VPC subnets per AZ: /28 for TGW ENIs, /28 for firewall endpoints, /24 public (NAT).
  tgw_subnets      = [for i in range(var.az_count) : cidrsubnet(var.inspection_cidr, 12, i)]
  firewall_subnets = [for i in range(var.az_count) : cidrsubnet(var.inspection_cidr, 12, i + 16)]
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(var.inspection_cidr, 8, i + 10)]
}

# ------------------------------------------------------------------ Transit Gateway
resource "aws_ec2_transit_gateway" "this" {
  description                     = "hub"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "disable"
  tags                            = { Name = "tgw-hub" }
}

resource "aws_ec2_transit_gateway_route_table" "spokes" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "rt-spokes" }
}

resource "aws_ec2_transit_gateway_route_table" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "rt-inspection" }
}

# ------------------------------------------------------------------ inspection / egress VPC
resource "aws_vpc" "inspection" {
  cidr_block           = var.inspection_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "vpc-inspection" }
}

resource "aws_internet_gateway" "inspection" {
  vpc_id = aws_vpc.inspection.id
}

resource "aws_subnet" "tgw" {
  count             = var.az_count
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.tgw_subnets[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "inspection-tgw-${local.azs[count.index]}" }
}

resource "aws_subnet" "firewall" {
  count             = var.az_count
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.firewall_subnets[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "inspection-firewall-${local.azs[count.index]}" }
}

resource "aws_subnet" "public" {
  count             = var.az_count
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.public_subnets[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "inspection-public-${local.azs[count.index]}" }
}

resource "aws_eip" "nat" {
  count  = var.az_count
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  count         = var.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.inspection]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = aws_vpc.inspection.id
  subnet_ids                                      = aws_subnet.tgw[*].id
  appliance_mode_support                          = "enable" # keep both directions of a flow on the same AZ firewall
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "att-inspection" }
}

# ------------------------------------------------------------------ AWS Network Firewall
resource "aws_networkfirewall_rule_group" "egress_allowlist" {
  name     = "egress-domain-allowlist"
  type     = "STATEFUL"
  capacity = 100
  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets              = var.allowed_egress_domains
      }
    }
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set { definition = concat([var.inspection_cidr], values(var.spokes)) }
      }
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "this" {
  name = "hub-egress"
  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]
    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.egress_allowlist.arn
    }
  }
}

resource "aws_networkfirewall_firewall" "this" {
  name                = "hub-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this.arn
  vpc_id              = aws_vpc.inspection.id
  dynamic "subnet_mapping" {
    for_each = aws_subnet.firewall[*].id
    content { subnet_id = subnet_mapping.value }
  }
}

resource "aws_cloudwatch_log_group" "firewall" {
  name              = "/network-firewall/hub"
  retention_in_days = 90
}

resource "aws_networkfirewall_logging_configuration" "this" {
  firewall_arn = aws_networkfirewall_firewall.this.arn
  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = aws_cloudwatch_log_group.firewall.name }
    }
  }
}

locals {
  # Firewall endpoint per AZ, used to steer traffic symmetrically.
  firewall_endpoints = {
    for s in aws_networkfirewall_firewall.this.firewall_status[0].sync_states :
    s.availability_zone => s.attachment[0].endpoint_id
  }
}

# Routing inside the inspection VPC, per AZ:
#   TGW subnet      0.0.0.0/0   -> firewall endpoint
#   firewall subnet 0.0.0.0/0   -> NAT gateway;  spokes -> TGW
#   public subnet   0.0.0.0/0   -> IGW;          spokes -> firewall endpoint (return path)
resource "aws_route_table" "tgw" {
  count  = var.az_count
  vpc_id = aws_vpc.inspection.id
  route {
    cidr_block      = "0.0.0.0/0"
    vpc_endpoint_id = local.firewall_endpoints[local.azs[count.index]]
  }
}

resource "aws_route_table" "firewall" {
  count  = var.az_count
  vpc_id = aws_vpc.inspection.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
  dynamic "route" {
    for_each = var.spokes
    content {
      cidr_block         = route.value
      transit_gateway_id = aws_ec2_transit_gateway.this.id
    }
  }
}

resource "aws_route_table" "public" {
  count  = var.az_count
  vpc_id = aws_vpc.inspection.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.inspection.id
  }
  dynamic "route" {
    for_each = var.spokes
    content {
      cidr_block      = route.value
      vpc_endpoint_id = local.firewall_endpoints[local.azs[count.index]]
    }
  }
}

resource "aws_route_table_association" "tgw" {
  count          = var.az_count
  subnet_id      = aws_subnet.tgw[count.index].id
  route_table_id = aws_route_table.tgw[count.index].id
}

resource "aws_route_table_association" "firewall" {
  count          = var.az_count
  subnet_id      = aws_subnet.firewall[count.index].id
  route_table_id = aws_route_table.firewall[count.index].id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[count.index].id
}

# ------------------------------------------------------------------ spoke VPCs
resource "aws_vpc" "spoke" {
  for_each             = var.spokes
  cidr_block           = each.value
  enable_dns_hostnames = true
  tags                 = { Name = "vpc-${each.key}" }
}

resource "aws_subnet" "spoke" {
  for_each = { for pair in setproduct(keys(var.spokes), range(var.az_count)) : "${pair[0]}-${pair[1]}" => {
    spoke = pair[0], az = pair[1]
  } }
  vpc_id                  = aws_vpc.spoke[each.value.spoke].id
  cidr_block              = cidrsubnet(var.spokes[each.value.spoke], 4, each.value.az)
  availability_zone       = local.azs[each.value.az]
  map_public_ip_on_launch = false
  tags                    = { Name = "${each.value.spoke}-private-${local.azs[each.value.az]}" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  for_each                                        = var.spokes
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = aws_vpc.spoke[each.key].id
  subnet_ids                                      = [for k, s in aws_subnet.spoke : s.id if startswith(k, "${each.key}-")]
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "att-${each.key}" }
}

# Spokes have no internet gateway: all traffic, including spoke-to-spoke, goes to the TGW.
resource "aws_route_table" "spoke" {
  for_each = var.spokes
  vpc_id   = aws_vpc.spoke[each.key].id
  route {
    cidr_block         = "0.0.0.0/0"
    transit_gateway_id = aws_ec2_transit_gateway.this.id
  }
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}

resource "aws_route_table_association" "spoke" {
  for_each       = aws_subnet.spoke
  subnet_id      = each.value.id
  route_table_id = aws_route_table.spoke[split("-", each.key)[0]].id
}

# ------------------------------------------------------------------ TGW routing
# Spoke route table: everything -> inspection VPC (so east-west traffic is inspected too).
resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  for_each                       = var.spokes
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route" "spokes_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

# Inspection route table: knows every spoke, for return traffic after inspection.
resource "aws_ec2_transit_gateway_route_table_association" "inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spokes_to_inspection" {
  for_each                       = var.spokes
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}
