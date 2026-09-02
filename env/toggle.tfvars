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
# Standard_B2s NAO esta disponivel nesta subscription (Azure for Students):
# a familia B x86 nao e oferecida em eastus. Os unicos SKUs x64 de 2 vCPU sem
# restricao na regiao sao Standard_D2as_v7 e Standard_D2s_v7 - conferir com:
#
#   az vm list-skus -l eastus --size Standard_D2as_v7 --query "[].restrictions"
#
# Os *_v2 da lista que o Azure sugere no erro (b2ps_v2 etc.) sao ARM64 e
# exigiriam reconstruir as imagens dos microsservicos.
#
# Quota da subscription (az vm list-usage -l eastus):
#   Total Regional vCPUs       14
#   Standard Dasv7 Family      10   <- o teto que importa aqui
#
# Por isso os pools sao pequenos: 1 + 2 = 3 nodes = 6 vCPU no estado normal,
# com no maximo 2 + 3 = 5 nodes = 10 vCPU se o autoscaler subir tudo. Passar
# disso faz o autoscaler falhar em runtime, sem erro no terraform.
###############################################################################

aks_sku_tier = "Free"

system_node_pool = {
  vm_size    = "Standard_D2as_v7"
  node_count = 1
  min_count  = 1
  max_count  = 2
}

app_node_pool = {
  enabled    = true
  vm_size    = "Standard_D2as_v7"
  node_count = 2
  min_count  = 1
  max_count  = 3
}

# Desligado: o pool sobe com o taint workload=cicd:NoSchedule e nenhum manifesto
# em ../../infra declara a tolerancia correspondente - ou seja, nada seria
# agendado nele. O Argo CD roda no apppool. Ligue junto com os nodeSelector /
# tolerations nos manifestos, e so se houver quota sobrando.
cicd_node_pool = {
  enabled    = false
  vm_size    = "Standard_D2as_v7"
  node_count = 1
  min_count  = 1
  max_count  = 1
}

acr_sku = "Standard"

###############################################################################
# PostgreSQL
#
# Um servidor por microsservico. Os nomes de database batem com os
# secret.example.yaml de ../../infra/base.
###############################################################################

# PostgreSQL Flexible Server esta BLOQUEADO em eastus nesta subscription. A API
# de capabilities responde "Provisioning is restricted in this region", e o erro
# que chega no apply e enganoso: "The value of the 'Version' should be in: []".
# Nao adianta mudar version nem sku_name - a regiao inteira esta fechada.
#
# eastus2 e regiao par de eastus (latencia de poucos ms) e aceita Burstable +
# versao 16. Conferir antes de trocar:
#   az postgres flexible-server list-skus -l <regiao> --query "[0].reason"
postgres_location = "eastus2"

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
