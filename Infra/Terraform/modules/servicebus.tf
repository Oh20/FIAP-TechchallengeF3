# Azure Service Bus (Tópico / Fila de Eventos)
resource "azurerm_servicebus_namespace" "sb" {
  name                = var.servicebus-toggle-master
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "evaluations_queue" {
  name         = "evaluation-events"
  namespace_id = azurerm_servicebus_namespace.sb.id
}
