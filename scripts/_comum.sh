#!/bin/sh
# =============================================================================
# Funções compartilhadas pelos scripts de bootstrap do ambiente.
#
# POSIX sh de propósito: o container mcr.microsoft.com/azure-cli, onde estes
# scripts rodam no pipeline, não garante bash. Nada de arrays nem de [[ ]].
#
# Este arquivo é sourced, não executado:
#     . "$(dirname "$0")/_comum.sh"
# =============================================================================

# Nunca ligue `set -x` aqui: os scripts manipulam senha do PostgreSQL, chave do
# Cosmos e connection string do Service Bus. O rastro iria inteiro para o log
# do Jenkins.
set -eu

# --- Diretórios ---------------------------------------------------------------
# WORKSPACE é definido pelo Jenkins. Fora dele, cai no diretório atual.
WORKSPACE="${WORKSPACE:-$(pwd)}"

# kubeconfig no workspace, não em ~/.kube: cada `docker run --rm` é um container
# novo, então o HOME não sobrevive entre as etapas — o workspace sim.
KUBECONFIG="${KUBECONFIG:-${WORKSPACE}/.kube/config}"
export KUBECONFIG

# Onde o kubectl baixado pelo `az aks install-cli` fica. No workspace para ser
# baixado uma vez só e reaproveitado pelas etapas seguintes.
BIN_DIR="${BIN_DIR:-${WORKSPACE}/bin}"
PATH="${BIN_DIR}:${PATH}"
export PATH

# Arquivo com as coordenadas do ambiente (ver carregar_ambiente).
AMBIENTE_ENV="${AMBIENTE_ENV:-${WORKSPACE}/ambiente.env}"

# Diretório do root module do Terraform, usado só quando AMBIENTE_ENV não existe.
TF_DIR="${TF_DIR:-$(cd "$(dirname "$0")/../env" 2>/dev/null && pwd || echo '')}"

NAMESPACE_APPS="${NAMESPACE_APPS:-toggle-apps}"
NAMESPACE_ARGOCD="${NAMESPACE_ARGOCD:-argocd}"

# --- Log ----------------------------------------------------------------------

