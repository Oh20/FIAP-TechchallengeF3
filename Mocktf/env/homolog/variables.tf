variable "project" {
  type        = string
  description = "Nome curto do projeto usado na nomenclatura dos recursos"
  default     = "togglemaster"
}

variable "environment" {
  type        = string
  description = "Nome do ambiente"
  default     = "hml"
}

variable "location" {
  type        = string
  description = "Regiao do Azure"
  default     = "eastus"
}

variable "vnet_address_space" {
  type        = list(string)
  description = "CIDR da VNet de homologacao"
  default     = ["10.20.0.0/16"]
}

variable "subnet_app_prefix" {
  type        = list(string)
  description = "CIDR da subnet de aplicacao"
  default     = ["10.20.1.0/24"]
}

variable "subnet_data_prefix" {
  type        = list(string)
  description = "CIDR da subnet de dados"
  default     = ["10.20.2.0/24"]
}

variable "allowed_ssh_source" {
  type        = string
  description = "IP ou CIDR autorizado a acessar a VM via SSH. Nunca usar '*' ou 'Internet'"

  validation {
    condition     = !contains(["*", "Internet", "any", "0.0.0.0/0"], var.allowed_ssh_source)
    error_message = "Libere o SSH apenas para um IP/CIDR especifico (ex.: 200.10.5.7/32)."
  }
}

variable "vm_size" {
  type        = string
  description = "SKU da VM de homologacao"
  default     = "Standard_B2s"
}

variable "admin_username" {
  type        = string
  description = "Usuario administrador da VM"
  default     = "azureuser"
}

variable "ssh_public_key" {
  type        = string
  description = "Conteudo da chave publica SSH usada para acessar a VM"
}

variable "enable_public_ip" {
  type        = bool
  description = "Expoe a VM de homologacao com IP publico"
  default     = true
}

variable "extra_tags" {
  type        = map(string)
  description = "Tags adicionais mescladas as tags padrao"
  default     = {}
}
