# IaC — ToggleMaster

Terraform que provisiona o ambiente Azure do ToggleMaster (`../ArquiteturaInfra.png`).
O deploy da aplicação é feito pelo Argo CD a partir do repositório `../infra`;
aqui sobe só a infraestrutura.

Este README é um runbook: siga na ordem e o ambiente sobe do zero.

## Estrutura

```
IaC/
├── bootstrap/   Resource Group + Storage Account do tfstate (backend local)
├── modules/     Módulo de plataforma: todos os recursos do ambiente
└── env/         Root module: instancia o módulo e guarda o state remoto
```

`modules/` é um módulo reutilizável — não tem `backend` nem bloco `provider`.
Para um segundo ambiente, basta uma pasta nova ao lado de `env/` apontando para
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

---

# Parte 1 — Preparação

## 1.1 App Registration

```bash
az ad app create --display-name "togglemaster-infra"
az ad sp create --id <application-client-id>
```

Anote três valores:

| O que | Como obter | Onde usa |
| --- | --- | --- |
| **Application (client) ID** | `az ad app list --display-name togglemaster-infra --query "[0].appId" -o tsv` | `ARM_CLIENT_ID` |
| **Object ID do service principal** | `az ad sp show --id <application-client-id> --query id -o tsv` | `state_contributor_object_ids` |
| **Tenant ID** | `az account show --query tenantId -o tsv` | `ARM_TENANT_ID` |

O **object ID** do service principal é diferente do **application (client) id**.
Confundir os dois é o erro mais comum aqui: o Terraform aceita, o apply passa, e
a permissão simplesmente não funciona.

Permissão na subscription:

```bash
az role assignment create \
  --assignee <application-client-id> \
  --role Owner \
  --scope /subscriptions/<subscription-id>
```

**Owner** — ou Contributor **+** User Access Administrator. O código cria role
assignments (AcrPull, Key Vault, AGIC); sem isso o apply quebra no meio, com
parte dos recursos já criada.

Credencial, uma das duas:

```bash
# opção A — client secret
az ad app credential reset --id <application-client-id> --years 1

# opção B — federated credential (OIDC), recomendada para Azure DevOps
# Portal > App registration > Certificates & secrets > Federated credentials
# ou service connection do tipo "Workload Identity federation"
```

## 1.2 Exportar as credenciais

O provider **e** o backend leem as mesmas variáveis, então exportar uma vez
cobre os dois:

```bash
export ARM_TENANT_ID="<tenant id>"
export ARM_SUBSCRIPTION_ID="<subscription id>"
export ARM_CLIENT_ID="<application (client) id>"
export ARM_CLIENT_SECRET="<client secret>"     # ou: export ARM_USE_OIDC=true
```

PowerShell: `$env:ARM_TENANT_ID = "..."`

O client secret **só** entra por variável de ambiente. Não existe variável
Terraform para ele de propósito, para não acabar em arquivo versionado.

## 1.3 Valores que você precisa alterar

Tudo abaixo tem default funcional, **menos os dois marcados como obrigatórios**.

### Obrigatório

| Arquivo | Campo | Valor atual | O que colocar |
| --- | --- | --- | --- |
| `bootstrap/terraform.tfvars` | `storage_account_name` | `attogglemastertfstate` | Nome **único no Azure inteiro**. Verifique antes. Se mudar, mude também no backend de `env/providers.tf`. |
| `env/providers.tf` | bloco `backend` | `attogglemastertfstate` | Tem que bater exatamente com o bootstrap |

```bash
az storage account check-name --name attogglemastertfstate
# "nameAvailable": false  -> escolha outro
```

### Recomendado

| Arquivo | Campo | Valor atual | O que colocar |
| --- | --- | --- | --- |
| `bootstrap/terraform.tfvars` | `state_contributor_object_ids` | `[]` | Object ID do App Registration, **se** o bootstrap não rodar com a identidade dele |
| `env/toggle.tfvars` | `key_vault_admin_object_ids` | `[]` | Object IDs de quem precisa ler os segredos sem rodar terraform (`az ad signed-in-user show --query id -o tsv`) |
| `env/toggle.tfvars` | `postgres_allowed_cidrs` | `{}` | Seu IP, para rodar as migrations pelo psql: `{ "equipe" = "<seu-ip>/32" }` |
| `env/toggle.tfvars` | `location` | `eastus` | Região, se outra |

### Opcional

