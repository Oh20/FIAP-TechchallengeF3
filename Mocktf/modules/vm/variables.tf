variable "vm_name" {
  type        = string
  description = "Nome da Virtual Machine"
}

variable "resource_group_name" {
  type        = string
  description = "Resource Group onde a VM sera criada"
}

variable "location" {
  type        = string
  description = "Regiao do Azure"
}

variable "subnet_id" {
  type        = string
  description = "ID da subnet onde a NIC da VM sera criada"
}

variable "vm_size" {
  type        = string
  description = "SKU da VM"
  default     = "Standard_B2s"
}

variable "admin_username" {
  type        = string
  description = "Usuario administrador da VM"
  default     = "azureuser"
}

variable "ssh_public_key" {
  type        = string
  description = "Chave publica SSH (conteudo do arquivo .pub) usada para acesso a VM"

  validation {
    condition     = length(trimspace(var.ssh_public_key)) > 0
    error_message = "ssh_public_key nao pode ser vazia. Autenticacao por senha esta desabilitada."
  }
}

variable "private_ip_address" {
  type        = string
  description = "IP privado estatico. Vazio usa alocacao dinamica"
  default     = null
}

variable "enable_public_ip" {
  type        = bool
  description = "Cria e associa um IP publico a VM"
  default     = false
}

variable "os_disk_type" {
  type        = string
  description = "Tipo do disco do SO"
  default     = "StandardSSD_LRS"
}

variable "os_disk_size_gb" {
  type        = number
  description = "Tamanho do disco do SO em GB"
  default     = 32
}

variable "source_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  description = "Imagem base da VM"
  default = {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

variable "data_disks" {
  type = map(object({
    size_gb              = number
    lun                  = number
    storage_account_type = optional(string, "StandardSSD_LRS")
    caching              = optional(string, "ReadWrite")
  }))
  description = "Discos de dados adicionais. A chave e o nome do disco"
  default     = {}
}

variable "custom_data" {
  type        = string
  description = "Script cloud-init em texto puro executado no primeiro boot"
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas aos recursos"
  default     = {}
}
