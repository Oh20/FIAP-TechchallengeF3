# PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "postgres" {
  for_each = var.database-postgres

  name = "servidor-pg-${each.key}"
  resource_group_name = var.resource-group_toggle-master
  location = var.location

  version                = "15"                 
  storage_mb             = 32768                
  sku_name               = each.value.tamanho   
  administrator_login    = each.value.usuario   
  administrator_password = "Tonin@1234"         
}

resource "azurerm_postgresql_flexible_server_database" "postgres_db" {
  for_each = var.database-postgres

  name      = each.value.nome_bd
  server_id = azurerm_postgresql_flexible_server.postgres[each.key].id
  
  charset   = "utf8"
  collation = "en_US.utf8"
}

