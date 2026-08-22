# Backend remoto no Azure Storage.
# Os valores sao injetados pelo pipeline (TerraformTaskV4 -> command: init).
# Para rodar local: terraform init -backend-config=backend.hcl
terraform {
  backend "azurerm" {}
}
