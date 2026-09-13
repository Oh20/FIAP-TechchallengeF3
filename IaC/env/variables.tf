###############################################################################
# Variaveis do ambiente.
#
# Espelham as do modulo em ../modules e sao preenchidas por toggle.tfvars.
###############################################################################

###############################################################################
# Identificacao / naming
###############################################################################

variable "project" {
  type        = string
  description = "Nome curto do projeto. Compoe o nome de todos os recursos."
  default     = "togglemaster"

  validation {
    condition     = can(regex("^[a-z0-9]{3,16}$", var.project))
    error_message = "project deve ter de 3 a 16 caracteres, apenas minusculas e numeros."
  }
}

variable "environment" {
  type        = string
  description = "Ambiente (dev, stg, prod). Compoe o nome de todos os recursos."
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.environment))
    error_message = "environment deve ter de 2 a 6 caracteres, apenas minusculas e numeros."
  }
}

variable "location" {
  type        = string
  description = "Regiao do Azure onde o ambiente sera criado."
  default     = "eastus"
}

variable "name_suffix" {
  type        = string
  description = "Sufixo dos recursos de nome globalmente unico (ACR, Key Vault, Storage Account, Cosmos, Service Bus, Redis, PostgreSQL). Vazio gera um sufixo aleatorio e estavel no state."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas a todos os recursos."
  default     = {}
}

###############################################################################
# Rede
###############################################################################

variable "vnet_address_space" {
  type        = list(string)
  description = "Address space da VNet do ambiente."
  default     = ["10.20.0.0/16"]
}

variable "aks_subnet_prefix" {
  type        = string
  description = "Prefixo da subnet dos nodes do AKS."
  default     = "10.20.0.0/20"
}

variable "appgw_subnet_prefix" {
  type        = string
  description = "Prefixo da subnet dedicada ao Application Gateway (AGIC)."
  default     = "10.20.16.0/24"
}

###############################################################################
# AKS
###############################################################################

variable "kubernetes_version" {
  type        = string
  description = "Versao do Kubernetes. null usa a default da regiao."
  default     = null
}

variable "aks_sku_tier" {
  type        = string
  description = "SLA do control plane: Free, Standard ou Premium."
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.aks_sku_tier)
    error_message = "aks_sku_tier deve ser Free, Standard ou Premium."
  }
}

variable "system_node_pool" {
  type = object({
    vm_size    = optional(string, "Standard_B2s")
    node_count = optional(number, 2)
    min_count  = optional(number, 2)
    max_count  = optional(number, 3)
    disk_gb    = optional(number, 30)
  })
  description = "Node pool de sistema (componentes do proprio cluster)."
  default     = {}
}

variable "app_node_pool" {
  type = object({
    enabled    = optional(bool, true)
    vm_size    = optional(string, "Standard_B2s")
    node_count = optional(number, 2)
    min_count  = optional(number, 2)
    max_count  = optional(number, 5)
    disk_gb    = optional(number, 30)
  })
  description = "Node pool das aplicacoes (AKS - App no diagrama)."
  default     = {}
}

variable "cicd_node_pool" {
  type = object({
    enabled    = optional(bool, true)
    vm_size    = optional(string, "Standard_B2s")
    node_count = optional(number, 1)
    min_count  = optional(number, 1)
    max_count  = optional(number, 3)
    disk_gb    = optional(number, 30)
  })
  description = "Node pool de CI/CD, onde roda o Argo CD (AKS - CI/CD no diagrama)."
  default     = {}
}

variable "acr_sku" {
  type        = string
  description = "SKU do Azure Container Registry."
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku deve ser Basic, Standard ou Premium."
  }
}

###############################################################################
# PostgreSQL
###############################################################################

variable "postgres_location" {
  type        = string
  description = "Regiao dos Flexible Servers. Vazio usa a mesma regiao do ambiente (var.location). Existe porque algumas subscriptions bloqueiam o provisionamento de PostgreSQL em certas regioes - o erro aparece como \"The value of the 'Version' should be in: []\"."
  default     = ""
}

variable "postgres_servers" {
  type = map(object({
    database_name = string
    sku_name      = optional(string, "B_Standard_B1ms")
    storage_mb    = optional(number, 32768)
    version       = optional(string, "16")
  }))
  description = "Um Flexible Server por microsservico, conforme o diagrama. A chave do mapa compoe o nome do servidor e o nome do secret no Key Vault."

  default = {
    auth = {
      database_name = "auth_db"
    }
    flag = {
      database_name = "flags_db"
    }
    targeting = {
      database_name = "targeting_db"
    }
  }
}

variable "postgres_admin_user" {
  type        = string
  description = "Usuario administrador dos Flexible Servers."
  default     = "admintogglemaster"
}

variable "postgres_admin_password" {
  type        = string
  description = "Senha do administrador. Vazio gera uma senha aleatoria guardada no Key Vault."
  default     = ""
  sensitive   = true
}

variable "postgres_allowed_cidrs" {
  type        = map(string)
  description = "Regras de firewall extras do PostgreSQL no formato { \"nome-da-regra\" = \"1.2.3.4/32\" }. Use para liberar o IP da equipe."
  default     = {}
}

###############################################################################
# Cosmos DB (analytics)
###############################################################################

variable "cosmos_database_name" {
  type        = string
  description = "Database do Cosmos DB usado pelo analytics-service (COSMOS_DATABASE)."
  default     = "ToggleMaster"
}

variable "cosmos_container_name" {
  type        = string
  description = "Container do Cosmos DB usado pelo analytics-service (COSMOS_CONTAINER)."
  default     = "ToggleMasterAnalytics"
}

variable "cosmos_partition_key_path" {
  type        = string
  description = "Partition key do container. O analytics-service grava eventos por flag_name."
  default     = "/flag_name"
}

###############################################################################
# Redis (evaluation-service)
###############################################################################

variable "redis" {
  type = object({
    sku_name = optional(string, "Basic")
    family   = optional(string, "C")
    capacity = optional(number, 0)
  })
  description = "Azure Cache for Redis usado como cache do evaluation-service."
  default     = {}
}

###############################################################################
# Service Bus (mensageria)
###############################################################################

variable "servicebus_sku" {
  type        = string
  description = "SKU do namespace do Service Bus."
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.servicebus_sku)
    error_message = "servicebus_sku deve ser Basic, Standard ou Premium."
  }
}

variable "servicebus_queue_name" {
  type        = string
  description = "Fila de eventos de avaliacao (SERVICE_BUS_QUEUE_NAME nos ConfigMaps)."
  default     = "togglemasterqueue"
}

###############################################################################
# Observabilidade
###############################################################################

variable "log_analytics_retention_days" {
  type        = number
  description = "Retencao do Log Analytics Workspace, em dias."
  default     = 30
}

###############################################################################
# Key Vault
###############################################################################

variable "key_vault_admin_object_ids" {
  type        = list(string)
  description = "Object IDs (usuarios, grupos ou service principals) que recebem Key Vault Secrets Officer nos dois cofres - normalmente a equipe e a service connection do pipeline de infra."
  default     = []
}

variable "key_vault_purge_protection_enabled" {
  type        = bool
  description = "Protecao contra purge. Mantenha false em laboratorio para permitir recriar o cofre."
  default     = false
}

variable "key_vault_soft_delete_retention_days" {
  type        = number
  description = "Dias de retencao do soft delete do Key Vault (minimo 7)."
  default     = 7
}
