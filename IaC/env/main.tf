###############################################################################
# Ambiente ToggleMaster
#
# Este root module apenas instancia o modulo de plataforma. Toda a definicao
# dos recursos vive em ../modules; os valores do ambiente vem de toggle.tfvars.
#
#   terraform init
#   terraform plan  -var-file=toggle.tfvars
#   terraform apply -var-file=toggle.tfvars
###############################################################################

module "togglemaster" {
  source = "../modules"

  project     = var.project
  environment = var.environment
  location    = var.location
  name_suffix = var.name_suffix
  tags        = var.tags

  # Rede
  vnet_address_space  = var.vnet_address_space
  aks_subnet_prefix   = var.aks_subnet_prefix
  appgw_subnet_prefix = var.appgw_subnet_prefix

  # AKS / ACR
  kubernetes_version = var.kubernetes_version
  aks_sku_tier       = var.aks_sku_tier
  system_node_pool   = var.system_node_pool
  app_node_pool      = var.app_node_pool
  cicd_node_pool     = var.cicd_node_pool
  acr_sku            = var.acr_sku

  # PostgreSQL
  postgres_location       = var.postgres_location
  postgres_servers        = var.postgres_servers
  postgres_admin_user     = var.postgres_admin_user
  postgres_admin_password = var.postgres_admin_password
  postgres_allowed_cidrs  = var.postgres_allowed_cidrs

  # Cosmos DB
  cosmos_database_name      = var.cosmos_database_name
  cosmos_container_name     = var.cosmos_container_name
  cosmos_partition_key_path = var.cosmos_partition_key_path

  # Redis
  redis = var.redis

  # Service Bus
  servicebus_sku        = var.servicebus_sku
  servicebus_queue_name = var.servicebus_queue_name

  # Observabilidade
  log_analytics_retention_days = var.log_analytics_retention_days

  # Key Vault
  key_vault_admin_object_ids           = var.key_vault_admin_object_ids
  key_vault_purge_protection_enabled   = var.key_vault_purge_protection_enabled
  key_vault_soft_delete_retention_days = var.key_vault_soft_delete_retention_days
}
