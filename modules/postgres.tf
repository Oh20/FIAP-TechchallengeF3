###############################################################################
# PostgreSQL Flexible Server
#
# Um servidor por microsservico (auth, flag, targeting), como no diagrama.
# Acesso publico com firewall: os servicos conectam pelo FQDN com
# sslmode=require, que e o formato de DATABASE_URL esperado pelos Secrets do
# Kubernetes. Para fechar o acesso, troque por delegated_subnet_id + private DNS.
###############################################################################

resource "random_password" "postgres" {
  count = var.postgres_admin_password == "" ? 1 : 0

  length  = 28
  upper   = true
  lower   = true
  numeric = true
  special = true

  # Apenas caracteres seguros dentro de uma URL de conexao, evitando
  # percent-encoding na DATABASE_URL montada abaixo.
  override_special = "-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
}

resource "azurerm_postgresql_flexible_server" "postgres" {
  for_each = var.postgres_servers

  name                = "psql-${each.key}-${local.base}-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name

  # Pode divergir da regiao do Resource Group - ver local.postgres_location.
  location = local.postgres_location

  version                = each.value.version
  sku_name               = each.value.sku_name
  storage_mb             = each.value.storage_mb
  administrator_login    = var.postgres_admin_user
  administrator_password = local.postgres_admin_password

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  tags = local.tags

  lifecycle {
    # A zona e escolhida pelo Azure quando nao informada; nao tratar como drift.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  for_each = var.postgres_servers

  name      = each.value.database_name
  server_id = azurerm_postgresql_flexible_server.postgres[each.key].id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Libera os servicos do Azure (nodes do AKS saindo pelo load balancer).
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  for_each = var.postgres_servers

  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.postgres[each.key].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Regras extras (IP da equipe, agente de pipeline, etc.).
resource "azurerm_postgresql_flexible_server_firewall_rule" "extra" {
  for_each = {
    for pair in setproduct(keys(var.postgres_servers), keys(var.postgres_allowed_cidrs)) :
    "${pair[0]}-${pair[1]}" => {
      server = pair[0]
      rule   = pair[1]
      cidr   = var.postgres_allowed_cidrs[pair[1]]
    }
  }

  name      = each.value.rule
  server_id = azurerm_postgresql_flexible_server.postgres[each.value.server].id

  # Aceita tanto um IP unico quanto um CIDR.
  start_ip_address = cidrhost(each.value.cidr, 0)
  end_ip_address   = cidrhost(each.value.cidr, -1)
}
