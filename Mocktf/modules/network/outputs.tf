output "vnet_id" {
  description = "ID da Virtual Network"
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Nome da Virtual Network"
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Mapa nome da subnet => ID"
  value       = { for name, subnet in azurerm_subnet.this : name => subnet.id }
}
