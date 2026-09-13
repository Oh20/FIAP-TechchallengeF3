#!/bin/sh
# =============================================================================
# Roda as quatro etapas de bootstrap na ordem, para quem está na máquina local.
#
# No Jenkins as etapas são chamadas uma a uma pelo pipeline_infra.jenkinsfile,
# porque cada uma roda num container diferente: a 01 só precisa de git (roda no
# agente), as outras precisam de az e kubectl.
#
# Pré-requisitos aqui: az, kubectl, git e (se não houver ambiente.env) terraform.
#
#   export ARM_TENANT_ID=... ARM_SUBSCRIPTION_ID=...
#   export ARM_CLIENT_ID=... ARM_CLIENT_SECRET=...
#
#   GITOPS_DIR=../infra APP_DIR=../app ./scripts/bootstrap.sh
#
# A ordem importa:
#   01  aponta os manifestos para o ACR/Cosmos novos e publica     (antes do Argo)
#   02  cria os Secrets do Kubernetes a partir do Key Vault        (antes de tudo
#                                                                   que sobe pod)
#   03  instala o Argo CD e aplica o App-of-Apps
#   04  roda as migrations, que leem DATABASE_URL dos Secrets da 02
#   05  registra a SERVICE_API_KEY na tabela api_keys, que a 04 acabou de criar
# =============================================================================

set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"

ETAPAS="${ETAPAS:-01 02 03 04 05}"

for etapa in $ETAPAS; do
    script=$(ls "${DIR}/${etapa}"-*.sh 2>/dev/null | head -1)
    [ -n "$script" ] || { printf 'ERRO: etapa %s não encontrada em %s\n' "$etapa" "$DIR" >&2; exit 1; }
    printf '\n\n########## %s ##########\n' "$(basename "$script")"
    sh "$script"
done

printf '\n\nBootstrap concluído.\n'
