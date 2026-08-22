# Mocktf — Infraestrutura modular (VM + VNET + NSG)

Módulos Terraform para provisionar o ambiente de **homologação** do ToggleMaster no Azure.

## Estrutura

```
Mocktf/
├── modules/
│   ├── network/   # VNet + subnets (map, com service endpoints)
│   ├── nsg/       # NSG + regras dinâmicas + associação às subnets
│   └── vm/        # VM Linux + NIC + IP público opcional + discos de dados
└── env/
    └── homolog/   # Composição do ambiente (root module)
```

Os módulos não criam Resource Group — quem cria é o ambiente, o que permite reaproveitá-los
em `dev`/`prod` apenas adicionando uma nova pasta em `env/`.

## O que o ambiente homolog cria

| Recurso | Nome | Detalhe |
|---|---|---|
| Resource Group | `rg-togglemaster-hml` | eastus |
| VNet | `vnet-togglemaster-hml` | `10.20.0.0/16` |
| Subnet app | `snet-app-togglemaster-hml` | `10.20.1.0/24` |
| Subnet data | `snet-data-togglemaster-hml` | `10.20.2.0/24`, service endpoints Storage/KeyVault |
| NSG app | `nsg-app-togglemaster-hml` | SSH restrito por IP, 80/443 liberados, deny-all final |
| NSG data | `nsg-data-togglemaster-hml` | 5432 só a partir da subnet de app, deny-all final |
| VM | `vm-app-togglemaster-hml` | Ubuntu 22.04, Standard_B2s, SSH por chave, Docker via cloud-init |

Autenticação por senha está **desabilitada** na VM — só chave SSH.

## Variáveis sensíveis

`ssh_public_key` e `allowed_ssh_source` **não ficam** no `homolog.tfvars`. Um valor em
`-var-file` tem precedência sobre `TF_VAR_*`, então um placeholder no arquivo sobrescreveria
o valor injetado pelo pipeline.

- **CI/CD:** variáveis secretas `sshPublicKey` e `allowedSshSource`, mapeadas para
  `TF_VAR_ssh_public_key` / `TF_VAR_allowed_ssh_source`.
- **Local:** `cp secrets.tfvars.example secrets.tfvars` (arquivo no `.gitignore`).

A variável `allowed_ssh_source` tem `validation` que **rejeita** `*`, `Internet`, `any` e
`0.0.0.0/0` — o plan falha se alguém tentar abrir SSH para o mundo.

## Execução local

```bash
az login
cp backend.hcl.example backend.hcl        # ajuste o key se necessário
cp secrets.tfvars.example secrets.tfvars  # preencha IP e chave SSH

cd env/homolog
terraform init -backend-config=backend.hcl
terraform plan  -var-file=homolog.tfvars -var-file=secrets.tfvars -out=tfplan
terraform apply tfplan
```

Destruir: `terraform destroy -var-file=homolog.tfvars -var-file=secrets.tfvars`.

## Execução via CI/CD

Pipeline: **`pipeline-iac-homolog.yml`** (raiz do repositório).

```
Bootstrap  →  ValidateAndPlan  →  [Approval Gate]  →  Apply
   (az)       fmt/validate/plan                        (ou Destroy)
```

- **Bootstrap** — cria o RG, a storage account e o container do tfstate. O `terraform init`
  consome o backend mas não o cria, então sem esse passo o primeiro run falha.
  Usa a *account key* (Contributor consegue `listKeys`) em vez de `--auth-mode login`,
  que exigiria a role de data plane `Storage Blob Data Contributor`.
- **ValidateAndPlan** — roda também em Pull Request; `terraform fmt -check -recursive` é gate.
  O plan é publicado como artefato `tfplan` e impresso com `terraform show` para revisão.
- **Apply** — só na `main`, fora de PR, atrás do Approval Gate do environment `Homolog-Infra`.
  Aplica o **plan aprovado**, então o que foi revisado é exatamente o que é aplicado.
- **Destroy** — rodar o pipeline manualmente com o parâmetro `destroyEnvironment = true`.

### Pré-requisitos no Azure DevOps

1. Extensão **Terraform (Microsoft DevLabs)** instalada na organização
   (fornece `TerraformInstaller@0` e `TerraformTaskV4@4`, já usadas em `pipeline-iac.yml`).
2. Service connection ARM `sc-azure-togglemaster` com **Contributor** na subscription.
3. Environment `Homolog-Infra` criado, com Approval Gate.
4. Variáveis **secretas** do pipeline: `sshPublicKey` e `allowedSshSource`.

O nome da storage account (`sttogglemastertfstate`) é global no Azure; se já estiver em uso
por outra conta, ajuste `backendStorageAccount` no pipeline.

O state deste ambiente usa a key `togglemaster-homolog.terraform.tfstate`, separada da key
`togglemaster.terraform.tfstate` do `pipeline-iac.yml`, para que os dois não colidam.

## Validação executada

Com Terraform 1.7.5 / azurerm 3.117.1:

- `terraform fmt -check -recursive` — sem diferenças;
- `terraform validate` — `Success! The configuration is valid.`;
- `terraform plan` com `allowed_ssh_source = "0.0.0.0/0"` — bloqueado pela `validation`;
- `terraform plan` com valores válidos — chega até a autenticação no Azure (única etapa
  que exige credencial real), confirmando que variáveis, módulos e flags estão corretos;
- `.terraform.lock.hcl` com hashes para `linux_amd64` (agente), `windows_amd64` e
  `darwin_arm64`, para o `init` não falhar por checksum ausente.
