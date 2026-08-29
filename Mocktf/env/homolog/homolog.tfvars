project     = "togglemaster"
environment = "hml"
location    = "eastus"

vnet_address_space = ["10.20.0.0/16"]
subnet_app_prefix  = ["10.20.1.0/24"]
subnet_data_prefix = ["10.20.2.0/24"]

vm_size          = "Standard_B2s"
admin_username   = "azureuser"
enable_public_ip = true

extra_tags = {
  cost_center = "techchallenge-f3"
}

# ATENCAO: ssh_public_key e allowed_ssh_source NAO ficam neste arquivo.
# Valores em -var-file tem precedencia sobre TF_VAR_*, entao um placeholder aqui
# sobrescreveria o valor injetado pelo pipeline.
#   CI/CD  -> variaveis TF_VAR_ssh_public_key / TF_VAR_allowed_ssh_source
#   Local  -> cp secrets.tfvars.example secrets.tfvars (arquivo no .gitignore)
#             terraform plan -var-file=homolog.tfvars -var-file=secrets.tfvars
