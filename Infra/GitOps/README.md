# GitOps — entrega contínua via ArgoCD

O ArgoCD só fala com a API do Kubernetes: ele reconcilia manifestos K8s do Git para o
cluster. Ele **não executa pipelines** e não provisiona infraestrutura Azure. Por isso a
divisão aqui é:

| Responsabilidade | Ferramenta | Onde |
|---|---|---|
| Provisionar Azure (VNET, NSG, VM, AKS) | Terraform + Azure DevOps | `pipeline-iac-homolog.yml`, `Mocktf/` |
| Build e push de imagem | Azure DevOps | `pipeline-cd-gitops.yml`, stage `Build` |
| Secrets e migrations | Azure DevOps | `pipeline-cd-gitops.yml`, stage `Prepare` |
| Deploy no AKS | **ArgoCD** | este diretório |

O pipeline não faz mais `kubectl apply` dos serviços. Ele para no Git: atualiza a tag da
imagem nos overlays e commita. Esse commit **é** o deploy — o ArgoCD detecta e sincroniza.

## Estrutura

```
Infra/
├── K8S_AKS/<serviço>/kustomization.yaml   # base: configmap + deployment + service
├── K8S_AKS/ingress/kustomization.yaml     # base: ingress
├── K8S_AKS/scaling/kustomization.yaml     # base: HPAs
└── GitOps/
    ├── prod/<serviço>/kustomization.yaml  # overlay: namespace + tag da imagem
    ├── prod/platform/kustomization.yaml   # overlay: ingress + HPAs
    └── argocd/
        ├── project.yaml                   # AppProject togglemaster
        ├── root-app.yaml                  # App-of-Apps
        └── applications/*.yaml            # 5 serviços + platform
```

Os overlays referenciam as bases por **diretório** (`../../../K8S_AKS/<serviço>`), não por
arquivo. Isso importa: o kustomize bloqueia carregar *arquivos* fora da raiz da
kustomization, mas diretórios com `kustomization.yaml` próprio são bases válidas. Assim
não é preciso afrouxar o `--load-restrictor` do ArgoCD.

## Bootstrap

1. Instalar o ArgoCD no cluster que vai hospedá-lo (hoje: `docker-desktop` local):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

2. Registrar a credencial do repositório. Os manifestos já apontam para
   `https://dev.azure.com/Oh20Tony/FIAP%20-%20TechChallenge/_git/FIAP%20-%20ToggleMaster%20F3`.

   Gere um PAT no Azure DevOps (*User settings → Personal Access Tokens*) com escopo
   **Code: Read** e crie o Secret direto no cluster — ele **não** vai para o Git:

```bash
kubectl -n argocd create secret generic repo-togglemaster \
  --from-literal=type=git \
  --from-literal=url='https://dev.azure.com/Oh20Tony/FIAP%20-%20TechChallenge/_git/FIAP%20-%20ToggleMaster%20F3' \
  --from-literal=username=Oh20Tony \
  --from-literal=password='<SEU_PAT>'

kubectl -n argocd label secret repo-togglemaster \
  argocd.argoproj.io/secret-type=repository
```

   A URL tem duas armadilhas: o remote do `git` traz o prefixo `Oh20Tony@`, que **não** pode
   entrar aqui, e os espaços do nome do projeto/repo vêm como `%20`. Essa string precisa ser
   idêntica no Secret, no `sourceRepos` do AppProject e no `repoURL` de cada Application.

3. Registrar o cluster de destino. **O ArgoCD roda em um cluster e entrega em outro**: ele
   está no `docker-desktop` local, e as aplicações vão para o AKS. Por isso as 6 Applications
   de workload têm `destination.server` apontando para o AKS, e só o `togglemaster-root` fica
   com `https://kubernetes.default.svc` — é lá que os objetos `Application` moram.

```bash
az login
az aks get-credentials --resource-group <RG-DO-AKS> --name <NOME-DO-AKS>
argocd cluster add <NOME-DO-CONTEXTO> --grpc-web
```

   O `argocd cluster add` cria um ServiceAccount no AKS e guarda o token. Confira que a URL
   registrada bate exatamente com o `destination.server` dos manifestos:

```bash
argocd cluster list --grpc-web
# esperado: https://fiaptc3-dns-l25hulwg.hcp.eastus.azmk8s.io:443
```

