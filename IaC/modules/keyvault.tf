###############################################################################
# Key Vault
#
# Dois cofres, como no diagrama:
#   [APP CI]   - segredos consumidos pelos pods (via CSI driver) e pelo pipeline
#                que renderiza os Secrets do Kubernetes para o Argo CD
#   [Infra CI] - coordenadas do ambiente consumidas pelo pipeline de infra
#
# Ambos usam RBAC (enable_rbac_authorization) em vez de access policies.
###############################################################################

resource "azurerm_key_vault" "app" {
  name                = local.names.key_vault_app
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization  = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  tags = local.tags
}

resource "azurerm_key_vault" "infra" {
  name                = local.names.key_vault_infra
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization  = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  tags = local.tags
}

###############################################################################
# Permissoes
###############################################################################

locals {
  key_vaults = {
    app   = azurerm_key_vault.app.id
    infra = azurerm_key_vault.infra.id
  }
}

# Quem roda o Terraform precisa poder gravar os segredos abaixo.
resource "azurerm_role_assignment" "kv_terraform" {
  for_each = local.key_vaults

  scope                = each.value
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Equipe e service connections declarados em var.key_vault_admin_object_ids.
resource "azurerm_role_assignment" "kv_admins" {
  for_each = {
    for pair in setproduct(keys(local.key_vaults), var.key_vault_admin_object_ids) :
    "${pair[0]}-${pair[1]}" => {
      vault_id  = local.key_vaults[pair[0]]
      object_id = pair[1]
    }
  }

  scope                = each.value.vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value.object_id
}

# Identidade do CSI driver do AKS: leitura apenas do cofre da aplicacao.
resource "azurerm_role_assignment" "kv_app_aks_csi" {
  scope                = azurerm_key_vault.app.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.aks.key_vault_secrets_provider[0].secret_identity[0].object_id
}

# A atribuicao de RBAC leva algum tempo para propagar; sem esta espera o
# primeiro apply costuma falhar ao gravar os segredos.
resource "time_sleep" "kv_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.kv_terraform]
  create_duration = "60s"
}

###############################################################################
# Segredos da aplicacao
###############################################################################

# Chave mestra do auth-service (MASTER_KEY) e chave de servico usada pelo
# evaluation-service para chamar os demais servicos (SERVICE_API_KEY).
resource "random_password" "master_key" {
  length  = 48
  special = false
}

resource "random_password" "service_api_key" {
  length  = 40
  special = false
}

locals {
  # DATABASE_URL de cada microsservico, no mesmo formato dos
  # secret.example.yaml em ../../infra/base.
  postgres_urls = {
    for key, server in var.postgres_servers :
    key => format(
      "postgres://%s:%s@%s:5432/%s?sslmode=require",
      var.postgres_admin_user,
      local.postgres_admin_password,
      azurerm_postgresql_flexible_server.postgres[key].fqdn,
      server.database_name,
    )
  }

  redis_url = format(
    "rediss://:%s@%s:%d",
    urlencode(azurerm_redis_cache.evaluation.primary_access_key),
    azurerm_redis_cache.evaluation.hostname,
    azurerm_redis_cache.evaluation.ssl_port,
  )

  app_secrets = merge(
    {
      for key, url in local.postgres_urls :
      "${key}-service-database-url" => url
    },
    {
      "postgres-admin-user"          = var.postgres_admin_user
      "postgres-admin-password"      = local.postgres_admin_password
      "redis-url"                    = local.redis_url
      "cosmos-endpoint"              = azurerm_cosmosdb_account.analytics.endpoint
      "cosmos-key"                   = azurerm_cosmosdb_account.analytics.primary_key
      "cosmos-database"              = var.cosmos_database_name
      "cosmos-container"             = var.cosmos_container_name
      "servicebus-connection-string" = azurerm_servicebus_namespace_authorization_rule.app.primary_connection_string
      "servicebus-queue-name"        = var.servicebus_queue_name
      "auth-master-key"              = random_password.master_key.result
      "evaluation-service-api-key"   = "tm_key_${random_password.service_api_key.result}"
    },
  )

  infra_secrets = {
    "acr-login-server"           = azurerm_container_registry.acr.login_server
    "acr-name"                   = azurerm_container_registry.acr.name
    "aks-cluster-name"           = azurerm_kubernetes_cluster.aks.name
    "aks-resource-group"         = azurerm_resource_group.rg.name
    "aks-oidc-issuer-url"        = azurerm_kubernetes_cluster.aks.oidc_issuer_url
    "log-analytics-workspace-id" = azurerm_log_analytics_workspace.logs.workspace_id
    "observability-storage-name" = azurerm_storage_account.observability.name
    "key-vault-app-name"         = azurerm_key_vault.app.name
  }
}

resource "azurerm_key_vault_secret" "app" {
  for_each = local.app_secrets

  name         = each.key
  value        = each.value
  key_vault_id = azurerm_key_vault.app.id
  content_type = "text/plain"
  tags         = local.tags

  depends_on = [time_sleep.kv_rbac_propagation]
}

resource "azurerm_key_vault_secret" "infra" {
  for_each = local.infra_secrets

  name         = each.key
  value        = each.value
  key_vault_id = azurerm_key_vault.infra.id
  content_type = "text/plain"
  tags         = local.tags

  depends_on = [time_sleep.kv_rbac_propagation]
}
