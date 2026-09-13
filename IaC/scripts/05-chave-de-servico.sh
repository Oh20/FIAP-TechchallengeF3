#!/bin/sh
# =============================================================================
# Registra a SERVICE_API_KEY do evaluation-service no banco do auth-service.
#
# Por que isto precisa existir: o Terraform GERA a chave
# (evaluation-service-api-key no Key Vault) e o 02-k8s-secrets.sh a injeta no
# Secret do evaluation-service — mas o auth-service valida a chave procurando o
# SHA-256 dela na tabela api_keys, e nada nunca gravava essa linha.
#
# Sem este passo, com todo o resto no ar:
#   evaluation-service -> flag-service   (Authorization: Bearer <SERVICE_API_KEY>)
#   flag-service       -> auth /validate -> hash nao existe -> 401
#   evaluation-service -> /evaluate      -> 502 para TODA flag
#
# Depende do 02-k8s-secrets.sh (Secret com a DATABASE_URL do auth) e do
# 04-migrations.sh (a tabela api_keys precisa existir). Roda depois dos dois.
#
# Idempotente: o Job usa ON CONFLICT pelo key_hash.
#
# Roda no container mcr.microsoft.com/azure-cli (precisa de az e kubectl).
#
# Entradas:
#   GITOPS_DIR   clone do repositorio de manifestos (contem o service-key-job.yaml)
# =============================================================================

. "$(dirname "$0")/_comum.sh"

carregar_ambiente
preparar_kubeconfig

GITOPS_DIR="${GITOPS_DIR:-}"
SEED_TIMEOUT="${SEED_TIMEOUT:-180s}"

[ -n "$GITOPS_DIR" ] || erro 'GITOPS_DIR não definido (clone do repositório de manifestos).'

MANIFESTO="${GITOPS_DIR}/base/auth-service/service-key-job.yaml"
[ -f "$MANIFESTO" ] || erro "não encontrei ${MANIFESTO}."

garantir_namespace "$NAMESPACE_APPS"

###############################################################################
# 1. Hash da chave
###############################################################################
# O auth-service guarda hashAPIKey(chave) = SHA-256 em hex minusculo, 64
# caracteres (ver app/auth-service/key.go). Reproduzimos isso aqui.
#
# `printf '%s'` e nao `echo`: um \n a mais muda o hash inteiro e o 401 voltaria
# sem nenhuma pista do motivo.
#
# A chave em texto plano existe so nesta variavel, nunca em argumento de
# comando (visivel em `ps`) nem no log.

log 'Calculando o hash da chave de serviço'

_chave=$(ler_segredo evaluation-service-api-key)

if command -v sha256sum >/dev/null 2>&1; then
    _hash=$(printf '%s' "$_chave" | sha256sum | cut -d' ' -f1)
elif command -v openssl >/dev/null 2>&1; then
    _hash=$(printf '%s' "$_chave" | openssl dgst -sha256 -r | cut -d' ' -f1)
elif command -v python3 >/dev/null 2>&1; then
    _hash=$(CHAVE="$_chave" python3 -c \
        'import hashlib,os;print(hashlib.sha256(os.environ["CHAVE"].encode()).hexdigest())')
else
    erro 'nenhuma ferramenta de SHA-256 disponível (sha256sum, openssl ou python3).'
fi

_chave=''

# 64 hexadecimais minusculos, o mesmo formato que o key.go grava.
echo "$_hash" | grep -Eq '^[0-9a-f]{64}$' \
    || erro 'o hash calculado não tem o formato esperado (64 hex).'

info "hash calculado (prefixo $(echo "$_hash" | cut -c1-8)…)"

###############################################################################
# 2. Secret com o hash
###############################################################################
# O hash vai por Secret, e nao por argumento do Job: assim ele nao aparece no
# manifesto versionado nem em `kubectl get job -o yaml`.

kubectl -n "$NAMESPACE_APPS" create secret generic auth-service-key-seed \
    --from-literal=KEY_HASH="$_hash" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
info 'secret auth-service-key-seed aplicado'

###############################################################################
# 3. Rodar o Job
###############################################################################
# Job e imutavel: reaplicar por cima falha com "field is immutable". O delete
# antes resolve; o ttlSecondsAfterFinished do manifesto costuma deixar isso
# como no-op.

log 'Registrando a chave na tabela api_keys'

kubectl -n "$NAMESPACE_APPS" delete job auth-seed-service-key --ignore-not-found >/dev/null
kubectl -n "$NAMESPACE_APPS" apply -f "$MANIFESTO" >/dev/null

if kubectl -n "$NAMESPACE_APPS" wait --for=condition=complete \
    job/auth-seed-service-key --timeout="$SEED_TIMEOUT" >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE_APPS" logs job/auth-seed-service-key --tail=10 2>&1 | sed 's/^/      /' || true
    log 'Chave de serviço registrada'
else
    aviso 'auth-seed-service-key NÃO completou — logs abaixo:'
    kubectl -n "$NAMESPACE_APPS" logs job/auth-seed-service-key --tail=50 2>&1 | sed 's/^/      /' || true
    erro 'não foi possível registrar a chave de serviço. O /evaluate vai responder 502 até isto passar.'
fi
