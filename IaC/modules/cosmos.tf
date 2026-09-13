###############################################################################
# Cosmos DB (analytics-service)
#
# Conta SQL/Core em modo serverless: o analytics-service grava um documento por
# evento consumido da fila, com particao por flag_name.
###############################################################################

resource "azurerm_cosmosdb_account" "analytics" {
  name                = local.names.cosmos
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  # Carga esporadica e imprevisivel: serverless cobra por requisicao.
  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

  tags = local.tags
}

resource "azurerm_cosmosdb_sql_database" "analytics" {
  name                = var.cosmos_database_name
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.analytics.name
}

resource "azurerm_cosmosdb_sql_container" "analytics" {
  name                = var.cosmos_container_name
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.analytics.name
  database_name       = azurerm_cosmosdb_sql_database.analytics.name
  partition_key_path  = var.cosmos_partition_key_path

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/*"
    }
  }
}
