# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# Azure Container Registry
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
  admin_enabled       = false
  tags                = var.tags
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "togglemaster-k8s"

  default_node_pool {
    name                = "systempool"
    node_count          = 2
    vm_size             = "Standard_B2s" # Ajustável conforme carga/orçamento
    os_disk_size_gb     = 30
    vnet_subnet_id      = azurerm_subnet.aks_subnet.id
    enable_auto_scaling = true
    min_count           = 2
    max_count           = 4
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }

  tags = var.tags
}

# Permissão para o AKS puxar imagens do ACR sem credenciais estáticas
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

# Azure Service Bus (Tópico / Fila de Eventos)
resource "azurerm_servicebus_namespace" "sb" {
  name                = var.servicebus_namespace_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "evaluations_queue" {
  name         = "evaluation-events"
  namespace_id = azurerm_servicebus_namespace.sb.id
  enable_partitioning = false
}

# PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "postgres" {
  name                   = var.postgres_server_name
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = "15"
  administrator_login    = var.db_admin_user
  administrator_password = var.db_admin_password
  storage_mb             = 32768
  sku_name               = "B_Standard_B1ms"
  tags                   = var.tags
}

# Bancos de dados individuais para os microsserviços
resource "azurerm_postgresql_flexible_server_database" "auth_db" {
  name      = "auth_db"
  server_id = azurerm_postgresql_flexible_server.postgres.id
}

resource "azurerm_postgresql_flexible_server_database" "flag_db" {
  name      = "flag_db"
  server_id = azurerm_postgresql_flexible_server.postgres.id
}

resource "azurerm_postgresql_flexible_server_database" "targeting_db" {
  name      = "targeting_db"
  server_id = azurerm_postgresql_flexible_server.postgres.id
}