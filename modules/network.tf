###############################################################################
# Rede
#
# Uma VNet com duas subnets: nodes do AKS e Application Gateway (AGIC).
# O Application Gateway exige uma subnet dedicada, sem outros recursos.
###############################################################################

resource "azurerm_virtual_network" "vnet" {
  name                = local.names.vnet
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = local.names.aks_subnet
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.aks_subnet_prefix]

  # Permite que os nodes alcancem PostgreSQL, Redis, Cosmos e Service Bus
  # pela backbone do Azure em vez de sair pela internet publica.
  service_endpoints = [
    "Microsoft.Sql",
    "Microsoft.AzureCosmosDB",
    "Microsoft.ServiceBus",
    "Microsoft.KeyVault",
    "Microsoft.Storage",
  ]
}

resource "azurerm_subnet" "appgw" {
  name                 = local.names.appgw_subnet
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.appgw_subnet_prefix]
}

###############################################################################
# NSG dos nodes
#
# O trafego de entrada chega pelo Application Gateway, entao a subnet do AKS
# so precisa aceitar o que vem da subnet do gateway e do proprio load balancer.
###############################################################################

resource "azurerm_network_security_group" "aks" {
  name                = "nsg-${local.base}-aks"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = local.tags

  security_rule {
    name                       = "allow-appgw-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443", "8000-8100"]
    source_address_prefix      = var.appgw_subnet_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-azure-lb-inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}
