locals {
  suffix = "${var.project}-${var.environment}"

  tags = merge(
    {
      project     = var.project
      environment = "homolog"
      managed_by  = "terraform"
      owner       = "squad-togglemaster"
    },
    var.extra_tags
  )
}

# Resource Group do ambiente de homologacao
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.suffix}"
  location = var.location
  tags     = local.tags
}

# Rede: VNet + subnets de aplicacao e dados
module "network" {
  source = "../../modules/network"

  vnet_name           = "vnet-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = var.vnet_address_space
  tags                = local.tags

  subnets = {
    "snet-app-${local.suffix}" = {
      address_prefixes = var.subnet_app_prefix
    }
    "snet-data-${local.suffix}" = {
      address_prefixes  = var.subnet_data_prefix
      service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
    }
  }
}

# NSG da subnet de aplicacao: SSH restrito + HTTP/HTTPS liberados
module "nsg_app" {
  source = "../../modules/nsg"

  nsg_name            = "nsg-app-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_ids          = [module.network.subnet_ids["snet-app-${local.suffix}"]]
  tags                = local.tags

  security_rules = {
    "allow-ssh-admin" = {
      description            = "SSH liberado apenas para a origem administrativa"
      priority               = 100
      direction              = "Inbound"
      access                 = "Allow"
      protocol               = "Tcp"
      destination_port_range = "22"
      source_address_prefix  = var.allowed_ssh_source
    }
    "allow-http-https" = {
      description             = "Trafego web da aplicacao em homologacao"
      priority                = 110
      direction               = "Inbound"
      access                  = "Allow"
      protocol                = "Tcp"
      destination_port_ranges = ["80", "443"]
      source_address_prefix   = "Internet"
    }
    "allow-vnet-inbound" = {
      description            = "Comunicacao interna entre as subnets do ambiente"
      priority               = 120
      direction              = "Inbound"
      access                 = "Allow"
      protocol               = "*"
      destination_port_range = "*"
      source_address_prefix  = "VirtualNetwork"
    }
    "deny-all-inbound" = {
      description                = "Bloqueio explicito do restante do trafego de entrada"
      priority                   = 4096
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}

# NSG da subnet de dados: acesso somente a partir da VNet
module "nsg_data" {
  source = "../../modules/nsg"

  nsg_name            = "nsg-data-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_ids          = [module.network.subnet_ids["snet-data-${local.suffix}"]]
  tags                = local.tags

  security_rules = {
    "allow-postgres-from-app" = {
      description            = "PostgreSQL acessivel apenas pela subnet de aplicacao"
      priority               = 100
      direction              = "Inbound"
      access                 = "Allow"
      protocol               = "Tcp"
      destination_port_range = "5432"
      source_address_prefix  = var.subnet_app_prefix[0]
    }
    "deny-all-inbound" = {
      description                = "Bloqueio explicito do restante do trafego de entrada"
      priority                   = 4096
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}

# VM de homologacao na subnet de aplicacao
module "vm_app" {
  source = "../../modules/vm"

  vm_name             = "vm-app-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = module.network.subnet_ids["snet-app-${local.suffix}"]
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
  enable_public_ip    = var.enable_public_ip
  os_disk_size_gb     = 32
  tags                = local.tags

  custom_data = <<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - docker.io
      - docker-compose
    runcmd:
      - systemctl enable --now docker
      - usermod -aG docker ${var.admin_username}
  CLOUDINIT

  # A VM so e criada depois que o NSG protege a subnet
  depends_on = [module.nsg_app]
}
