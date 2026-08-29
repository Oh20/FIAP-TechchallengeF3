resource "azurerm_container_registry" "acr_toggle_master" {
  name                = "acrmeuprojetofantastico" # Precisa ser único globalmente e apenas letras/numeros
  resource_group_name = var.resource-group_toggle-master
  location            = var.location
  
  sku                 = "Basic"
  admin_enabled       = false
  tags = var.tags
}