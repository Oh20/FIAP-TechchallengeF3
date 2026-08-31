###############################################################################
# Root module: backend remoto e configuracao dos providers.
#
# O Storage Account do state e criado pela pasta ../bootstrap, que roda com
# backend local. Ajuste os nomes abaixo se alterar o bootstrap.
#
# As credenciais do App Registration vem das variaveis ARM_* do ambiente -
# ver ./auth.tf. O backend le as mesmas variaveis que o provider, entao nao
# precisa de configuracao de credencial propria (blocos backend nao aceitam
# variaveis do Terraform de qualquer forma).
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

    # Le e grava o state com a identidade do Entra ID (o App Registration),
    # nao com a chave compartilhada da storage account. Exige
    # 'Storage Blob Data Contributor' - concedido em ../bootstrap.
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  use_oidc        = var.use_oidc

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
