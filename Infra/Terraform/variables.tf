variable  "resource-group_toggle-master" {
  type        = string
  default     = "rg-toggle-master"
  description = "Resource Group Criada para o projeto toggle-master"
}

variable "location" {
  type        = string
  default     = "eastus"
  description = "Location Criada para o projeto toggle-master"
}

variable "vnet" {
  type        = string
  default     = "vnet-toggle-master"
  description = "VNet Criada para o projeto toggle-master"
}

variable subnet {
  type        = string
  default     = "subnet-toggle-master"
  description = "Subnet Criada para o projeto toggle-master"
}

variable "database-postgre" {
  type        = string
  default     = "database-postgre-toggle-master"
  description = "Database PostgreSQL Criada para o projeto toggle-master"
}

variable "aks-toggle-master" {
  type        = string
  default     = "aks-toggle-master"
  description = "Cluster AKS Criado para o projeto toggle-master"
}

variable "redis-toggle-master" {
  type        = string
  default     = "redis-toggle-master"
  description = "Redis Criado para o projeto toggle-master"
}

variable "cosmodb-toggle-master" {
  type        = string
  default     = "cosmodb-toggle-master"
  description = "Cosmodb Criado para o projeto toggle-master"
}

variable "servicebus-toggle-master" {
  type        = string
  default     = "servicebus-toggle-master"
  description = "Service Bus Criado para o projeto toggle-master"
}

variable "acr-toggle-master" {
  type        = string
  default     = "acr-toggle-master"
  description = "ACR Criado para o projeto toggle-master"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags para o projeto toggle-master"
}




