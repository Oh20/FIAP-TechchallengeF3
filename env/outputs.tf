###############################################################################
# Outputs do ambiente
#
# Os valores sensiveis nao aparecem no terminal. Para le-los:
#   terraform output -json database_urls
#   terraform output -raw redis_url
#
# Todos tambem ficam disponiveis no Key Vault [APP CI], que e a fonte
# recomendada para o pipeline que gera os Secrets do Kubernetes.
###############################################################################

output "resource_group_name" {
  description = "Resource Group do ambiente."
  value       = module.togglemaster.resource_group_name
}

output "aks_cluster_name" {
  description = "Nome do cluster AKS."
  value       = module.togglemaster.aks_cluster_name
}

output "aks_get_credentials_command" {
  description = "Comando para configurar o kubectl neste cluster."
  value       = module.togglemaster.aks_get_credentials_command
}

output "aks_node_resource_group" {
  description = "Resource Group gerenciado do AKS (onde fica o Application Gateway)."
  value       = module.togglemaster.aks_node_resource_group
}

output "aks_oidc_issuer_url" {
  description = "Issuer OIDC do cluster, para workload identity."
  value       = module.togglemaster.aks_oidc_issuer_url
}

output "aks_secrets_provider_client_id" {
  description = "Client ID da identidade do CSI driver do Key Vault."
  value       = module.togglemaster.aks_secrets_provider_client_id
}

output "application_gateway_id" {
  description = "Application Gateway do AGIC que atende o Ingress."
  value       = module.togglemaster.application_gateway_id
}

output "acr_login_server" {
  description = "Login server do ACR. Use como prefixo das imagens nos deployments."
  value       = module.togglemaster.acr_login_server
}

output "acr_name" {
  description = "Nome do ACR."
  value       = module.togglemaster.acr_name
}

output "postgres_server_names" {
  description = "Nome de cada Flexible Server, por microsservico."
  value       = module.togglemaster.postgres_server_names
}

output "postgres_fqdns" {
  description = "FQDN de cada Flexible Server, por microsservico."
  value       = module.togglemaster.postgres_fqdns
}

output "postgres_admin_user" {
  description = "Usuario administrador do PostgreSQL."
  value       = module.togglemaster.postgres_admin_user
}

output "postgres_admin_password" {
  description = "Senha do administrador do PostgreSQL."
  value       = module.togglemaster.postgres_admin_password
  sensitive   = true
}

output "database_urls" {
  description = "DATABASE_URL de cada microsservico."
  value       = module.togglemaster.database_urls
  sensitive   = true
}

output "cosmos_endpoint" {
  description = "COSMOS_ENDPOINT do analytics-service."
  value       = module.togglemaster.cosmos_endpoint
}

output "cosmos_primary_key" {
  description = "COSMOS_KEY do analytics-service."
  value       = module.togglemaster.cosmos_primary_key
  sensitive   = true
}

output "redis_hostname" {
  description = "Hostname do Redis."
  value       = module.togglemaster.redis_hostname
}

output "redis_url" {
  description = "REDIS_URL do evaluation-service."
  value       = module.togglemaster.redis_url
  sensitive   = true
}

output "servicebus_namespace" {
  description = "Namespace do Service Bus."
  value       = module.togglemaster.servicebus_namespace
}

output "servicebus_queue_name" {
  description = "Nome da fila de eventos."
  value       = module.togglemaster.servicebus_queue_name
}

output "servicebus_connection_string" {
  description = "SERVICE_BUS_CONNECTION_STRING dos servicos."
  value       = module.togglemaster.servicebus_connection_string
  sensitive   = true
}

output "key_vault_app_name" {
  description = "Key Vault [APP CI]."
  value       = module.togglemaster.key_vault_app_name
}

output "key_vault_app_uri" {
  description = "URI do Key Vault [APP CI]."
  value       = module.togglemaster.key_vault_app_uri
}

output "key_vault_infra_name" {
  description = "Key Vault [Infra CI/CD]."
  value       = module.togglemaster.key_vault_infra_name
}

output "log_analytics_workspace_id" {
  description = "Workspace ID do Log Analytics."
  value       = module.togglemaster.log_analytics_workspace_id
}

output "observability_storage_account" {
  description = "Storage Account de observabilidade."
  value       = module.togglemaster.observability_storage_account
}
