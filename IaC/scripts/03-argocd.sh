#!/bin/sh
# =============================================================================
# Parte 4.4 e 4.5 do README: instalar o Argo CD no AKS, registrar o repositório
# GitOps e aplicar o App-of-Apps.
#
# O Terraform cria o cluster; o Argo CD é dia-1 do cluster, não infraestrutura
# do Azure. Ficou fora do Terraform de propósito: o provider helm/kubernetes
# precisaria ser configurado a partir de atributos do próprio AKS, o que quebra
# `plan` e `destroy` quando o cluster não existe — e este ambiente é destruído
# entre as sessões de trabalho (ver "Custo" no README).
#
# Idempotente: pode rodar em cluster limpo ou em cluster que já tem Argo CD.
#
# Roda no container mcr.microsoft.com/azure-cli (precisa de az e kubectl).
#
# Entradas:
#   GITOPS_DIR       clone do repositório TCF3 - K8S (para o root-app.yaml)
#   GITOPS_USER      usuário do Azure DevOps         } registro do repo no Argo;
#   GITOPS_PAT       personal access token           } vazio = pula o registro
#   ARGOCD_VERSION   tag do manifesto. Default 'stable'.
#   POOL_CICD        'true' se o cicdpool estiver ligado no toggle.tfvars.
# =============================================================================

. "$(dirname "$0")/_comum.sh"

carregar_ambiente
preparar_kubeconfig

ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
ARGOCD_TIMEOUT="${ARGOCD_TIMEOUT:-600s}"
POOL_CICD="${POOL_CICD:-false}"
GITOPS_DIR="${GITOPS_DIR:-}"

# 'stable' é o default porque sempre resolve. Para builds reprodutíveis, fixe
# uma tag (ARGOCD_VERSION=v2.13.2) — o manifesto muda sem aviso em 'stable'.
MANIFESTO="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

###############################################################################
# 1. Instalação
###############################################################################

garantir_namespace "$NAMESPACE_ARGOCD"

log "Instalando Argo CD (${ARGOCD_VERSION})"
info "$MANIFESTO"

# --server-side, e não o apply comum: as CRDs do Argo CD estouram o limite de
# 262144 bytes da anotação last-applied-configuration, e o apply client-side
# falha com "metadata.annotations: Too long" na segunda execução.
# --force-conflicts porque o próprio Argo CD passa a gerenciar campos dos seus
# manifestos depois de subir.
kubectl -n "$NAMESPACE_ARGOCD" apply \
    --server-side --force-conflicts \
    -f "$MANIFESTO"

###############################################################################
# 2. Node pool de CI/CD (opcional)
###############################################################################
# O cicdpool sobe com taint workload=cicd:NoSchedule. Tolerância sozinha não
# basta: sem nodeSelector o Argo CD continua caindo no apppool. Por isso os dois.

if [ "$POOL_CICD" = 'true' ]; then
    log 'Fixando o Argo CD no cicdpool'
    PATCH_CICD='{"spec":{"template":{"spec":{"nodeSelector":{"workload":"cicd"},"tolerations":[{"key":"workload","operator":"Equal","value":"cicd","effect":"NoSchedule"}]}}}}'
    for alvo in deployment/argocd-server deployment/argocd-repo-server statefulset/argocd-application-controller; do
        kubectl -n "$NAMESPACE_ARGOCD" patch "$alvo" --type=strategic -p "$PATCH_CICD" >/dev/null
        info "$alvo"
    done
fi

###############################################################################
# 3. Esperar subir
###############################################################################

log "Aguardando o Argo CD ficar disponível (timeout ${ARGOCD_TIMEOUT})"

# As Applications só podem ser aplicadas depois que a CRD existir de fato.
kubectl wait --for=condition=established --timeout=120s \
    crd/applications.argoproj.io crd/appprojects.argoproj.io

kubectl -n "$NAMESPACE_ARGOCD" wait --for=condition=available \
    deployment --all --timeout="$ARGOCD_TIMEOUT"

# O application-controller é StatefulSet, não Deployment: o wait acima não o pega.
kubectl -n "$NAMESPACE_ARGOCD" rollout status \
    statefulset/argocd-application-controller --timeout="$ARGOCD_TIMEOUT"

