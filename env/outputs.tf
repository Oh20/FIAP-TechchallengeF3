terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
        source = "hashicorp/azurerm"
        version = "~>3.90.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-togglemaster-tfstate"
    storage_account_name = "attogglemastertfstate"
    container_name       = "tfstate"
    key                  = "togglemaster.terrafor.tfstate"
  }
}

provider "azurerm" {
  features {}
}