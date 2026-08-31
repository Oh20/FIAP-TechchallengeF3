###############################################################################
# Outputs do modulo de plataforma
###############################################################################

output "resource_group_name" {
  description = "Resource Group do ambiente."
  value       = azurerm_resource_group.rg.name
}

output "location" {
  description = "Regiao do ambiente."
  value       = azurerm_resource_group.rg.location
}

###############################################################################
# AKS / ACR
###############################################################################

output "aks_cluster_name" {
  description = "Nome do cluster AKS (use com az aks get-credentials)."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "aks_node_resource_group" {
  description = "Resource Group gerenciado pelo AKS, onde vive o Application Gateway."
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "aks_oidc_issuer_url" {
  description = "Issuer OIDC do cluster, para federated credentials de workload identity."
  value       = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

output "aks_get_credentials_command" {
  description = "Comando pronto para configurar o kubectl."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
}

output "application_gateway_id" {
  description = "Application Gateway criado pelo addon AGIC e usado pelo Ingress."
  value       = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].effective_gateway_id
}

output "acr_login_server" {
  description = "Login server do ACR. Prefixo das imagens nos deployments."
  value       = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  description = "Nome do ACR (use com az acr login --name)."
  value       = azurerm_container_registry.acr.name
}

###############################################################################
# Dados
###############################################################################

output "postgres_fqdns" {
  description = "FQDN de cada Flexible Server, por microsservico."
  value       = { for k, s in azurerm_postgresql_flexible_server.postgres : k => s.fqdn }
}

output "postgres_server_names" {
  description = "Nome de cada Flexible Server (use com az postgres flexible-server start/stop)."
  value       = { for k, s in azurerm_postgresql_flexible_server.postgres : k => s.name }
}

output "postgres_admin_user" {
  description = "Usuario administrador do PostgreSQL."
  value       = var.postgres_admin_user
}

output "postgres_admin_password" {
  description = "Senha do administrador do PostgreSQL. Tambem gravada no Key Vault [APP CI]."
  value       = local.postgres_admin_password
  sensitive   = true
}

output "database_urls" {
  description = "DATABASE_URL de cada microsservico, no formato dos Secrets do Kubernetes."
  value       = local.postgres_urls
  sensitive   = true
}

output "cosmos_endpoint" {
  description = "COSMOS_ENDPOINT do analytics-service."
  value       = azurerm_cosmosdb_account.analytics.endpoint
}

output "cosmos_primary_key" {
  description = "COSMOS_KEY do analytics-service."
  value       = azurerm_cosmosdb_account.analytics.primary_key
  sensitive   = true
}

output "redis_hostname" {
  description = "Hostname do Azure Cache for Redis."
  value       = azurerm_redis_cache.evaluation.hostname
}

output "redis_url" {
  description = "REDIS_URL do evaluation-service, com a chave ja embutida."
  value       = local.redis_url
  sensitive   = true
}

###############################################################################
# Mensageria
###############################################################################

output "servicebus_namespace" {
  description = "Namespace do Service Bus."
  value       = azurerm_servicebus_namespace.sb.name
}

output "servicebus_queue_name" {
  description = "SERVICE_BUS_QUEUE_NAME usado pelos ConfigMaps."
  value       = azurerm_servicebus_queue.evaluations.name
}

output "servicebus_connection_string" {
  description = "SERVICE_BUS_CONNECTION_STRING (regra dedicada, sem permissao de manage)."
  value       = azurerm_servicebus_namespace_authorization_rule.app.primary_connection_string
  sensitive   = true
}

###############################################################################
# Key Vault e observabilidade
###############################################################################

output "key_vault_app_name" {
  description = "Key Vault [APP CI] - segredos consumidos pelos pods e pelo CD."
  value       = azurerm_key_vault.app.name
}

output "key_vault_app_uri" {
  description = "URI do Key Vault [APP CI]."
  value       = azurerm_key_vault.app.vault_uri
}

output "key_vault_infra_name" {
  description = "Key Vault [Infra CI/CD] - coordenadas do ambiente para o pipeline de infra."
  value       = azurerm_key_vault.infra.name
}

output "aks_secrets_provider_client_id" {
  description = "Client ID da identidade do CSI driver, para o SecretProviderClass."
  value       = azurerm_kubernetes_cluster.aks.key_vault_secrets_provider[0].secret_identity[0].client_id
}

output "log_analytics_workspace_id" {
  description = "Workspace ID (GUID) do Log Analytics."
  value       = azurerm_log_analytics_workspace.logs.workspace_id
}

output "observability_storage_account" {
  description = "Storage Account de observabilidade."
  value       = azurerm_storage_account.observability.name
}
