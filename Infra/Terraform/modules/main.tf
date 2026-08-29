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

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource-group_toggle-master
  location = var.location
  tags     = var.tags
}

resource "azurerm_role_assignment" "aks_para_acr" {

  scope                = azurerm_container_registry.meu_acr.id
  

  role_definition_name = "AcrPull"
  
  principal_id         = azurerm_kubernetes_cluster.meu_aks.kubelet_identity[0].object_id
}