###############################################################################
# 4. Registrar o repositório GitOps
###############################################################################
# Registro declarativo (Secret com a label argocd.argoproj.io/secret-type), e
# não `argocd repo add`: dispensa o CLI do Argo e o login no servidor.
#
# A URL tem que ser IDÊNTICA à do repoURL das Applications — com o prefixo
# `usuario@` e os espaços em %20. URL diferente = o Argo não casa a credencial
# e a Application fica em "repository not accessible".

REPO_URL="${GITOPS_REPO_URL:-}"
if [ -z "$REPO_URL" ] && [ -n "$GITOPS_DIR" ] && [ -f "${GITOPS_DIR}/argocd/root-app.yaml" ]; then
    REPO_URL=$(grep -m1 'repoURL:' "${GITOPS_DIR}/argocd/root-app.yaml" \
        | sed -e 's/.*repoURL:[[:space:]]*//' | tr -d "'\"" | tr -d '[:space:]')
fi

if [ -n "${GITOPS_PAT:-}" ] && [ -n "$REPO_URL" ]; then
    log 'Registrando o repositório GitOps no Argo CD'
    info "$REPO_URL"
    kubectl -n "$NAMESPACE_ARGOCD" create secret generic repo-gitops \
        --from-literal=type=git \
        --from-literal=url="$REPO_URL" \
        --from-literal=username="${GITOPS_USER:-jenkins}" \
        --from-literal=password="$GITOPS_PAT" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # `create secret generic` não aceita label; ela vai num segundo passo.
    kubectl -n "$NAMESPACE_ARGOCD" label secret repo-gitops \
        argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
    info 'secret repo-gitops aplicado'
else
    aviso 'GITOPS_PAT vazio ou repoURL não encontrado: repositório NÃO registrado.'
    aviso 'As Applications ficarão em "repository not accessible" até o registro.'
fi

###############################################################################
# 5. App-of-Apps
###############################################################################
# A única Application aplicada à mão. Daqui em diante, adicionar app = commitar
# um arquivo em argocd/apps/ do repositório GitOps.

if [ -n "$GITOPS_DIR" ] && [ -f "${GITOPS_DIR}/argocd/root-app.yaml" ]; then
    log 'Aplicando o root-app (App-of-Apps)'
    kubectl apply -f "${GITOPS_DIR}/argocd/root-app.yaml"
else
    aviso 'root-app.yaml não encontrado: App-of-Apps não aplicado.'
fi

###############################################################################
# 6. Senha inicial do admin
###############################################################################
# Guardada no Key Vault [Infra CI/CD], não impressa no log — o log de build fica
# legível para qualquer um com acesso de leitura ao job.
#
# O Terraform popula esse cofre com `for_each`, que não remove segredos que ele
# não gerencia: gravar aqui não vira drift no próximo apply.

SENHA=$(kubectl -n "$NAMESPACE_ARGOCD" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [ -n "$SENHA" ]; then
    az keyvault secret set \
        --vault-name "$KEY_VAULT_INFRA_NAME" \
        --name argocd-admin-password \
        --value "$SENHA" \
        --only-show-errors --output none
    log 'Senha inicial do admin gravada no Key Vault [Infra CI/CD]'
    info "az keyvault secret show --vault-name ${KEY_VAULT_INFRA_NAME} --name argocd-admin-password --query value -o tsv"
else
    aviso 'argocd-initial-admin-secret não existe (senha já trocada?). Nada gravado no cofre.'
fi

###############################################################################
# 7. Como acessar
###############################################################################
# Sem Ingress e sem LoadBalancer de propósito: o argocd-server fica ClusterIP e
# o acesso é por port-forward. Nada do Argo CD exposto na internet.

log 'Argo CD pronto'
cat <<TXT

    Acesso (o Service e ClusterIP - nao ha endereco publico):

      az aks get-credentials -g ${RESOURCE_GROUP_NAME} -n ${AKS_CLUSTER_NAME} --overwrite-existing
      kubectl -n ${NAMESPACE_ARGOCD} port-forward svc/argocd-server 8080:443

      https://localhost:8080   usuario: admin

TXT

kubectl -n "$NAMESPACE_ARGOCD" get pods
kubectl -n "$NAMESPACE_ARGOCD" get applications 2>/dev/null || true
