variable "vnet_name" {
  type        = string
  description = "Nome da Virtual Network"
}

variable "resource_group_name" {
  type        = string
  description = "Resource Group onde a VNet sera criada"
}

variable "location" {
  type        = string
  description = "Regiao do Azure"
}

variable "address_space" {
  type        = list(string)
  description = "Faixas de enderecos (CIDR) da VNet"

  validation {
    condition     = length(var.address_space) > 0
    error_message = "Informe ao menos um CIDR para a VNet."
  }
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS customizados da VNet. Vazio usa o DNS padrao do Azure"
  default     = []
}

variable "subnets" {
  type = map(object({
    address_prefixes  = list(string)
    service_endpoints = optional(list(string), [])
  }))
  description = "Mapa de subnets. A chave e o nome da subnet"
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas aos recursos"
  default     = {}
}