| Campo | Valor atual | Quando mexer |
| --- | --- | --- |
| `name_suffix` | `""` (gera aleatório) | Fixe um valor se quiser nomes previsíveis entre ambientes |
| `project` / `environment` | `togglemaster` / `prod` | Compõem o nome de todos os recursos |
| `aks_sku_tier` | `Free` | `Standard` para SLA do control plane |
| `system_node_pool` / `app_node_pool` / `cicd_node_pool` | `Standard_B2s` | Carga real: `Standard_D2s_v5` |
| `postgres_servers[*].sku_name` | `B_Standard_B1ms` | Carga real |
| `redis.sku_name` | `Basic` / C0 | `Standard` para réplica |

O que **não** precisa preencher: `postgres_admin_password` (o Terraform gera e
grava no Key Vault) e o App Registration em `key_vault_admin_object_ids` (o
módulo já concede Key Vault Secrets Officer ao principal em execução, via
`data.azurerm_client_config.current`).

---

# Parte 2 — Subir a infraestrutura

## 2.1 Backend do state

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars    # ajuste os valores da Parte 1.3
terraform init
terraform apply
```

**Rode com o próprio App Registration sempre que puder.** O principal que
executa recebe `Storage Blob Data Contributor` automaticamente. Se rodar com o
seu usuário (`az login`), preencha `state_contributor_object_ids` — senão o
pipeline não consegue gravar o state.

A conta sobe com `shared_access_key_enabled = false`: o state guarda a senha do
PostgreSQL, a chave do Cosmos e a connection string do Service Bus em texto
claro, então o RBAC do Entra ID é o único caminho. Se falhar com
`AuthorizationPermissionMismatch`, é propagação de RBAC — suba
`rbac_propagation_delay` para `"180s"` antes de considerar ligar a chave
compartilhada.

## 2.2 Ambiente

```bash
cd ../env
terraform init
terraform plan  -var-file=toggle.tfvars      # revise antes
terraform apply -var-file=toggle.tfvars
```

15 a 25 minutos. AKS e Application Gateway são os demorados.

## 2.3 Conectar no cluster

```bash
az aks get-credentials \
  --resource-group $(terraform output -raw resource_group_name) \
  --name           $(terraform output -raw aks_cluster_name) \
  --overwrite-existing

kubectl get nodes
```

Devem aparecer os três node pools: `systempool`, `apppool`, `cicdpool`.

---

# Parte 3 — Publicar as imagens

O ACR novo está **vazio**. Os pods ficam em `ImagePullBackOff` até isto rodar.

```bash
cd ../..                                        # raiz do projeto
ACR=$(cd IaC/env && terraform output -raw acr_name)
az acr login --name "$ACR"

for svc in auth-service flag-service targeting-service evaluation-service analytics-service; do
  az acr build --registry "$ACR" --image "$svc:latest" "app/app/$svc"
done

az acr repository list --name "$ACR" -o table    # confirme os 5
```

`az acr build` compila no próprio ACR — não precisa de Docker local.

---

# Parte 4 — Ligar o repositório `../infra` (Argo CD)

## 4.1 Trocar o ACR nos manifests

O ACR antigo (`fiapdevopsadegj.azurecr.io`) aparece em **dois lugares** — o
kustomize casa a imagem pelo campo `name`, então trocar só o deployment não
basta:

```bash
cd ../infra
NEW_ACR=$(cd ../IaC/env && terraform output -raw acr_login_server)

# 1) os 5 deployments (linha 20 de cada)
sed -i "s|fiapdevopsadegj.azurecr.io|$NEW_ACR|g" base/*/deployment.yaml

# 2) os overlays dev e prod (campo images[].name)
sed -i "s|fiapdevopsadegj.azurecr.io|$NEW_ACR|g" overlays/*/*/kustomization.yaml

grep -rn "azurecr.io" base overlays        # confirme que não sobrou nenhum
```

## 4.2 Trocar o endpoint do Cosmos

`base/analytics-service/configmap.yaml`, linha 11:

```bash
COSMOS=$(cd ../IaC/env && terraform output -raw cosmos_endpoint)
sed -i "s|https://tohhlemaster-analytics.documents.azure.com:443/|$COSMOS|" \
  base/analytics-service/configmap.yaml
