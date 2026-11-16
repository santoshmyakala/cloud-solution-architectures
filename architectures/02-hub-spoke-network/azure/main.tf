resource "azurerm_resource_group" "hub" {
  name     = "rg-connectivity-hub"
  location = var.location
  tags     = var.tags
}

# ------------------------------------------------------------------ hub
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = [var.hub_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet" # name required by Azure
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_cidr, 4, 0)]
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet" # reserved for a future VPN/ExpressRoute gateway
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_cidr, 5, 2)]
}

resource "azurerm_public_ip" "firewall" {
  name                = "pip-afw-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_firewall_policy" "hub" {
  name                     = "afwp-hub"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.hub.name
  sku                      = "Premium"
  threat_intelligence_mode = "Deny"
  intrusion_detection {
    mode = "Deny"
  }
  dns {
    proxy_enabled = true # lets FQDN rules work for network rules too
  }
  tags = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "egress"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 200

  application_rule_collection {
    name     = "allow-approved-fqdns"
    priority = 200
    action   = "Allow"
    rule {
      name              = "https-allowlist"
      source_addresses  = values(var.spokes)
      destination_fqdns = var.allowed_egress_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  network_rule_collection {
    name     = "allow-spoke-to-spoke-https"
    priority = 300
    action   = "Allow"
    rule {
      name                  = "east-west-https"
      protocols             = ["TCP"]
      source_addresses      = values(var.spokes)
      destination_addresses = values(var.spokes)
      destination_ports     = ["443"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  name                = "afw-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Premium"
  firewall_policy_id  = azurerm_firewall_policy.hub.id
  zones               = ["1", "2", "3"]
  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
  tags = var.tags
}

resource "azurerm_log_analytics_workspace" "network" {
  name                = "log-network-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                           = "afw-to-log-analytics"
  target_resource_id             = azurerm_firewall.hub.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.network.id
  log_analytics_destination_type = "Dedicated"
  enabled_log {
    category_group = "allLogs"
  }
}

# ------------------------------------------------------------------ spokes
resource "azurerm_resource_group" "spoke" {
  for_each = var.spokes
  name     = "rg-spoke-${each.key}"
  location = var.location
  tags     = merge(var.tags, { environment = each.key })
}

resource "azurerm_virtual_network" "spoke" {
  for_each            = var.spokes
  name                = "vnet-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  address_space       = [each.value]
  dns_servers         = [azurerm_firewall.hub.ip_configuration[0].private_ip_address] # firewall DNS proxy
  tags                = azurerm_resource_group.spoke[each.key].tags
}

resource "azurerm_subnet" "workload" {
  for_each                        = var.spokes
  name                            = "snet-workload"
  resource_group_name             = azurerm_resource_group.spoke[each.key].name
  virtual_network_name            = azurerm_virtual_network.spoke[each.key].name
  address_prefixes                = [cidrsubnet(each.value, 2, 0)]
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "workload" {
  for_each            = var.spokes
  name                = "nsg-${each.key}-workload"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  tags                = azurerm_resource_group.spoke[each.key].tags
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  for_each                  = var.spokes
  subnet_id                 = azurerm_subnet.workload[each.key].id
  network_security_group_id = azurerm_network_security_group.workload[each.key].id
}

# Force all spoke traffic (internet and east-west) through the firewall.
resource "azurerm_route_table" "spoke" {
  for_each                      = var.spokes
  name                          = "rt-${each.key}-via-firewall"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.spoke[each.key].name
  bgp_route_propagation_enabled = false
  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  }
  dynamic "route" {
    for_each = { for k, v in var.spokes : k => v if k != each.key }
    content {
      name                   = "to-${route.key}-via-firewall"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
    }
  }
  tags = azurerm_resource_group.spoke[each.key].tags
}

resource "azurerm_subnet_route_table_association" "workload" {
  for_each       = var.spokes
  subnet_id      = azurerm_subnet.workload[each.key].id
  route_table_id = azurerm_route_table.spoke[each.key].id
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each                  = var.spokes
  name                      = "hub-to-${each.key}"
  resource_group_name       = azurerm_resource_group.hub.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke[each.key].id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each                  = var.spokes
  name                      = "${each.key}-to-hub"
  resource_group_name       = azurerm_resource_group.spoke[each.key].name
  virtual_network_name      = azurerm_virtual_network.spoke[each.key].name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
  use_remote_gateways       = false
}
