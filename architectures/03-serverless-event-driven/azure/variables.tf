variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "swedencentral"
}

variable "name" {
  description = "Base name; must be globally unique-ish (used for storage, Cosmos and Service Bus names)."
  type        = string
  default     = "orders"
  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name))
    error_message = "3-12 lowercase letters or digits."
  }
}

variable "tags" {
  type    = map(string)
  default = { owner = "orders-team", environment = "dev", costCenter = "orders" }
}
