# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks-toggle-master
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "togglemaster-k8s"

  default_node_pool {
    name                = "systempool"
    node_count          = 2
    vm_size             = "Standard_B2s" # Ajustável conforme carga/orçamento
    os_disk_size_gb     = 30
    vnet_subnet_id      = azurerm_subnet.aks_subnet.id
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
