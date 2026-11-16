variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "name" {
  type    = string
  default = "orders"
}

variable "max_receive_count" {
  description = "Delivery attempts before a message moves to the dead-letter queue."
  type        = number
  default     = 5
}