```

`SERVICE_BUS_QUEUE_NAME` já bate com o default (`togglemasterqueue`) — não mexa.

## 4.3 Criar os Secrets

Os `secret.example.yaml` são modelos e ficam fora do kustomize de propósito —
segredo não vai para o Git. Os valores reais estão no Key Vault [APP CI]:

| Secret no Key Vault | Secret do Kubernetes | Chave |
| --- | --- | --- |
| `auth-service-database-url` | `auth-service-secret` | `DATABASE_URL` |
| `auth-master-key` | `auth-service-secret` | `MASTER_KEY` |
| `flag-service-database-url` | `flag-service-secret` | `DATABASE_URL` |
| `targeting-service-database-url` | `targeting-service-secret` | `DATABASE_URL` |
| `redis-url` | `evaluation-service-secret` | `REDIS_URL` |
| `evaluation-service-api-key` | `evaluation-service-secret` | `SERVICE_API_KEY` |
| `servicebus-connection-string` | `evaluation-service-secret` | `SERVICE_BUS_CONNECTION_STRING` |
| `servicebus-connection-string` | `analytics-service-secret` | `SERVICE_BUS_CONNECTION_STRING` |
| `cosmos-key` | `analytics-service-secret` | `COSMOS_KEY` |

```bash
KV=$(cd ../IaC/env && terraform output -raw key_vault_app_name)
kv() { az keyvault secret show --vault-name "$KV" --name "$1" --query value -o tsv; }

kubectl create namespace toggle-apps --dry-run=client -o yaml | kubectl apply -f -

kubectl -n toggle-apps create secret generic auth-service-secret \
  --from-literal=DATABASE_URL="$(kv auth-service-database-url)" \
  --from-literal=MASTER_KEY="$(kv auth-master-key)"

kubectl -n toggle-apps create secret generic flag-service-secret \
  --from-literal=DATABASE_URL="$(kv flag-service-database-url)"

kubectl -n toggle-apps create secret generic targeting-service-secret \
  --from-literal=DATABASE_URL="$(kv targeting-service-database-url)"

kubectl -n toggle-apps create secret generic evaluation-service-secret \
  --from-literal=REDIS_URL="$(kv redis-url)" \
  --from-literal=SERVICE_API_KEY="$(kv evaluation-service-api-key)" \
  --from-literal=SERVICE_BUS_CONNECTION_STRING="$(kv servicebus-connection-string)"

kubectl -n toggle-apps create secret generic analytics-service-secret \
  --from-literal=SERVICE_BUS_CONNECTION_STRING="$(kv servicebus-connection-string)" \
  --from-literal=COSMOS_KEY="$(kv cosmos-key)"
```

Alternativa sem `kubectl create secret`: o cluster já tem o addon
`key_vault_secrets_provider`, então dá para montar os segredos por
`SecretProviderClass`. O client ID da identidade está em
`terraform output -raw aks_secrets_provider_client_id`.

## 4.4 Instalar o Argo CD

O Terraform cria o cluster, não instala o Argo.

```bash
kubectl create namespace argocd
kubectl -n argocd apply -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd wait --for=condition=available deployment --all --timeout=300s

# senha inicial do admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

O `cicdpool` tem taint `workload=cicd:NoSchedule`. Sem tolerância o Argo sobe no
`apppool` — funciona, mas some a separação App / CI-CD do diagrama. Para
respeitá-la, adicione aos deployments `argocd-server`, `argocd-repo-server` e
`argocd-application-controller`:

```yaml
tolerations:
  - key: workload
    operator: Equal
    value: cicd
    effect: NoSchedule
nodeSelector:
  workload: cicd
```

## 4.5 Registrar o repositório e aplicar o root app

```bash
# commite e dê push nas mudanças das partes 4.1 e 4.2 ANTES disto:
# o Argo lê do Git, não do disco
git add -A && git commit -m "aponta para o ambiente novo" && git push

argocd repo add 'https://Oh20Tony@dev.azure.com/Oh20Tony/FIAP%20-%20TechChallenge/_git/TCF3%20-%20K8S' \
  --username <user> --password <PAT>

kubectl -n argocd apply -f argocd/root-app.yaml
```

## 4.6 Rodar as migrations

Os migration jobs ficam fora do kustomize de propósito — migração é operação
imperativa e ordenada, não estado desejado. Eles usam `psql` contra o
`DATABASE_URL` do Secret, então dependem da Parte 4.3:

