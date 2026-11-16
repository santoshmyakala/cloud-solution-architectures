variable "prefix" {
  description = "Short organisation prefix used for management group names."
  type        = string
  default     = "contoso"
  validation {
    condition     = can(regex("^[a-z0-9-]{2,10}$", var.prefix))
    error_message = "Use 2-10 lowercase letters, digits or hyphens."
  }
}

variable "management_subscription_id" {
  description = "Subscription that hosts shared management resources (Log Analytics)."
  type        = string
}

variable "allowed_locations" {
  type    = list(string)
  default = ["swedencentral", "westeurope", "northeurope"]
}

variable "required_tags" {
  description = "Tags every resource group in a landing zone must carry."
  type        = list(string)
  default     = ["owner", "environment", "costCenter"]
}

variable "log_retention_days" {
  type    = number
  default = 90
}
