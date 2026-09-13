###############################################################################
# Naming, contexto e Resource Group
#
# Todos os nomes derivam de project + environment. Recursos com nome
# globalmente unico no Azure (ACR, Key Vault, Storage, Cosmos, Service Bus,
# Redis, PostgreSQL) ganham um sufixo curto para evitar colisao.
###############################################################################

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result

  # base com hifen, para recursos que aceitam hifen
  base = "${var.project}-${var.environment}"

  # base sem separador, para recursos que so aceitam alfanumerico
  base_compact = "${var.project}${var.environment}"

  # Key Vault aceita no maximo 24 caracteres e Storage Account 24 sem hifen;
  # encurtar o projeto aqui garante que o nome nunca precise ser truncado
  # (o que poderia deixa-lo terminando em hifen ou comer o sufixo unico).
  project_kv = substr(var.project, 0, 12)
  project_st = substr(var.project, 0, 8)

  names = {
    resource_group  = "rg-${local.base}"
    vnet            = "vnet-${local.base}"
    aks_subnet      = "snet-${local.base}-aks"
    appgw_subnet    = "snet-${local.base}-appgw"
    aks             = "aks-${local.base}"
    aks_node_rg     = "rg-${local.base}-aks-nodes"
    appgw           = "agw-${local.base}"
    acr             = substr("acr${local.base_compact}${local.suffix}", 0, 50)
    log_analytics   = "log-${local.base}"
    storage_observ  = "st${local.project_st}${var.environment}obs${local.suffix}"
    key_vault_app   = "kv-${local.project_kv}-app-${local.suffix}"
    key_vault_infra = "kv-${local.project_kv}-inf-${local.suffix}"
    cosmos          = "cosmos-${local.base}-${local.suffix}"
    servicebus      = "sb-${local.base}-${local.suffix}"
    redis           = "redis-${local.base}-${local.suffix}"
  }

  tags = merge(
    {
      projeto    = var.project
      ambiente   = var.environment
      gerenciado = "terraform"
    },
    var.tags,
  )

  # Regiao do PostgreSQL. Normalmente e a do ambiente; vira outra quando a
  # subscription bloqueia o provisionamento de Flexible Server na regiao
  # principal (ver var.postgres_location).
  postgres_location = var.postgres_location != "" ? var.postgres_location : var.location

  # Senha do admin do PostgreSQL: usa a informada ou a gerada.
  postgres_admin_password = var.postgres_admin_password != "" ? var.postgres_admin_password : random_password.postgres[0].result
}

resource "azurerm_resource_group" "rg" {
  name     = local.names.resource_group
  location = var.location
  tags     = local.tags
}
