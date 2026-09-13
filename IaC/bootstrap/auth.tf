###############################################################################
# Autenticacao no Azure (App Registration / service principal)
#
# Mesmas variaveis de ../env/auth.tf. Todas com default null: null significa
# "nao definido" e o provider cai na variavel de ambiente correspondente.
#
#   export ARM_TENANT_ID="<directory (tenant) id>"
#   export ARM_SUBSCRIPTION_ID="<subscription id>"
#   export ARM_CLIENT_ID="<application (client) id>"
#   export ARM_CLIENT_SECRET="<client secret>"       # ou ARM_USE_OIDC=true
###############################################################################

variable "subscription_id" {
  type        = string
  description = "Subscription onde o backend sera criado. null usa ARM_SUBSCRIPTION_ID."
  default     = null
}

variable "tenant_id" {
  type        = string
  description = "Tenant do Entra ID. null usa ARM_TENANT_ID."
  default     = null
}

variable "client_id" {
  type        = string
  description = "Application (client) ID do App Registration. null usa ARM_CLIENT_ID."
  default     = null
}

variable "use_oidc" {
  type        = bool
  description = "Autenticar por federated credential (OIDC) em vez de client secret. null usa ARM_USE_OIDC."
  default     = null
}
