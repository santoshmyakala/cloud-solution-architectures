variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "inspection_cidr" {
  description = "CIDR of the central inspection/egress VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "spokes" {
  description = "Workload VPCs attached to the Transit Gateway."
  type        = map(string)
  default = {
    prod    = "10.10.0.0/16"
    nonprod = "10.20.0.0/16"
  }
  validation {
    condition     = alltrue([for c in values(var.spokes) : can(cidrnetmask(c))])
    error_message = "Every spoke needs a valid IPv4 CIDR."
  }
}

variable "allowed_egress_domains" {
  description = "Outbound HTTPS destinations allowed through the firewall (TLS SNI match)."
  type        = list(string)
  default     = [".amazonaws.com", ".github.com", ".pypi.org", ".pythonhosted.org"]
}

variable "az_count" {
  type    = number
  default = 2
}
