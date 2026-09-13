###############################################################################
# Azure Cache for Redis (evaluation-service)
#
# O evaluation-service consome REDIS_URL no formato rediss://:<chave>@<host>:6380
# (ver output redis_url em outputs.tf). Somente TLS: a porta 6379 fica fechada.
###############################################################################

resource "azurerm_redis_cache" "evaluation" {
  name                = local.names.redis
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku_name = var.redis.sku_name
  family   = var.redis.family
  capacity = var.redis.capacity

  non_ssl_port_enabled = false
  minimum_tls_version  = "1.2"

  redis_configuration {
    maxmemory_policy = "allkeys-lru"
  }

  tags = local.tags
}
