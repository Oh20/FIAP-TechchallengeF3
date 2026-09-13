###############################################################################
# AKS
#
# Um cluster com tres node pools, espelhando o diagrama:
#   systempool - componentes do proprio Kubernetes
#   apppool    - "AKS - App": os cinco microsservicos do ToggleMaster
#   cicdpool   - "AKS - CI/CD": Argo CD e agentes de pipeline
#
# Addons habilitados:
#   ingress_application_gateway - cria o Application Gateway + AGIC, que atende
#                                 o Ingress com a classe azure/application-gateway
#   key_vault_secrets_provider  - CSI driver para os pods lerem o Key Vault [APP CI]
#   oms_agent                   - envia logs e metricas ao Log Analytics
###############################################################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = local.names.aks
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  node_resource_group = local.names.aks_node_rg
  dns_prefix          = replace(local.base, "-", "")
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.aks_sku_tier

  # OIDC + workload identity permitem que o Argo CD e os microsservicos
  # autentiquem no Azure sem secret estatico.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true

  default_node_pool {
    name                         = "systempool"
    vm_size                      = var.system_node_pool.vm_size
    os_disk_size_gb              = var.system_node_pool.disk_gb
    vnet_subnet_id               = azurerm_subnet.aks.id
    enable_auto_scaling          = true
    node_count                   = var.system_node_pool.node_count
    min_count                    = var.system_node_pool.min_count
    max_count                    = var.system_node_pool.max_count
    only_critical_addons_enabled = var.app_node_pool.enabled

    # Necessario para trocar vm_size / disco sem destruir o cluster.
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
    service_cidr      = "10.30.0.0/16"
    dns_service_ip    = "10.30.0.10"
  }

  ingress_application_gateway {
    gateway_name = local.names.appgw
    subnet_id    = azurerm_subnet.appgw.id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "5m"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.logs.id
    msi_auth_for_monitoring_enabled = true
  }

  tags = local.tags

  lifecycle {
    # O autoscaler ajusta node_count em runtime; nao tratar como drift.
    ignore_changes = [
      default_node_pool[0].node_count,
    ]
  }
}

###############################################################################
# Node pool das aplicacoes (AKS - App)
###############################################################################

resource "azurerm_kubernetes_cluster_node_pool" "app" {
  count = var.app_node_pool.enabled ? 1 : 0

  name                  = "apppool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.app_node_pool.vm_size
  os_disk_size_gb       = var.app_node_pool.disk_gb
  vnet_subnet_id        = azurerm_subnet.aks.id
  mode                  = "User"
  enable_auto_scaling   = true
  node_count            = var.app_node_pool.node_count
  min_count             = var.app_node_pool.min_count
  max_count             = var.app_node_pool.max_count

  node_labels = {
    workload = "app"
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

###############################################################################
# Node pool de CI/CD (Argo CD e agentes)
#
# Recebe taint para que apenas cargas com a tolerancia correspondente sejam
# agendadas aqui - as aplicacoes continuam no apppool.
###############################################################################

resource "azurerm_kubernetes_cluster_node_pool" "cicd" {
  count = var.cicd_node_pool.enabled ? 1 : 0

  name                  = "cicdpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.cicd_node_pool.vm_size
  os_disk_size_gb       = var.cicd_node_pool.disk_gb
  vnet_subnet_id        = azurerm_subnet.aks.id
  mode                  = "User"
  enable_auto_scaling   = true
  node_count            = var.cicd_node_pool.node_count
  min_count             = var.cicd_node_pool.min_count
  max_count             = var.cicd_node_pool.max_count

  node_labels = {
    workload = "cicd"
  }

  node_taints = ["workload=cicd:NoSchedule"]

  tags = local.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

###############################################################################
# Permissoes das managed identities do cluster
###############################################################################

# O kubelet puxa imagens do ACR sem credencial estatica.
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

# O cluster precisa administrar as subnets (nodes e Application Gateway).
resource "azurerm_role_assignment" "aks_network_contributor" {
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
  role_definition_name = "Network Contributor"
  scope                = azurerm_virtual_network.vnet.id
}

# O AGIC gerencia o Application Gateway criado no node resource group.
resource "azurerm_role_assignment" "agic_node_rg_contributor" {
  principal_id         = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  role_definition_name = "Contributor"
  scope                = azurerm_kubernetes_cluster.aks.node_resource_group_id
}

# ...e precisa enxergar a subnet dedicada para publicar os listeners.
resource "azurerm_role_assignment" "agic_subnet_network_contributor" {
  principal_id         = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  role_definition_name = "Network Contributor"
  scope                = azurerm_subnet.appgw.id
}
