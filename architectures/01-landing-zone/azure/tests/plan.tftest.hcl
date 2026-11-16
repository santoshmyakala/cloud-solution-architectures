mock_provider "azurerm" {}

variables {
  management_subscription_id = "00000000-0000-0000-0000-000000000000"
}

run "hierarchy" {
  command = plan

  assert {
    condition     = length(azurerm_management_group.level1) == 4 && length(azurerm_management_group.level2) == 5
    error_message = "Expected the CAF hierarchy: 4 level-1 and 5 level-2 management groups."
  }
  assert {
    condition     = azurerm_management_group.level2["corp"].name == "contoso-corp"
    error_message = "Management group names must use the prefix."
  }
}

run "guardrails" {
  command = plan

  assert {
    condition     = length(azurerm_policy_definition.this) == 5
    error_message = "Expected five custom policy definitions."
  }
  assert {
    condition     = alltrue([for p in azurerm_policy_definition.this : jsondecode(p.policy_rule).then.effect == "deny"])
    error_message = "All guardrails are preventive (deny)."
  }
  assert {
    condition     = jsondecode(azurerm_management_group_policy_assignment.this["allowed-locations@root"].parameters).allowedLocations.value == ["swedencentral", "westeurope", "northeurope"]
    error_message = "Allowed locations must come from the variable."
  }
  assert {
    condition     = !contains(keys(azurerm_management_group_policy_assignment.this), "deny-public-ip@online")
    error_message = "Online landing zones may expose public endpoints; public IPs are only denied for corp and identity."
  }
  assert {
    condition     = alltrue([for a in azurerm_management_group_policy_assignment.this : length(a.name) <= 24])
    error_message = "Management-group policy assignment names are limited to 24 characters."
  }
}

run "central_logging" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.central.retention_in_days == 90
    error_message = "Default retention is 90 days."
  }
  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.activity_log.enabled_log) == 4
    error_message = "Activity log categories must be forwarded."
  }
}

run "rejects_bad_prefix" {
  command = plan
  variables {
    prefix = "Bad_Prefix!"
  }
  expect_failures = [var.prefix]
}
