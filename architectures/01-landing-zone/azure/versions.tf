terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# Run as a principal with Management Group Contributor + Resource Policy Contributor at tenant root.
provider "azurerm" {
  features {}
  subscription_id = var.management_subscription_id
}
