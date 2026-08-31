# IaC — ToggleMaster

Terraform que provisiona o ambiente Azure do ToggleMaster (o desenho em
`../ArquiteturaInfra.png`). O deploy da aplicação é feito pelo Argo CD a partir
do repositório `../infra`; aqui só sobe a infraestrutura.

## Estrutura

```
IaC/
├── bootstrap/   Resource Group + Storage Account do tfstate (backend local)
├── modules/     Módulo de plataforma: todos os recursos do ambiente
└── env/         Root module: instancia o módulo e guarda o state remoto
```

`modules/` é um módulo reutilizável — não tem `backend` nem bloco `provider`.
Para um segundo ambiente, basta uma nova pasta ao lado de `env/` apontando para
o mesmo módulo com outro `environment` e outra `key` de state.

## O que é criado

| Bloco do diagrama | Recursos |
| --- | --- |
| AKS | Cluster com 3 node pools: `systempool`, `apppool` (App), `cicdpool` (Argo CD, com taint `workload=cicd:NoSchedule`) |
| AppGateway + AGIC | Addon `ingress_application_gateway`, em subnet dedicada — atende o Ingress com a classe `azure/application-gateway` |
| ACR | Registry com `admin_enabled = false`; o kubelet puxa imagens via role `AcrPull` |
| Managed DB | 3 PostgreSQL Flexible Server (auth, flag, targeting) + Cosmos DB serverless (analytics) + Azure Cache for Redis (evaluation) |
| Mensageria | Service Bus namespace + fila `togglemasterqueue` + regra de acesso `listen/send` (sem `manage`) |
| KeyVault [APP CI] | Segredos da aplicação; o CSI driver do AKS tem `Key Vault Secrets User` |
| KeyVault [Infra CI/CD] | Coordenadas do ambiente para o pipeline de infra |
| StorageAccount [Observabilidade] | Log Analytics + Storage com os logs do control plane do AKS |
| StorageAccount [TFState] | Criado por `bootstrap/` |

## Como subir

### 1. Autenticação (App Registration)

O provider **e** o backend leem as mesmas variáveis `ARM_*`, então exportá-las
uma vez cobre os dois:

```bash
export ARM_TENANT_ID="<directory (tenant) id>"
export ARM_SUBSCRIPTION_ID="<subscription id>"
export ARM_CLIENT_ID="<application (client) id>"
export ARM_CLIENT_SECRET="<client secret>"     # ou: export ARM_USE_OIDC=true
```

No PowerShell, `$env:ARM_TENANT_ID = "..."`.

O client secret **só** entra por variável de ambiente. Não existe variável
Terraform para ele de propósito, para não acabar em arquivo versionado. Para
Azure DevOps, prefira uma service connection do tipo *Workload Identity
federation* e `ARM_USE_OIDC=true`: não há segredo para rotacionar.

`env/auth.tf` e `bootstrap/auth.tf` expõem `tenant_id`, `subscription_id`,
`client_id` e `use_oidc` como variáveis, caso prefira fixar tenant e
subscription no tfvars. Todas têm default `null`, que significa "não definido" —
o provider então cai na variável de ambiente. Não troque esses defaults por
`false`: um valor explícito sobrescreve o ambiente e quebraria quem usa
`ARM_USE_OIDC`.

Permissões que o App Registration precisa na subscription:

| Papel | Por quê |
| --- | --- |
| **Owner** — ou Contributor **+** User Access Administrator | O código cria role assignments (AcrPull, Key Vault, AGIC) |
| `Storage Blob Data Contributor` no Storage Account do state | Ler e gravar o tfstate via Entra ID |

O segundo é concedido pelo próprio `bootstrap/`. Ele **não** precisa entrar em
`key_vault_admin_object_ids`: o módulo já dá `Key Vault Secrets Officer` ao
principal em execução, via `data.azurerm_client_config.current`.

Para conferir com qual identidade você está autenticado:

```bash
terraform console -var-file=toggle.tfvars   # e então: data.azurerm_client_config.current
```

### 2. Backend do state (uma vez por subscription)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # ajuste os object IDs
terraform init
terraform apply
```

Cria `rg-togglemaster-tfstate` / `attogglemastertfstate`. Se mudar esses nomes,
ajuste também o bloco `backend` em `env/providers.tf`.

**Rode o bootstrap com o próprio App Registration sempre que puder.** O
principal que executa recebe `Storage Blob Data Contributor` automaticamente. Se
rodar com o seu usuário (`az login`), coloque o *object ID* do App Registration
em `state_contributor_object_ids` — senão o pipeline não consegue gravar o
state:

```bash
az ad sp show --id <application-client-id> --query id -o tsv
```

Repare que o **object ID** do service principal é diferente do *application
(client) id*. É o object ID que vai nessa lista.

O Storage Account do state sobe com `shared_access_key_enabled = false`: o state
guarda a senha do PostgreSQL, a chave do Cosmos e a connection string do Service
Bus em texto claro, então o RBAC do Entra ID é o único caminho de acesso. Se o
primeiro apply falhar com `AuthorizationPermissionMismatch`, é propagação de
RBAC — suba `rbac_propagation_delay` para `"180s"` antes de considerar ligar a
chave compartilhada.

O state do bootstrap é local e pequeno — versione o `terraform.tfstate` dele ou
recrie por `terraform import` se precisar.

### 3. Ambiente

```bash
cd ../env
terraform init
terraform plan  -var-file=toggle.tfvars
terraform apply -var-file=toggle.tfvars
```

O primeiro apply leva de 15 a 25 minutos (AKS e Application Gateway são os
demorados).

### 4. Conectar no cluster

```bash
az aks get-credentials \
  --resource-group $(terraform output -raw resource_group_name) \
  --name           $(terraform output -raw aks_cluster_name) \
  --overwrite-existing
