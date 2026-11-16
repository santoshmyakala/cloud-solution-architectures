mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.OperationalInsights/workspaces/log-orders" }
  }
  mock_resource "azurerm_application_insights" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.Insights/components/appi-orders", connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "azurerm_servicebus_namespace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.ServiceBus/namespaces/sb-orders" }
  }
  mock_resource "azurerm_servicebus_queue" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.ServiceBus/namespaces/sb-orders/queues/orders" }
  }
  mock_resource "azurerm_cosmosdb_account" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-orders", endpoint = "https://cosmos-orders.documents.azure.com:443/" }
  }
  mock_resource "azurerm_storage_account" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.Storage/storageAccounts/stordersfn", primary_blob_endpoint = "https://stordersfn.blob.core.windows.net/" }
  }
  mock_resource "azurerm_storage_container" {
    defaults = { id = "https://stordersfn.blob.core.windows.net/deployments" }
  }
  mock_resource "azurerm_service_plan" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.Web/serverFarms/asp-orders" }
  }
  mock_resource "azurerm_function_app_flex_consumption" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders/providers/Microsoft.Web/sites/func-orders"
      identity = { principal_id = "11111111-1111-1111-1111-111111111111", tenant_id = "22222222-2222-2222-2222-222222222222", type = "SystemAssigned", identity_ids = [] }
    }
  }
}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

run "identity_only_no_keys" {
  command = plan

  assert {
    condition     = azurerm_servicebus_namespace.this.local_auth_enabled == false && azurerm_cosmosdb_account.this.local_authentication_enabled == false
    error_message = "Service Bus and Cosmos DB must reject keys/SAS; Entra ID only."
  }
  assert {
    condition     = azurerm_storage_account.fn.shared_access_key_enabled == false && azurerm_function_app_flex_consumption.this.storage_authentication_type == "SystemAssignedIdentity"
    error_message = "Function storage must use managed identity, not account keys."
  }
  assert {
    condition     = alltrue([for k, v in azurerm_function_app_flex_consumption.this.app_settings : !can(regex("(?i)(AccountKey|SharedAccessKey)=", v))])
    error_message = "No connection strings with secrets in app settings."
  }
}

run "least_privilege_rbac" {
  command = plan

  assert {
    condition     = azurerm_role_assignment.fn["sb-send"].scope == azurerm_servicebus_queue.orders.id
    error_message = "Service Bus roles are scoped to the queue, not the namespace or subscription."
  }
  assert {
    condition     = endswith(azurerm_cosmosdb_sql_role_assignment.fn.scope, "/dbs/orders/colls/orders")
    error_message = "Cosmos DB data access is scoped to the single container."
  }
  assert {
    condition     = alltrue([for r in azurerm_role_assignment.fn : !contains(["Owner", "Contributor"], r.role_definition_name)])
    error_message = "No broad control-plane roles for the workload identity."
  }
}

run "reliability" {
  command = plan

  assert {
    condition     = azurerm_servicebus_queue.orders.max_delivery_count == 5
    error_message = "Messages dead-letter after 5 attempts (parity with the AWS design)."
  }
  assert {
    condition     = azurerm_cosmosdb_account.this.backup[0].type == "Continuous"
    error_message = "Continuous backup (point-in-time restore) is required."
  }
}
