#!/bin/sh
# =============================================================================
# Parte 4.1 e 4.2 do README: apontar os manifestos do repositório GitOps para
# o ambiente recém-criado (ACR e endpoint do Cosmos) e publicar a mudança.
#
# Por que isto precisa existir: o Argo CD lê do Git, não do disco. Um ambiente
# novo tem ACR e Cosmos novos (o `name_suffix` aleatório muda a cada state
# zerado), então sem este passo os pods sobem em ImagePullBackOff apontando
# para o registry do ambiente anterior.
#
# Roda no próprio agente Jenkins (só precisa de git e sed), não em container.
#
# Entradas:
#   GITOPS_DIR       clone do repositório TCF3 - K8S            (obrigatório)
#   ACR_LOGIN_SERVER } vêm do ambiente.env via carregar_ambiente
#   COSMOS_ENDPOINT  }
#   PUBLICAR         'true' faz commit e push. Default 'false'.
#   GITOPS_BRANCH    branch de destino do push. Default 'main'.
# =============================================================================

. "$(dirname "$0")/_comum.sh"

carregar_ambiente

GITOPS_DIR="${GITOPS_DIR:-}"
PUBLICAR="${PUBLICAR:-false}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"

[ -n "$GITOPS_DIR" ] || erro 'GITOPS_DIR não definido.'
[ -d "${GITOPS_DIR}/base" ] || erro "GITOPS_DIR='${GITOPS_DIR}' não parece o repositório de manifestos."
exigir_comando git

cd "$GITOPS_DIR"

# --- ACR ---------------------------------------------------------------------
# O kustomize casa a imagem pelo campo `name`, então o registry aparece em DOIS
# lugares e trocar só o deployment não basta — o overlay continuaria com o
# `images[].name` antigo e a substituição simplesmente não seria aplicada.
log "Apontando as imagens para ${ACR_LOGIN_SERVER}"

_antes=$(grep -rhoE '[a-z0-9]+\.azurecr\.io' base overlays 2>/dev/null | sort -u | tr '\n' ' ')
info "registries encontrados hoje: ${_antes:-nenhum}"

sed -i -E "s|[a-z0-9]+\.azurecr\.io|${ACR_LOGIN_SERVER}|g" base/*/deployment.yaml
sed -i -E "s|[a-z0-9]+\.azurecr\.io|${ACR_LOGIN_SERVER}|g" overlays/*/*/kustomization.yaml

_sobrou=$(grep -rhoE '[a-z0-9]+\.azurecr\.io' base overlays 2>/dev/null | sort -u | grep -v "^${ACR_LOGIN_SERVER}$" || true)
[ -z "$_sobrou" ] || erro "ainda há registries de outro ambiente nos manifestos: ${_sobrou}"

info "$(grep -rlF "$ACR_LOGIN_SERVER" base overlays | wc -l) arquivo(s) apontando para o ACR novo"

# --- Cosmos DB ----------------------------------------------------------------
# Substituição pela CHAVE, não pelo valor antigo: assim o script é idempotente e
# funciona mesmo que o endpoint atual já seja outro.
log "Apontando o analytics-service para ${COSMOS_ENDPOINT}"
sed -i -E "s|^([[:space:]]*COSMOS_ENDPOINT:[[:space:]]*).*|\1\"${COSMOS_ENDPOINT}\"|" \
    base/analytics-service/configmap.yaml
grep -q "$COSMOS_ENDPOINT" base/analytics-service/configmap.yaml \
    || erro 'a substituição do COSMOS_ENDPOINT não pegou — confira o configmap do analytics-service.'

# SERVICE_BUS_QUEUE_NAME já bate com o default do Terraform (togglemasterqueue),
# por isso não entra aqui.

# --- Publicar -----------------------------------------------------------------
if git diff --quiet; then
    log 'Manifestos já apontavam para este ambiente — nada a publicar.'
    exit 0
fi

git --no-pager diff --stat

if [ "$PUBLICAR" != 'true' ]; then
    log 'PUBLICAR != true: alterações ficam só no workspace.'
    aviso 'O Argo CD lê do Git. Sem push, ele vai sincronizar os manifestos ANTIGOS.'
    exit 0
fi

log "Publicando em origin/${GITOPS_BRANCH}"
git config user.email "${GIT_EMAIL:-jenkins@ci.local}"
git config user.name  "${GIT_NAME:-Jenkins IaC}"
git add base overlays
git commit -m "infra: aponta manifestos para ${ACR_LOGIN_SERVER}"
git push origin "HEAD:${GITOPS_BRANCH}"
info 'push concluído'
