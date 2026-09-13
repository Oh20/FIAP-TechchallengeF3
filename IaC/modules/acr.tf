###############################################################################
# Azure Container Registry
#
# admin_enabled = false: o AKS puxa imagens pela managed identity do kubelet
# (role AcrPull em aks.tf) e o pipeline de CI autentica via OIDC/service
# connection. Nao ha usuario e senha estaticos no registry.
###############################################################################

resource "azurerm_container_registry" "acr" {
  name                = local.names.acr
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.acr_sku
  admin_enabled       = false
  tags                = local.tags
}
