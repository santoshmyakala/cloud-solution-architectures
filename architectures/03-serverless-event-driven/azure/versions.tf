terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }
}

# Deployed into a workload ("online" landing zone) subscription.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
