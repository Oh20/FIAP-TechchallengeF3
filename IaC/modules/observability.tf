###############################################################################
# Observabilidade
#
# Log Analytics recebe logs e metricas do AKS (addon oms_agent) e o Storage
# Account guarda os logs de longo prazo / exportacoes, conforme o bloco
# "StorageAccount [Observabilidade]" do diagrama.
###############################################################################

resource "azurerm_log_analytics_workspace" "logs" {
  name                = local.names.log_analytics
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.tags
}

resource "azurerm_storage_account" "observability" {
  name                            = local.names.storage_observ
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }
}

# Container onde o cluster e os pipelines despejam artefatos de observabilidade
# (dumps de log, relatorios de teste de carga, evidencias de execucao).
resource "azurerm_storage_container" "observability" {
  name                  = "observabilidade"
  storage_account_name  = azurerm_storage_account.observability.name
  container_access_type = "private"
}

# Logs do control plane do AKS -> Log Analytics + arquivamento no Storage.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "diag-aks"
  target_resource_id         = azurerm_kubernetes_cluster.aks.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  storage_account_id         = azurerm_storage_account.observability.id

  enabled_log {
    category = "kube-apiserver"
  }

  enabled_log {
    category = "kube-controller-manager"
  }

  enabled_log {
    category = "kube-audit-admin"
  }

  enabled_log {
    category = "cluster-autoscaler"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
