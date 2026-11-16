# Management group hierarchy aligned with the Cloud Adoption Framework (CAF) enterprise-scale design.
resource "azurerm_management_group" "root" {
  name         = var.prefix
  display_name = upper(var.prefix)
}

locals {
  level1 = ["platform", "landingzones", "sandbox", "decommissioned"]
  level2 = {
    identity     = "platform"
    management   = "platform"
    connectivity = "platform"
    corp         = "landingzones"
    online       = "landingzones"
  }
}

resource "azurerm_management_group" "level1" {
  for_each                   = toset(local.level1)
  name                       = "${var.prefix}-${each.key}"
  display_name               = title(each.key)
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "level2" {
  for_each                   = local.level2
  name                       = "${var.prefix}-${each.key}"
  display_name               = title(each.key)
  parent_management_group_id = azurerm_management_group.level1[each.value].id
}

# ------------------------------------------------------------------ guardrails (Azure Policy)
locals {
  policies = {
    allowed-locations = {
      display = "Allowed locations"
      mode    = "Indexed"
      params  = { allowedLocations = { type = "Array", metadata = { displayName = "Allowed locations" } } }
      rule = {
        if = { allOf = [
          { field = "location", notIn = "[parameters('allowedLocations')]" },
          { field = "location", notEquals = "global" },
        ] }
        then = { effect = "deny" }
      }
    }
    require-rg-tags = {
      display = "Resource groups must carry the required tags"
      mode    = "All"
      params  = { tagNames = { type = "Array", metadata = { displayName = "Required tag names" } } }
      rule = {
        if = { allOf = [
          { field = "type", equals = "Microsoft.Resources/subscriptions/resourceGroups" },
          { count = { value = "[parameters('tagNames')]", name = "tag", where = {
            value = "[empty(field(concat('tags[', current('tag'), ']')))]", equals = true
          } }, greater = 0 },
        ] }
        then = { effect = "deny" }
      }
    }
    deny-public-ip = {
      display = "Deny public IP addresses"
      mode    = "All"
      params  = {}
      rule = {
        if   = { field = "type", equals = "Microsoft.Network/publicIPAddresses" }
        then = { effect = "deny" }
      }
    }
    secure-storage = {
      display = "Storage accounts must enforce HTTPS, TLS 1.2 and no anonymous blob access"
      mode    = "Indexed"
      params  = {}
      rule = {
        if = { allOf = [
          { field = "type", equals = "Microsoft.Storage/storageAccounts" },
          { anyOf = [
            { field = "Microsoft.Storage/storageAccounts/supportsHttpsTrafficOnly", equals = false },
            { field = "Microsoft.Storage/storageAccounts/minimumTlsVersion", notEquals = "TLS1_2" },
            { field = "Microsoft.Storage/storageAccounts/allowBlobPublicAccess", equals = true },
          ] },
        ] }
        then = { effect = "deny" }
      }
    }
    deny-all-resources = {
      display = "Deny all new resources (decommissioned subscriptions)"
      mode    = "All"
      params  = {}
      rule = {
        if   = { field = "type", like = "*" }
        then = { effect = "deny" }
      }
    }
  }

  # Where each guardrail applies, and with which parameters.
  assignments = {
    "allowed-locations@root"        = { policy = "allowed-locations", scope = azurerm_management_group.root.id, params = { allowedLocations = { value = var.allowed_locations } } }
    "secure-storage@root"           = { policy = "secure-storage", scope = azurerm_management_group.root.id, params = {} }
    "require-rg-tags@landingzones"  = { policy = "require-rg-tags", scope = azurerm_management_group.level1["landingzones"].id, params = { tagNames = { value = var.required_tags } } }
    "deny-public-ip@corp"           = { policy = "deny-public-ip", scope = azurerm_management_group.level2["corp"].id, params = {} }
    "deny-public-ip@identity"       = { policy = "deny-public-ip", scope = azurerm_management_group.level2["identity"].id, params = {} }
    "deny-all-resources@decommiss." = { policy = "deny-all-resources", scope = azurerm_management_group.level1["decommissioned"].id, params = {} }
  }
}

resource "azurerm_policy_definition" "this" {
  for_each            = local.policies
  name                = "${var.prefix}-${each.key}"
  display_name        = each.value.display
  policy_type         = "Custom"
  mode                = each.value.mode
  management_group_id = azurerm_management_group.root.id
  parameters          = length(each.value.params) > 0 ? jsonencode(each.value.params) : null
  policy_rule         = jsonencode(each.value.rule)
  metadata            = jsonencode({ category = "Landing Zone Guardrails" })
}

resource "azurerm_management_group_policy_assignment" "this" {
  for_each             = local.assignments
  name                 = substr(replace(each.key, "/[^a-zA-Z0-9-]/", "-"), 0, 24)
  display_name         = "${local.policies[each.value.policy].display} (${split("@", each.key)[1]})"
  management_group_id  = each.value.scope
  policy_definition_id = azurerm_policy_definition.this[each.value.policy].id
  parameters           = length(each.value.params) > 0 ? jsonencode(each.value.params) : null
}

# ------------------------------------------------------------------ central logging (management subscription)
resource "azurerm_resource_group" "management" {
  name     = "rg-${var.prefix}-management"
  location = var.allowed_locations[0]
  tags     = { owner = "platform-team", environment = "shared", costCenter = "platform" }
}

resource "azurerm_log_analytics_workspace" "central" {
  name                = "log-${var.prefix}-central"
  location            = azurerm_resource_group.management.location
  resource_group_name = azurerm_resource_group.management.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = azurerm_resource_group.management.tags
}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "activity-to-central-workspace"
  target_resource_id         = "/subscriptions/${var.management_subscription_id}"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id
  dynamic "enabled_log" {
    for_each = ["Administrative", "Security", "Policy", "Alert"]
    content { category = enabled_log.value }
  }
}
