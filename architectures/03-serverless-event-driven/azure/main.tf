resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = var.tags
}


# ------------------------------------------------------------------ observability
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "other"
  tags                = var.tags
}

# ------------------------------------------------------------------ messaging + data (no local auth: Entra ID only)
resource "azurerm_servicebus_namespace" "this" {
  name                = "sb-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  local_auth_enabled  = false
  minimum_tls_version = "1.2"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "orders" {
  name                                 = "orders"
  namespace_id                         = azurerm_servicebus_namespace.this.id
  max_delivery_count                   = 5 # then dead-lettered
  dead_lettering_on_message_expiration = true
  lock_duration                        = "PT1M"
}

resource "azurerm_cosmosdb_account" "this" {
  name                         = "cosmos-${var.name}"
  location                     = var.location
  resource_group_name          = azurerm_resource_group.this.name
  offer_type                   = "Standard"
  kind                         = "GlobalDocumentDB"
  local_authentication_enabled = false
  capabilities {
    name = "EnableServerless"
  }
  consistency_policy {
    consistency_level = "Session"
  }
  geo_location {
    location          = var.location
    failover_priority = 0
  }
  backup {
    type = "Continuous"
    tier = "Continuous7Days"
  }
  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "orders" {
  name                = "orders"
  resource_group_name = azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this.name
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  name                = "orders"
  resource_group_name = azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this.name
  database_name       = azurerm_cosmosdb_sql_database.orders.name
  partition_key_paths = ["/id"]
}

# ------------------------------------------------------------------ Function App (Flex Consumption, identity-based storage)
resource "azurerm_storage_account" "fn" {
  name                            = "st${var.name}fn"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.this.name
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "deploy" {
  name                  = "deployments"
  storage_account_id    = azurerm_storage_account.fn.id
  container_access_type = "private"
}

resource "azurerm_service_plan" "fn" {
  name                = "asp-${var.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                        = "func-${var.name}"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.this.name
  service_plan_id             = azurerm_service_plan.fn.id
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.fn.primary_blob_endpoint}${azurerm_storage_container.deploy.name}"
  storage_authentication_type = "SystemAssignedIdentity"
  runtime_name                = "python"
  runtime_version             = "3.12"
  maximum_instance_count      = 40
  instance_memory_in_mb       = 2048
  https_only                  = true
  identity {
    type = "SystemAssigned"
  }
  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
    minimum_tls_version                    = "1.2"
  }
  app_settings = {
    ServiceBusConnection__fullyQualifiedNamespace = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
    CosmosDBConnection__accountEndpoint           = azurerm_cosmosdb_account.this.endpoint
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING     = "Authorization=AAD"
  }
  tags = var.tags
}

# ------------------------------------------------------------------ RBAC: the function's identity gets exactly what it needs
locals {
  fn_principal = azurerm_function_app_flex_consumption.this.identity[0].principal_id
  role_assignments = {
    deploy-storage = { scope = azurerm_storage_account.fn.id, role = "Storage Blob Data Owner" }
    sb-send        = { scope = azurerm_servicebus_queue.orders.id, role = "Azure Service Bus Data Sender" }
    sb-receive     = { scope = azurerm_servicebus_queue.orders.id, role = "Azure Service Bus Data Receiver" }
    monitoring     = { scope = azurerm_application_insights.this.id, role = "Monitoring Metrics Publisher" }
  }
}

resource "azurerm_role_assignment" "fn" {
  for_each             = local.role_assignments
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = local.fn_principal
}

# Cosmos DB data-plane RBAC (built-in "Cosmos DB Built-in Data Contributor"), scoped to one container.
resource "azurerm_cosmosdb_sql_role_assignment" "fn" {
  resource_group_name = azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this.name
  role_definition_id  = "${azurerm_cosmosdb_account.this.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = local.fn_principal
  scope               = "${azurerm_cosmosdb_account.this.id}/dbs/${azurerm_cosmosdb_sql_database.orders.name}/colls/${azurerm_cosmosdb_sql_container.orders.name}"
}

resource "azurerm_monitor_metric_alert" "dead_letters" {
  name                = "alert-${var.name}-dead-letters"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_servicebus_namespace.this.id]
  description         = "Orders were dead-lettered after 5 delivery attempts."
  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 0
    dimension {
      name     = "EntityName"
      operator = "Include"
      values   = ["orders"]
    }
  }
  tags = var.tags
}