```bash
kubectl -n toggle-apps apply -f base/auth-service/migration-job.yaml
kubectl -n toggle-apps apply -f base/flag-service/migration-job.yaml
kubectl -n toggle-apps apply -f base/targeting-service/migration-job.yaml

kubectl -n toggle-apps get jobs
```

## 4.7 Verificar

```bash
kubectl -n toggle-apps get pods
kubectl -n toggle-apps get ingress togglemaster-ingress    # IP público do App Gateway
```

A coleção Postman está em `../app/postman/ToggleMaster.postman_collection.json`.

---

# Parte 5 — Pendências de segurança

## 5.1 Rotacionar as credenciais expostas

`../app/.env/DBCredentials.txt` e `../app/.env/ServiceBusConnection.txt` estão
versionados com chave do Cosmos, chave do Redis e senhas em texto claro.

O ambiente novo não herda nada disso — Cosmos, Redis e Service Bus são recursos
novos, com chaves novas, e a senha do PostgreSQL é gerada pelo Terraform. O
vazamento fica restrito ao ambiente antigo. O que fazer:

1. Desligue ou destrua o ambiente antigo.
2. Apague os dois arquivos **e o histórico deles** (`git filter-repo`) — apagar
   só o arquivo não remove do histórico do Git.
3. Se o ambiente antigo tiver de continuar de pé, rotacione as chaves:
   `az cosmosdb keys regenerate`, `az redis regenerate-keys`,
   `az servicebus namespace authorization-rule keys renew`.

## 5.2 Atualizar o script de liga/desliga

`../app/scripts/env.sh` aponta para os nomes antigos. Ajuste no topo do arquivo:

```bash
AKS_NAME="<terraform output -raw aks_cluster_name>"
AKS_RG="<terraform output -raw resource_group_name>"
NAMESPACE="toggle-apps"
PG_SERVERS=(<terraform output -json postgres_server_names | jq -r '.[]'>)
```

Depois: `bash scripts/env.sh down` entre apresentações. Redis, Cosmos e Service
Bus não têm "stop" — continuam custando.

---

# Referência

## Outputs

```bash
cd IaC/env
terraform output                                  # todos os não-sensíveis
terraform output -raw  acr_login_server
terraform output -raw  cosmos_endpoint
terraform output -json postgres_fqdns
terraform output -json database_urls              # sensível
terraform output -raw  redis_url                  # sensível
terraform output -raw  servicebus_connection_string
```

## Custo

Os defaults são de laboratório: `Standard_B2s` nos nodes, `B_Standard_B1ms` no
PostgreSQL, Redis Basic C0, Cosmos serverless, AKS no tier `Free`.

## Decisões que valem registrar

- **PostgreSQL com acesso público + firewall**, não private endpoint. É o que
  permite `DATABASE_URL` com FQDN e `sslmode=require`, o formato que a aplicação
  já usa, e mantém o `psql` da equipe funcionando para as migrations. Para
  fechar, troque por `delegated_subnet_id` + Private DNS Zone e mova as
  migrations para dentro do cluster.
- **Senha do PostgreSQL gerada pelo Terraform** (`random_password`) e gravada no
  Key Vault. Nenhuma senha no código.
- **Redis é Azure Cache for Redis**, não Managed Redis. A porta é `6380` e o
  host `.redis.cache.windows.net` — o output `redis_url` já sai no formato certo.
- **Key Vault com RBAC**, não access policies.
- **Provider azurerm na série 3.x** (`~> 3.116`), que é o que o projeto já
  pinava. A migração para 4.x é um passo separado e mexe em vários nomes de
  atributo.
- **Credenciais só por variável de ambiente.** O bloco `backend` do Terraform
  não aceita variáveis, então fixar credencial no código exigiria hardcode.
- **`storage_use_azuread` ligado no `bootstrap/`, não no `env/`.** No bootstrap
  ele é o que permite manter a chave compartilhada desligada no state. Já a
  Storage Account de observabilidade mantém a chave habilitada (as diagnostic
  settings do Azure Monitor arquivam por ela), então usar Entra ID para criar o
  container ali não fecharia nada — só adicionaria uma espera de RBAC.

## Verificação

```bash
terraform fmt -recursive -check
terraform validate          # em env/ e em bootstrap/
```

Se o VS Code marcar erro nos argumentos do bloco `module` em `env/main.tf`, é o
language server sem o índice do módulo: rode `terraform init` em `env/` e
recarregue a janela (`Developer: Reload Window`). O `.terraform/` é local e já
está no `.gitignore`.