4. Aplicar o projeto e o App-of-Apps — os dois únicos manifestos aplicados à mão:

```bash
kubectl apply -f Infra/GitOps/argocd/project.yaml
kubectl apply -f Infra/GitOps/argocd/root-app.yaml
```

A partir daí o `togglemaster-root` cria as 6 Applications sozinho. Tudo o mais é Git.

> Os manifestos precisam estar **no remoto** antes deste passo. O ArgoCD lê do Git, não do
> disco: se `Infra/GitOps/` só existe localmente, o root app sincroniza vazio.

## Decisões que valem explicar

**Uma Application por serviço.** Dá rollback e health independentes: se o `flag-service`
quebra, você reverte só ele, sem tocar nos outros quatro.

**HPA separado do Deployment.** Os HPAs ficam na Application `platform`. Como o HPA altera
`spec.replicas` do Deployment, as Applications de `evaluation-service` e `analytics-service`
declaram `ignoreDifferences` nesse campo — sem isso o `selfHeal` reverteria o autoscaling a
cada sync e a Application ficaria permanentemente `OutOfSync`.

**Namespace via `managedNamespaceMetadata`.** O `00-namespaces.yaml` não entra nos overlays;
o namespace vem de `CreateNamespace=true` e o label `projeto: togglemaster` de
`managedNamespaceMetadata`. Isso evita que o arquivo do namespace fique fora de qualquer
kustomization na raiz do `K8S_AKS/`.

**Secrets fora do Git.** Nenhum secret real é versionado. Eles continuam vindo da stage
`Prepare` do pipeline, a partir de variáveis secretas do Azure DevOps. A evolução natural é
o External Secrets Operator lendo de um Azure Key Vault — o módulo `keyvault.tf` do Terraform
está vazio hoje, então esse passo ainda não tem de onde ler.

**Migrations fora do ArgoCD.** Migração de banco é operação imperativa e ordenada, não estado
desejado. Os `migration-job.yaml` ficam de fora das bases e continuam sendo aplicados pela
stage `Prepare`, antes da promoção da tag.

## Como um deploy acontece

```
push na main
   └─ Build     → imagem :$(Build.BuildId) no ACR
   └─ Prepare   → secrets + migrations no cluster
   └─ Promote   → kustomize edit set image + commit ***NO_CI*** na main
                     └─ ArgoCD detecta o commit e sincroniza
   └─ Verify    → argocd app wait --health --sync
```

O `***NO_CI***` na mensagem de commit e o `paths.exclude: Infra/GitOps/**` no trigger são as
duas barreiras contra loop infinito de pipeline.

**Rollback:** `git revert` do commit de promoção, ou `argocd app rollback <serviço>`.

## Pendências do repositório que afetam isto

Encontradas ao montar a estrutura, não corrigidas aqui:

- `pipeline-ci.yml` faz deploy no namespace `togglemaster`, mas os manifestos e o
  `azure-pipelines.yml` usam `toggle-apps`. Um dos dois está errado.
- `pipeline-ci.yml` usa o registry `acrtogglemaster.azurecr.io`; os deployments referenciam
  `fiapdevopsadegj.azurecr.io`. Os overlays adotaram o segundo, que é o que está nos manifestos.
- `azure-pipelines.yml` referencia `K8S_AKS/...` e `auth-service/db/init.sql`, caminhos que não
  existem na estrutura atual (`Infra/K8S_AKS/...` e `app/auth-service/db/...`). O
  `pipeline-cd-gitops.yml` já usa os caminhos corretos.
- `azure-pipelines.yml` e `pipeline-ci.yml` continuam com stages de deploy imperativo. Depois
  que o ArgoCD assumir, essas stages precisam ser removidas — dois donos aplicando os mesmos
  recursos entram em conflito com o `selfHeal`.

## Validação executada

Com kustomize v5:

- `kustomize build` nos 6 overlays — todos renderizam;
- serviços rendem ConfigMap + Deployment + Service, todos em `toggle-apps`;
- `platform` rende Ingress + 2 HPAs;
- loop de promoção do pipeline simulado com `kustomize edit set image` nos 5 serviços — a tag
  chega correta na imagem renderizada e os comentários do arquivo sobrevivem ao edit;
- YAML das 8 manifestos do ArgoCD e do `pipeline-cd-gitops.yml` — sintaticamente válidos.

Não foi possível validar contra um cluster ou um ArgoCD real daqui.