```

## Ligação com o repositório `../infra` (Argo CD)

Depois do apply, três valores precisam ser refletidos nos manifests:

1. **Imagens.** Os deployments em `infra/base/*/deployment.yaml` apontam para
   um ACR fixo. Troque o prefixo pelo valor de `terraform output -raw acr_login_server`.

2. **ConfigMaps.** `COSMOS_ENDPOINT` em
   `infra/base/analytics-service/configmap.yaml` deve receber
   `terraform output -raw cosmos_endpoint`. `SERVICE_BUS_QUEUE_NAME` já bate com
   o default (`togglemasterqueue`).

3. **Secrets.** Os `secret.example.yaml` são modelos. Os valores reais estão no
   Key Vault [APP CI], com estes nomes:

   | Secret no Key Vault | Variável no pod |
   | --- | --- |
   | `auth-service-database-url` | `DATABASE_URL` do auth-service |
   | `flag-service-database-url` | `DATABASE_URL` do flag-service |
   | `targeting-service-database-url` | `DATABASE_URL` do targeting-service |
   | `redis-url` | `REDIS_URL` |
   | `cosmos-endpoint` / `cosmos-key` | `COSMOS_ENDPOINT` / `COSMOS_KEY` |
   | `servicebus-connection-string` | `SERVICE_BUS_CONNECTION_STRING` |
   | `auth-master-key` | `MASTER_KEY` |
   | `evaluation-service-api-key` | `SERVICE_API_KEY` |

   O cluster já tem o addon `key_vault_secrets_provider` habilitado, então dá
   para consumi-los via `SecretProviderClass` em vez de commitar Secrets. O
   client ID da identidade está em
   `terraform output -raw aks_secrets_provider_client_id`.

Os mesmos valores também saem por output, se preferir gerar os Secrets no
pipeline:

```bash
terraform output -json database_urls
terraform output -raw  redis_url
terraform output -raw  servicebus_connection_string
```

## Custo

Os defaults em `toggle.tfvars` são de laboratório: `Standard_B2s` nos nodes,
`B_Standard_B1ms` no PostgreSQL, Redis Basic C0, Cosmos serverless, AKS no tier
`Free`. Para carga real, suba `aks_sku_tier` para `Standard` e troque os VM
sizes.

`../app/scripts/env.sh` liga e desliga AKS, Application Gateway e PostgreSQL
entre apresentações — ajuste `AKS_NAME`, `AKS_RG` e `PG_SERVERS` com os nomes que
saem de `terraform output`.

## Decisões que valem registrar

- **PostgreSQL com acesso público + firewall**, não private endpoint. É o que
  permite `DATABASE_URL` com FQDN e `sslmode=require`, o formato que a aplicação
  já usa, e mantém o `psql` da equipe funcionando para as migrations. Para
  fechar, troque por `delegated_subnet_id` + Private DNS Zone e mova as
  migrations para dentro do cluster.
- **Senha do PostgreSQL gerada pelo Terraform** (`random_password`) e gravada no
  Key Vault. Nenhuma senha fica no código. Se preferir uma sua, preencha
  `postgres_admin_password` em `toggle.tfvars`.
- **Redis é Azure Cache for Redis**, não Managed Redis. A porta muda de `10000`
  para `6380` e o host de `.redis.azure.net` para `.redis.cache.windows.net` — o
  output `redis_url` já sai no formato certo.
- **Key Vault com RBAC**, não access policies. Adicione a equipe e a service
  connection do pipeline em `key_vault_admin_object_ids`.
- **Provider azurerm na série 3.x** (`~> 3.116`), que é o que o projeto já
  pinava. A migração para 4.x é um passo separado e mexe em vários nomes de
  atributo.
- **Credenciais só por variável de ambiente.** O bloco `backend` do Terraform
  não aceita variáveis, então fixar credencial no código exigiria hardcode.
  `ARM_*` resolve backend e provider de uma vez.
- **`storage_use_azuread` ligado no `bootstrap/`, não no `env/`.** No bootstrap
  ele é o que permite manter a chave compartilhada desligada no state. Já a
  Storage Account de observabilidade mantém a chave habilitada (as diagnostic
  settings do Azure Monitor arquivam por ela), então usar Entra ID para criar o
  container ali não fecharia nada — só adicionaria uma espera de RBAC.

## Verificação

```bash
terraform fmt -recursive -check
terraform validate
```

Ambas as pastas (`env/` e `bootstrap/`) passam limpas.
