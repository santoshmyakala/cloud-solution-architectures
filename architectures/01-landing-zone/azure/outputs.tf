output "management_groups" {
  value = merge(
    { root = azurerm_management_group.root.id },
    { for k, mg in azurerm_management_group.level1 : k => mg.id },
    { for k, mg in azurerm_management_group.level2 : k => mg.id },
  )
}

output "policy_assignments" {
  value = keys(azurerm_management_group_policy_assignment.this)
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.central.id
}
