output "vm_id" {
  description = "ID da Virtual Machine"
  value       = azurerm_linux_virtual_machine.this.id
}

output "vm_name" {
  description = "Nome da Virtual Machine"
  value       = azurerm_linux_virtual_machine.this.name
}

output "private_ip_address" {
  description = "IP privado da VM"
  value       = azurerm_network_interface.this.private_ip_address
}

output "public_ip_address" {
  description = "IP publico da VM (null quando enable_public_ip = false)"
  value       = var.enable_public_ip ? azurerm_public_ip.this[0].ip_address : null
}

output "principal_id" {
  description = "Object ID da identidade gerenciada da VM"
  value       = azurerm_linux_virtual_machine.this.identity[0].principal_id
}