log()   { printf '\n=== %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
aviso() { printf '    AVISO: %s\n' "$*" >&2; }
erro()  { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

# Falha se a variável nomeada estiver vazia. Recebe o NOME, não o valor, para
# não expandir segredo em argumento de comando.
exigir_var() {
    # shellcheck disable=SC2154
    eval "_v=\${$1:-}"
    [ -n "$_v" ] || erro "variável $1 não definida."
}

exigir_comando() {
    command -v "$1" >/dev/null 2>&1 || erro "comando '$1' não encontrado no PATH."
}

# --- Coordenadas do ambiente --------------------------------------------------
#
# Os scripts precisam saber o nome do Resource Group, do AKS, do ACR etc. Duas
# fontes, nesta ordem:
#
#   1. $AMBIENTE_ENV, gerado pelo pipeline logo após o apply. É o caminho normal:
#      só o container do Terraform tem terraform e acesso ao state.
#   2. `terraform output` em $TF_DIR, para quem roda os scripts na máquina local.

CHAVES_AMBIENTE='RESOURCE_GROUP_NAME AKS_CLUSTER_NAME ACR_NAME ACR_LOGIN_SERVER COSMOS_ENDPOINT KEY_VAULT_APP_NAME KEY_VAULT_INFRA_NAME'

carregar_ambiente() {
    if [ ! -f "$AMBIENTE_ENV" ]; then
        info "$AMBIENTE_ENV não existe; gerando a partir de terraform output."
        gerar_ambiente_env "$AMBIENTE_ENV"
    fi

    # shellcheck disable=SC1090
    . "$AMBIENTE_ENV"

    for _chave in $CHAVES_AMBIENTE; do
        exigir_var "$_chave"
    done

    info "Ambiente: ${RESOURCE_GROUP_NAME} / AKS ${AKS_CLUSTER_NAME}"
}

# Escreve o ambiente.env a partir dos outputs do root module. Só valores não
# sensíveis: os segredos continuam vindo do Key Vault, nunca de arquivo.
gerar_ambiente_env() {
    _destino="$1"
    exigir_comando terraform
    [ -n "$TF_DIR" ] && [ -d "$TF_DIR" ] || erro "TF_DIR não aponta para o root module do Terraform."

    log "Coletando outputs do Terraform em ${TF_DIR}"
    {
        printf 'RESOURCE_GROUP_NAME=%s\n'  "$(terraform -chdir="$TF_DIR" output -raw resource_group_name)"
        printf 'AKS_CLUSTER_NAME=%s\n'     "$(terraform -chdir="$TF_DIR" output -raw aks_cluster_name)"
        printf 'ACR_NAME=%s\n'             "$(terraform -chdir="$TF_DIR" output -raw acr_name)"
        printf 'ACR_LOGIN_SERVER=%s\n'     "$(terraform -chdir="$TF_DIR" output -raw acr_login_server)"
        printf 'COSMOS_ENDPOINT=%s\n'      "$(terraform -chdir="$TF_DIR" output -raw cosmos_endpoint)"
        printf 'KEY_VAULT_APP_NAME=%s\n'   "$(terraform -chdir="$TF_DIR" output -raw key_vault_app_name)"
        printf 'KEY_VAULT_INFRA_NAME=%s\n' "$(terraform -chdir="$TF_DIR" output -raw key_vault_infra_name)"
    } > "$_destino"
}

# --- Azure / Kubernetes -------------------------------------------------------

# O container do azure-cli não traz kubectl. `az aks install-cli` é o caminho
# suportado pela Microsoft e também instala o kubelogin.
garantir_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        return 0
    fi
    log "Instalando kubectl em ${BIN_DIR}"
    mkdir -p "$BIN_DIR"
    az aks install-cli \
        --install-location "${BIN_DIR}/kubectl" \
        --kubelogin-install-location "${BIN_DIR}/kubelogin" \
        --only-show-errors >/dev/null
    exigir_comando kubectl
}

# Login no Azure com a App Registration e kubeconfig do cluster.
#
# `az login -p` expõe o secret na linha de comando (visível em `ps` no host).
# Aceitável aqui porque o container é efêmero e dedicado ao build; se o agente
# passar a ser compartilhado, troque por federated credential (ARM_USE_OIDC).
preparar_kubeconfig() {
    exigir_comando az
    garantir_kubectl

    if ! az account show >/dev/null 2>&1; then
        exigir_var ARM_CLIENT_ID
        exigir_var ARM_CLIENT_SECRET
        exigir_var ARM_TENANT_ID
        log 'Autenticando no Azure (service principal)'
        az login --service-principal \
            -u "$ARM_CLIENT_ID" \
            -p "$ARM_CLIENT_SECRET" \
            --tenant "$ARM_TENANT_ID" \
            --only-show-errors --output none
    fi

    if [ -n "${ARM_SUBSCRIPTION_ID:-}" ]; then
        az account set --subscription "$ARM_SUBSCRIPTION_ID" --only-show-errors
    fi

    log "Obtendo credenciais do cluster ${AKS_CLUSTER_NAME}"
    mkdir -p "$(dirname "$KUBECONFIG")"
    az aks get-credentials \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing \
        --only-show-errors

    kubectl cluster-info >/dev/null \
        || erro "kubeconfig obtido mas o cluster não respondeu. Verifique se o AKS está ligado."
}

# Lê um segredo do Key Vault [APP CI]. Falha em vez de devolver vazio: um valor
# vazio aqui viraria um Secret do Kubernetes vazio, e o pod só quebraria depois,
# longe da causa.
ler_segredo() {
    _valor=$(az keyvault secret show \
        --vault-name "$KEY_VAULT_APP_NAME" \
        --name "$1" \
        --query value -o tsv --only-show-errors 2>/dev/null) || _valor=''
    [ -n "$_valor" ] || erro "segredo '$1' não encontrado em ${KEY_VAULT_APP_NAME}."
    printf '%s' "$_valor"
}

# Cria ou atualiza um namespace sem falhar se ele já existir.
garantir_namespace() {
    kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    info "namespace $1 pronto"
}
