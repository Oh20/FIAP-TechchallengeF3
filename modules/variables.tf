variable  "resource-group_toggle-master" {
  type        = string
  description = "Resource Group Criada para o projeto toggle-master"
}

variable "location" {
  type        = string
  description = "Location Criada para o projeto toggle-master"
}

variable "vnet" {
  type        = string
  description = "VNet Criada para o projeto toggle-master"
}

variable subnet {
  type        = string
  description = "Subnet Criada para o projeto toggle-master"
}

variable "database-postgres" {
  description = "Instância de Database PostgreSQL Criada para o projeto toggle-master"
  default =  {
    "auth_db" = {
      tamanho  = "B_Standard_B1ms"
      nome_bd  = "auth_db"
      usuario  = "admin_auth" 
    }
    "flag_db" = {
      tamanho  = "B_Standard_B1ms"
      nome_bd  = "flag_db"
      usuario  = "admin_flag" 
    }
    "targeting_db" = {
      tamanho  = "B_Standard_B1ms"
      nome_bd  = "targeting_db"
      usuario  = "admin_targ" 
    }
  }
}

variable "aks-toggle-master" {
  type        = string
  description = "Cluster AKS Criado para o projeto toggle-master"
}

variable "redis-toggle-master" {
  type        = string
  description = "Redis Criado para o projeto toggle-master"
}

variable "cosmodb-toggle-master" {
  type        = string
  description = "Cosmodb Criado para o projeto toggle-master"
}

variable "servicebus-toggle-master" {
  type        = string
  description = "Service Bus Criado para o projeto toggle-master"
}

variable "acr-toggle-master" {
  type        = string
  description = "ACR Criado para o projeto toggle-master"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags para o projeto toggle-master"
}


