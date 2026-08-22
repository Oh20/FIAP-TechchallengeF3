output "nsg_id" {
  description = "ID do Network Security Group"
  value       = azurerm_network_security_group.this.id
}

output "nsg_name" {
  description = "Nome do Network Security Group"
  value       = azurerm_network_security_group.this.name
}
