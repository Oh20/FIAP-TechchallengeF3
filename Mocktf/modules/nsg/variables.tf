variable "nsg_name" {
  type        = string
  description = "Nome do Network Security Group"
}

variable "resource_group_name" {
  type        = string
  description = "Resource Group onde o NSG sera criado"
}

variable "location" {
  type        = string
  description = "Regiao do Azure"
}

variable "security_rules" {
  type = map(object({
    priority                     = number
    direction                    = string # Inbound | Outbound
    access                       = string # Allow | Deny
    protocol                     = string # Tcp | Udp | Icmp | *
    source_port_range            = optional(string, "*")
    destination_port_range       = optional(string)
    destination_port_ranges      = optional(list(string))
    source_address_prefix        = optional(string)
    source_address_prefixes      = optional(list(string))
    destination_address_prefix   = optional(string, "*")
    destination_address_prefixes = optional(list(string))
    description                  = optional(string, "")
  }))
  description = "Mapa de regras do NSG. A chave e o nome da regra"
  default     = {}

  validation {
    condition     = alltrue([for r in var.security_rules : contains(["Inbound", "Outbound"], r.direction)])
    error_message = "direction deve ser Inbound ou Outbound."
  }

  validation {
    condition     = alltrue([for r in var.security_rules : contains(["Allow", "Deny"], r.access)])
    error_message = "access deve ser Allow ou Deny."
  }
}

variable "subnet_ids" {
  type        = list(string)
  description = "IDs das subnets que serao associadas a este NSG"
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas aos recursos"
  default     = {}
}
