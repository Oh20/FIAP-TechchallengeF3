# IP publico opcional (usado apenas em homolog para acesso administrativo)
resource "azurerm_public_ip" "this" {
  count = var.enable_public_ip ? 1 : 0

  name                = "pip-${var.vm_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Interface de rede da VM
resource "azurerm_network_interface" "this" {
  name                = "nic-${var.vm_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = var.private_ip_address == null ? "Dynamic" : "Static"
    private_ip_address            = var.private_ip_address
    public_ip_address_id          = var.enable_public_ip ? azurerm_public_ip.this[0].id : null
  }
}

# Virtual Machine Linux
resource "azurerm_linux_virtual_machine" "this" {
  name                = var.vm_name
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.this.id]

  # Acesso exclusivamente por chave SSH
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "osdisk-${var.vm_name}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.source_image.publisher
    offer     = var.source_image.offer
    sku       = var.source_image.sku
    version   = var.source_image.version
  }

  custom_data = var.custom_data == null ? null : base64encode(var.custom_data)

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {} # Usa a storage gerenciada pelo Azure
}

# Discos de dados adicionais
resource "azurerm_managed_disk" "data" {
  for_each = var.data_disks

  name                 = "disk-${var.vm_name}-${each.key}"
  resource_group_name  = var.resource_group_name
  location             = var.location
  storage_account_type = each.value.storage_account_type
  create_option        = "Empty"
  disk_size_gb         = each.value.size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each = var.data_disks

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = each.value.lun
  caching            = each.value.caching
}
