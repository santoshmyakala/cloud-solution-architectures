variable "connectivity_subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "swedencentral"
}

variable "hub_cidr" {
  type    = string
  default = "10.100.0.0/22"
}

variable "spokes" {
  type = map(string)
  default = {
    prod    = "10.110.0.0/22"
    nonprod = "10.120.0.0/22"
  }
  validation {
    condition     = alltrue([for c in values(var.spokes) : can(cidrnetmask(c))])
    error_message = "Every spoke needs a valid IPv4 CIDR."
  }
}

variable "allowed_egress_fqdns" {
  type    = list(string)
  default = ["*.github.com", "pypi.org", "*.pythonhosted.org", "mcr.microsoft.com", "*.data.mcr.microsoft.com"]
}

variable "tags" {
  type    = map(string)
  default = { owner = "platform-team", environment = "shared", costCenter = "network" }
}
