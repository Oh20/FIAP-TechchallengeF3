###############################################################################
# Ambiente ToggleMaster
#
# terraform apply -var-file=toggle.tfvars
#
# Os nomes dos recursos sao derivados de project + environment; os que precisam
# ser unicos no Azure recebem o sufixo definido em name_suffix.
###############################################################################

###############################################################################
# Autenticacao
#
# As credenciais do App Registration vem do ambiente (ver ./auth.tf):
#   ARM_TENANT_ID / ARM_SUBSCRIPTION_ID / ARM_CLIENT_ID
#   ARM_CLIENT_SECRET   ou   ARM_USE_OIDC=true
#
# Descomente abaixo se preferir fixar tenant e subscription aqui. O client
# secret nunca entra neste arquivo - ele e versionado.
###############################################################################

# tenant_id       = "00000000-0000-0000-0000-000000000000"
# subscription_id = "00000000-0000-0000-0000-000000000000"

###############################################################################
# Identificacao
###############################################################################

project     = "togglemaster"
environment = "prod"
location    = "eastus"

# Sufixo dos recursos de nome global. Deixe vazio para gerar um aleatorio no
# primeiro apply; fixe um valor se quiser nomes previsiveis entre ambientes.
name_suffix = ""

tags = {
  projeto  = "toggle-master"
  ambiente = "prod"
  squad    = "fiap-tech-challenge-f3"
}

###############################################################################
# Rede
###############################################################################

vnet_address_space  = ["10.20.0.0/16"]
aks_subnet_prefix   = "10.20.0.0/20"
appgw_subnet_prefix = "10.20.16.0/24"

###############################################################################
# AKS
#
# Standard_B2s mantem o custo baixo para o laboratorio. Para uma carga real,
# troque por Standard_D2s_v5 e aks_sku_tier = "Standard".
###############################################################################

aks_sku_tier = "Free"

system_node_pool = {
  vm_size    = "Standard_B2s"
  node_count = 2
  min_count  = 2
  max_count  = 3
}

app_node_pool = {
  enabled    = true
  vm_size    = "Standard_B2s"
  node_count = 2
  min_count  = 2
  max_count  = 5
}

cicd_node_pool = {
  enabled    = true
  vm_size    = "Standard_B2s"
  node_count = 1
  min_count  = 1
  max_count  = 3
}

acr_sku = "Standard"

###############################################################################
# PostgreSQL
#
# Um servidor por microsservico. Os nomes de database batem com os
# secret.example.yaml de ../../infra/base.
###############################################################################

postgres_admin_user = "admintogglemaster"

# Deixe vazio: o Terraform gera a senha e a grava no Key Vault [APP CI].
postgres_admin_password = ""

postgres_servers = {
  auth = {
    database_name = "auth_db"
    sku_name      = "B_Standard_B1ms"
  }
  flag = {
    database_name = "flags_db"
    sku_name      = "B_Standard_B1ms"
  }
  targeting = {
    database_name = "targeting_db"
    sku_name      = "B_Standard_B1ms"
  }
}

# Libere o IP da equipe para rodar as migrations pelo psql, por exemplo:
# postgres_allowed_cidrs = {
#   "acesso-equipe" = "203.0.113.42/32"
# }
postgres_allowed_cidrs = {}

###############################################################################
# Cosmos DB (analytics-service)
###############################################################################

cosmos_database_name      = "ToggleMaster"
cosmos_container_name     = "ToggleMasterAnalytics"
cosmos_partition_key_path = "/flag_name"

###############################################################################
# Redis (evaluation-service)
###############################################################################

redis = {
  sku_name = "Basic"
  family   = "C"
  capacity = 0
}

###############################################################################
# Service Bus
###############################################################################

servicebus_sku        = "Standard"
servicebus_queue_name = "togglemasterqueue"

###############################################################################
# Observabilidade
###############################################################################

log_analytics_retention_days = 30

###############################################################################
# Key Vault
#
# O App Registration que roda o terraform NAO precisa entrar aqui: o modulo ja
# concede Key Vault Secrets Officer ao principal em execucao
# (data.azurerm_client_config.current). Esta lista e para quem NAO roda o
# terraform mas precisa ler ou gravar segredos - a equipe, e o App Registration
# do pipeline de aplicacao, se for outro.
#
#   az ad signed-in-user show --query id -o tsv
#   az ad sp show --id <application-client-id> --query id -o tsv
###############################################################################

key_vault_admin_object_ids         = []
key_vault_purge_protection_enabled = false
