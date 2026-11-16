terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
  }
}

# Deployed into the connectivity subscription (CAF "connectivity" management group).
provider "azurerm" {
  features {}
  subscription_id = var.connectivity_subscription_id
}
