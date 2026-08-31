###############################################################################
# Root module: backend remoto e configuracao dos providers.
#
# O Storage Account do state e criado pela pasta ../bootstrap, que roda com
# backend local. Ajuste os nomes abaixo se alterar o bootstrap.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-togglemaster-tfstate"
    storage_account_name = "attogglemastertfstate"
    container_name       = "tfstate"
    key                  = "togglemaster.terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Em laboratorio, permite recriar cofres com o mesmo nome apos destroy.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
