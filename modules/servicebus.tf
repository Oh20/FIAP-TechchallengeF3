###############################################################################
# Service Bus (mensageria)
#
# O evaluation-service publica os eventos de avaliacao e o analytics-service
# consome da mesma fila. O nome da fila precisa bater com o
# SERVICE_BUS_QUEUE_NAME dos ConfigMaps em ../../infra/base.
###############################################################################

resource "azurerm_servicebus_namespace" "sb" {
  name                = local.names.servicebus
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = var.servicebus_sku
  tags                = local.tags
}

resource "azurerm_servicebus_queue" "evaluations" {
  name         = var.servicebus_queue_name
  namespace_id = azurerm_servicebus_namespace.sb.id

  partitioning_enabled = false

  # O analytics-service so confirma a mensagem apos gravar no Cosmos DB;
  # ate la ela precisa continuar bloqueada para outro consumidor.
  lock_duration       = "PT1M"
  max_delivery_count  = 10
  default_message_ttl = "P14D"

  dead_lettering_on_message_expiration = true
}

# Chave de acesso dedicada a aplicacao, em vez da RootManageSharedAccessKey.
resource "azurerm_servicebus_namespace_authorization_rule" "app" {
  name         = "togglemaster-app"
  namespace_id = azurerm_servicebus_namespace.sb.id

  listen = true
  send   = true
  manage = false
}
