terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Run with credentials for the AWS Organizations management account.
provider "aws" {
  region = var.home_region
  default_tags {
    tags = { ManagedBy = "terraform", Architecture = "landing-zone" }
  }
}
