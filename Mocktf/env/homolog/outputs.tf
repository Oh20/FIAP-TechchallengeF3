output "resource_group_name" {
  description = "Resource Group do ambiente de homologacao"
  value       = azurerm_resource_group.rg.name
}

output "vnet_id" {
  description = "ID da VNet de homologacao"
  value       = module.network.vnet_id
}

output "subnet_ids" {
  description = "Mapa nome da subnet => ID"
  value       = module.network.subnet_ids
}

output "nsg_ids" {
  description = "IDs dos Network Security Groups"
  value = {
    app  = module.nsg_app.nsg_id
    data = module.nsg_data.nsg_id
  }
}

output "vm_private_ip" {
  description = "IP privado da VM de aplicacao"
  value       = module.vm_app.private_ip_address
}

output "vm_public_ip" {
  description = "IP publico da VM de aplicacao"
  value       = module.vm_app.public_ip_address
}

output "ssh_command" {
  description = "Comando pronto para acessar a VM"
  value       = var.enable_public_ip ? "ssh ${var.admin_username}@${module.vm_app.public_ip_address}" : "Sem IP publico. Acesse via bastion/VPN em ${module.vm_app.private_ip_address}"
}
