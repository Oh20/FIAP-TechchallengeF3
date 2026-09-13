variable "resource_group_name" {
  type        = string
  description = "Resource Group que guarda o Storage Account do state."
  default     = "rg-togglemaster-tfstate"
}

variable "location" {
  type        = string
  description = "Regiao do Storage Account do state."
  default     = "eastus"
}

variable "storage_account_name" {
  type        = string
  description = "Storage Account do state. Precisa ser unico no Azure e bater com o backend em ../env/providers.tf."
  default     = "attogglemastertfstate"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name deve ter de 3 a 24 caracteres, apenas minusculas e numeros."
  }
}

variable "container_name" {
  type        = string
  description = "Container dos arquivos de state."
  default     = "tfstate"
}

variable "state_contributor_object_ids" {
  type        = list(string)
  description = "Object IDs que recebem Storage Blob Data Contributor no Storage Account. Coloque aqui o object ID do App Registration se o bootstrap nao rodar com a identidade dele, mais os usuarios da equipe que precisam rodar terraform localmente."
  default     = []
}

variable "shared_access_key_enabled" {
  type        = bool
  description = "Permitir acesso ao Storage Account pela chave compartilhada. false deixa o RBAC do Entra ID como unico caminho - o state guarda segredos em texto claro. Ligue temporariamente se o primeiro apply falhar por propagacao de RBAC."
  default     = false
}

variable "rbac_propagation_delay" {
  type        = string
  description = "Espera entre conceder Storage Blob Data Contributor e criar o container. RBAC de data plane leva ate ~2 minutos para propagar em alguns tenants."
  default     = "90s"
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas aos recursos do backend."

  default = {
    projeto    = "togglemaster"
    finalidade = "terraform-state"
    gerenciado = "terraform"
  }
}
