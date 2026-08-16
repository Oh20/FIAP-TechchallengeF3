#!/usr/bin/env bash
#
# Liga/desliga o ambiente inteiro do ToggleMaster para economizar custo entre
# apresentacoes: Application Gateway + AKS + PostgreSQL Flexible (x3).
#
# Uso (Azure Cloud Shell ou maquina com Azure CLI logada):
#   bash scripts/env.sh up       # liga tudo (antes de apresentar)
#   bash scripts/env.sh down     # desliga tudo (economiza depois de apresentar)
#   bash scripts/env.sh status   # mostra o estado de cada recurso + IP
#
# Observacoes:
# - Redis, Cosmos e Service Bus NAO tem "stop"; ficam ligados (custo continua).
# - Postgres Flexible parado RELIGA sozinho apos ~7 dias (limite da Azure).
# - Nada e apagado: os dados e a config persistem.

set -uo pipefail

# ---- Ajuste se necessario ----
AKS_NAME="togglemaster-aks"
AKS_RG="AKS_RG_LAB"
NAMESPACE="toggle-apps"
PG_SERVERS=("authservice-db" "flagservice-db" "targetingservice-db")
# ------------------------------

# Resolve o App Gateway gerenciado pelo AGIC a partir do AKS.
resolve_appgw() {
  APPGW_ID=$(az aks show -n "$AKS_NAME" -g "$AKS_RG" \
    --query "addonProfiles.ingressApplicationGateway.config.effectiveApplicationGatewayId" -o tsv 2>/dev/null || true)
  if [ -z "${APPGW_ID:-}" ] || [ "$APPGW_ID" = "null" ]; then
    APPGW_ID=$(az aks show -n "$AKS_NAME" -g "$AKS_RG" \
      --query "addonProfiles.ingressApplicationGateway.config.applicationGatewayId" -o tsv 2>/dev/null || true)
  fi
  if [ -n "${APPGW_ID:-}" ] && [ "$APPGW_ID" != "null" ]; then
    APPGW_NAME="$(basename "$APPGW_ID")"
    APPGW_RG="$(echo "$APPGW_ID" | sed -n 's#.*/resourceGroups/\([^/]*\)/.*#\1#p')"
  else
    APPGW_NAME=""; APPGW_RG=""
  fi
}

# Descobre o RG de um servidor Postgres pelo nome.
pg_rg() {
  az postgres flexible-server list --query "[?name=='$1'].resourceGroup | [0]" -o tsv 2>/dev/null
}

show_ip() {
  [ -z "${APPGW_NAME:-}" ] && return
  local pipid ip
  pipid=$(az network application-gateway show -n "$APPGW_NAME" -g "$APPGW_RG" \
    --query "frontendIPConfigurations[?publicIPAddress].publicIPAddress.id | [0]" -o tsv 2>/dev/null)
  if [ -n "${pipid:-}" ] && [ "$pipid" != "null" ]; then
    ip=$(az network public-ip show --ids "$pipid" --query ipAddress -o tsv 2>/dev/null)
    echo "   IP publico: ${ip:-<indisponivel>}"
  fi
}

resolve_appgw

case "${1:-}" in
  up|start)
    echo "== Ligando o ambiente =="

    echo ">> Iniciando PostgreSQL..."
    for s in "${PG_SERVERS[@]}"; do
      rg=$(pg_rg "$s")
      if [ -n "$rg" ]; then
        az postgres flexible-server start -n "$s" -g "$rg" 2>/dev/null \
          && echo "   $s: iniciando" || echo "   $s: ja ligado ou erro (ok)"
      else
        echo "   $s: nao encontrado (ajuste PG_SERVERS)"
      fi
    done

    echo ">> Iniciando AKS (pode levar alguns minutos)..."
    az aks start -n "$AKS_NAME" -g "$AKS_RG" || echo "   AKS ja ligado ou erro (ok)"

    echo ">> Aguardando os pods ficarem prontos..."
    az aks get-credentials -n "$AKS_NAME" -g "$AKS_RG" --overwrite-existing >/dev/null 2>&1 || true
    kubectl wait --for=condition=available deployment --all -n "$NAMESPACE" --timeout=300s || \
      echo "   (alguns pods ainda subindo; siga mesmo assim)"

    if [ -n "${APPGW_NAME:-}" ]; then
      echo ">> Iniciando Application Gateway..."
      az network application-gateway start -n "$APPGW_NAME" -g "$APPGW_RG" || echo "   Gateway ja ligado ou erro (ok)"
    fi

    echo "== Ambiente LIGADO =="
    show_ip
    ;;

  down|stop)
    echo "== Desligando o ambiente =="

    if [ -n "${APPGW_NAME:-}" ]; then
      echo ">> Parando Application Gateway..."
      az network application-gateway stop -n "$APPGW_NAME" -g "$APPGW_RG" || echo "   ja parado ou erro (ok)"
    fi

    echo ">> Parando AKS..."
    az aks stop -n "$AKS_NAME" -g "$AKS_RG" || echo "   ja parado ou erro (ok)"

    echo ">> Parando PostgreSQL..."
    for s in "${PG_SERVERS[@]}"; do
      rg=$(pg_rg "$s")
      if [ -n "$rg" ]; then
        az postgres flexible-server stop -n "$s" -g "$rg" 2>/dev/null \
          && echo "   $s: parando" || echo "   $s: ja parado ou erro (ok)"
      fi
    done

    echo "== Ambiente DESLIGADO (Redis/Cosmos/Service Bus seguem ligados) =="
    ;;

  status)
    echo "== Status =="
    aks_state=$(az aks show -n "$AKS_NAME" -g "$AKS_RG" --query "powerState.code" -o tsv 2>/dev/null)
    echo "AKS ($AKS_NAME): ${aks_state:-desconhecido}"

    if [ -n "${APPGW_NAME:-}" ]; then
      gw_state=$(az network application-gateway show -n "$APPGW_NAME" -g "$APPGW_RG" --query "operationalState" -o tsv 2>/dev/null)
      echo "Gateway ($APPGW_NAME): ${gw_state:-desconhecido}"
      show_ip
    fi

    for s in "${PG_SERVERS[@]}"; do
      rg=$(pg_rg "$s")
      if [ -n "$rg" ]; then
        st=$(az postgres flexible-server show -n "$s" -g "$rg" --query "state" -o tsv 2>/dev/null)
        echo "Postgres ($s): ${st:-desconhecido}"
      fi
    done
    ;;

  *)
    echo "Uso: bash scripts/env.sh {up|down|status}"
    echo "  up     - liga Postgres + AKS + Gateway (na ordem certa)"
    echo "  down   - para Gateway + AKS + Postgres (economiza custo)"
    echo "  status - estado de cada recurso + IP publico"
    exit 1
    ;;
esac
