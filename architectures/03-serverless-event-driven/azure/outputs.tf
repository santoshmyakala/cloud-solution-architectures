output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "orders_endpoint" {
  value = "https://${azurerm_function_app_flex_consumption.this.default_hostname}/api/orders"
}
