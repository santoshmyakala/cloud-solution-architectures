mock_provider "azurerm" {
  override_during = plan # resolve mocked computed values (firewall private IP) at plan time
  mock_resource "azurerm_firewall_policy" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/firewallPolicies/afwp-hub" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/publicIPAddresses/pip-afw-hub" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/networkSecurityGroups/nsg-mock" }
  }
  mock_resource "azurerm_route_table" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/routeTables/rt-mock" }
  }
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock" }
  }
  override_resource {
    target = azurerm_subnet.firewall
    values = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/AzureFirewallSubnet" }
  }
  mock_resource "azurerm_firewall" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.Network/azureFirewalls/afw-hub"
      ip_configuration = { private_ip_address = "10.100.0.4" }
    }
  }
}

variables {
  connectivity_subscription_id = "00000000-0000-0000-0000-000000000000"
}

run "forced_tunnelling_through_firewall" {
  command = plan

  assert {
    condition     = alltrue([for rt in azurerm_route_table.spoke : alltrue([for r in rt.route : r.next_hop_type == "VirtualAppliance" && r.next_hop_in_ip_address == "10.100.0.4"])])
    error_message = "Every spoke route must point at the firewall."
  }
  assert {
    condition     = alltrue([for rt in azurerm_route_table.spoke : length(rt.route) == 2])
    error_message = "Each spoke routes 0.0.0.0/0 plus the other spoke through the firewall."
  }
  assert {
    condition     = alltrue([for rt in azurerm_route_table.spoke : rt.bgp_route_propagation_enabled == false])
    error_message = "BGP propagation could bypass the firewall."
  }
  assert {
    condition     = alltrue([for s in azurerm_subnet.workload : s.default_outbound_access_enabled == false])
    error_message = "Implicit default outbound access must be disabled."
  }
}

run "firewall_posture" {
  command = plan

  assert {
    condition     = azurerm_firewall_policy.hub.threat_intelligence_mode == "Deny" && azurerm_firewall_policy.hub.intrusion_detection[0].mode == "Deny"
    error_message = "Threat intelligence and IDPS must block, not just alert."
  }
  assert {
    condition     = azurerm_firewall.hub.sku_tier == "Premium" && length(azurerm_firewall.hub.zones) == 3
    error_message = "Premium (IDPS) firewall across three zones."
  }
  assert {
    condition     = alltrue([for p in azurerm_virtual_network_peering.spoke_to_hub : p.allow_forwarded_traffic])
    error_message = "Peerings must allow forwarded traffic for the firewall to route return flows."
  }
}
