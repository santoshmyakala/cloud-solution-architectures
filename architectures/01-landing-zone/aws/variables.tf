variable "home_region" {
  description = "Region for the organisation trail bucket and regional resources."
  type        = string
  default     = "eu-north-1"
}

variable "allowed_regions" {
  description = "Regions workloads may use; everything else is denied by SCP (global services excepted)."
  type        = list(string)
  default     = ["eu-north-1", "eu-west-1"]

  validation {
    condition     = length(var.allowed_regions) > 0
    error_message = "At least one region must be allowed."
  }
}

variable "trail_bucket_name" {
  description = "Globally unique S3 bucket name for the organisation CloudTrail."
  type        = string
}
