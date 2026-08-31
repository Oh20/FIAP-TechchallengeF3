output "backend_config" {
  description = "Bloco backend correspondente ao que deve estar em ../env/providers.tf."

  value = {
    resource_group_name  = azurerm_resource_group.tfstate.name
    storage_account_name = azurerm_storage_account.tfstate.name
    container_name       = azurerm_storage_container.tfstate.name
    use_azuread_auth     = true
  }
}
