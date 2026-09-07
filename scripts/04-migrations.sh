#!/bin/sh
# =============================================================================
# Parte 4.6 do README: rodar as migrations dos três PostgreSQL.
#
# Os migration jobs ficam fora do kustomize de propósito — migração é operação
# imperativa e ordenada, não estado desejado, então o Argo CD não deve
# reconciliá-la.
#
# Cada Job monta um ConfigMap <servico>-initsql com o db/init.sql do repositório
# da APLICAÇÃO. Esse ConfigMap não existe em lugar nenhum do repositório de
# manifestos: é gerado aqui, a partir do código-fonte.
#
# Depende do 02-k8s-secrets.sh: o Job lê DATABASE_URL do Secret do serviço.
#
# Roda no container mcr.microsoft.com/azure-cli (precisa de az e kubectl).
#
# Entradas:
#   APP_DIR      clone do repositório da aplicação (contém app/<servico>/db/init.sql)
#   GITOPS_DIR   clone do repositório de manifestos (contém os migration-job.yaml)
# =============================================================================

. "$(dirname "$0")/_comum.sh"

carregar_ambiente
preparar_kubeconfig

APP_DIR="${APP_DIR:-}"
GITOPS_DIR="${GITOPS_DIR:-}"
MIGRATION_TIMEOUT="${MIGRATION_TIMEOUT:-300s}"

[ -n "$APP_DIR" ]    || erro 'APP_DIR não definido (clone do repositório da aplicação).'
[ -n "$GITOPS_DIR" ] || erro 'GITOPS_DIR não definido (clone do repositório de manifestos).'

# Os três serviços com banco relacional. analytics (Cosmos) e evaluation (Redis)
# não têm schema para migrar.
SERVICOS='auth flag targeting'

garantir_namespace "$NAMESPACE_APPS"

###############################################################################
# 1. ConfigMaps com o init.sql
###############################################################################

log 'Gerando os ConfigMaps de schema a partir do repositório da aplicação'

for svc in $SERVICOS; do
    sql="${APP_DIR}/app/${svc}-service/db/init.sql"
    [ -f "$sql" ] || erro "não encontrei ${sql}."
    kubectl -n "$NAMESPACE_APPS" create configmap "${svc}-initsql" \
        --from-file=init.sql="$sql" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    info "${svc}-initsql"
done

###############################################################################
# 2. Rodar os Jobs
###############################################################################
# Job é imutável: reaplicar por cima falha com "field is immutable". Por isso o
# delete antes. O ttlSecondsAfterFinished dos manifestos (600s) também apaga o
# Job sozinho depois de um tempo, então o delete costuma ser no-op.
#
# Os três init.sql são idempotentes (CREATE TABLE IF NOT EXISTS, CREATE OR
# REPLACE FUNCTION, DROP TRIGGER IF EXISTS): rodar de novo não destrói dados.

log 'Aplicando os migration jobs'

for svc in $SERVICOS; do
    manifesto="${GITOPS_DIR}/base/${svc}-service/migration-job.yaml"
    [ -f "$manifesto" ] || erro "não encontrei ${manifesto}."
    kubectl -n "$NAMESPACE_APPS" delete job "${svc}-migrate" --ignore-not-found >/dev/null
    kubectl -n "$NAMESPACE_APPS" apply -f "$manifesto" >/dev/null
    info "${svc}-migrate criado"
done

###############################################################################
# 3. Esperar e diagnosticar
###############################################################################

log "Aguardando as migrations (timeout ${MIGRATION_TIMEOUT} por serviço)"

falhou=''
for svc in $SERVICOS; do
    if kubectl -n "$NAMESPACE_APPS" wait --for=condition=complete \
        "job/${svc}-migrate" --timeout="$MIGRATION_TIMEOUT" >/dev/null 2>&1; then
        info "${svc}-migrate OK"
    else
        aviso "${svc}-migrate NÃO completou — logs abaixo:"
        kubectl -n "$NAMESPACE_APPS" logs "job/${svc}-migrate" --tail=50 2>&1 | sed 's/^/      /' || true
        falhou="${falhou} ${svc}"
    fi
done

[ -z "$falhou" ] || erro "migrations falharam:${falhou}"

log 'Migrations concluídas'
kubectl -n "$NAMESPACE_APPS" get jobs
