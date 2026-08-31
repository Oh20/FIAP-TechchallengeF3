###############################################################################
# Bootstrap do backend remoto
#
# Cria o Resource Group e o Storage Account que guardam o state do ambiente
# (bloco "StorageAccount [TFState]" do diagrama). Roda com backend local,
# porque e o que constroi o backend remoto.
#
#   cd bootstrap
#   terraform init
#   terraform apply
#
# Autentica com as mesmas variaveis ARM_* de ../env - ver ./auth.tf.
#
# Rode este bootstrap COM O PROPRIO App Registration sempre que puder: o
# principal que executa recebe 'Storage Blob Data Contributor' automaticamente
# (azurerm_role_assignment.tfstate_current abaixo). Se rodar com um usuario via
# az login, coloque o object ID do App Registration em
# state_contributor_object_ids, senao o pipeline nao consegue gravar o state.
#
# O state deste diretorio (terraform.tfstate) e pequeno e so muda quando o
# backend muda; guarde-o no repositorio ou recrie com terraform import.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  use_oidc        = var.use_oidc

  # Cria o container com a identidade do Entra ID em vez da chave da conta.
  # E o que permite manter shared_access_key_enabled = false.
  storage_use_azuread = true

  features {}
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"

  # O state guarda a senha do PostgreSQL, a chave do Cosmos e a connection
  # string do Service Bus em texto claro. Com a chave compartilhada
  # desabilitada, o unico caminho de acesso e o RBAC concedido abaixo.
  shared_access_key_enabled       = var.shared_access_key_enabled
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_name  = azurerm_storage_account.tfstate.name
  container_access_type = "private"

  # Sem a espera, o primeiro apply falha com AuthorizationPermissionMismatch:
  # a role assignment existe no ARM mas ainda nao propagou para o data plane.
  depends_on = [time_sleep.rbac_propagation]
}

###############################################################################
# Quem pode ler e gravar o state
###############################################################################

# Quem esta rodando este bootstrap - o App Registration, se o pipeline o executa.
resource "azurerm_role_assignment" "tfstate_current" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# App Registration e equipe, quando o bootstrap nao roda com a identidade deles.
resource "azurerm_role_assignment" "tfstate_contributors" {
  for_each = toset(var.state_contributor_object_ids)

  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

resource "time_sleep" "rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.tfstate_current,
    azurerm_role_assignment.tfstate_contributors,
  ]

  create_duration = var.rbac_propagation_delay
}
