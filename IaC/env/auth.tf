###############################################################################
# Autenticacao no Azure (App Registration / service principal)
#
# O provider azurerm e o backend azurerm leem as MESMAS variaveis de ambiente,
# entao exportar as credenciais uma vez cobre os dois:
#
#   export ARM_TENANT_ID="<directory (tenant) id>"
#   export ARM_SUBSCRIPTION_ID="<subscription id>"
#   export ARM_CLIENT_ID="<application (client) id>"
#   export ARM_CLIENT_SECRET="<client secret>"       # segredo
#
# Com federated credential (OIDC), no lugar do secret:
#   export ARM_USE_OIDC="true"
#
# As variaveis abaixo existem para quem prefere fixar tenant e subscription no
# tfvars em vez do ambiente. O client secret NAO tem variavel de proposito:
# ele so entra por ARM_CLIENT_SECRET, para nao acabar em arquivo versionado.
#
# Todas tem default null de proposito. null significa "nao definido", e o
# provider cai na variavel de ambiente correspondente. Um valor explicito aqui
# sobrescreve o ambiente - inclusive um `false`, o que quebraria quem depende
# de ARM_USE_OIDC.
###############################################################################

variable "subscription_id" {
  type        = string
  description = "Subscription onde o ambiente sera criado. null usa ARM_SUBSCRIPTION_ID."
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
