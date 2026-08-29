# Network Security Group
resource "azurerm_network_security_group" "this" {
  name                = var.nsg_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Regras declaradas em var.security_rules
resource "azurerm_network_security_rule" "this" {
  for_each = var.security_rules

  name                        = each.key
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
  description                 = each.value.description

  priority  = each.value.priority
  direction = each.value.direction
  access    = each.value.access
  protocol  = each.value.protocol

  source_port_range            = each.value.source_port_range
  destination_port_range       = each.value.destination_port_range
  destination_port_ranges      = each.value.destination_port_ranges
  source_address_prefix        = each.value.source_address_prefix
  source_address_prefixes      = each.value.source_address_prefixes
  destination_address_prefix   = each.value.destination_address_prefix
  destination_address_prefixes = each.value.destination_address_prefixes
}

# Associacao do NSG as subnets informadas
resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = toset(var.subnet_ids)

  subnet_id                 = each.value
  network_security_group_id = azurerm_network_security_group.this.id
}
