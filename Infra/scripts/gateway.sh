#!/usr/bin/env bash
#
# Controla o Application Gateway (AGIC) para economizar custo entre apresentacoes.
#
# stop/start NAO apagam o gateway: cessam a cobranca de compute e mantem o
# MESMO IP publico (o baseUrl do Postman/curl continua igual).
#
# Uso (rodar no Azure Cloud Shell ou em qualquer maquina com Azure CLI logada):
#   ./gateway.sh up       # inicia o gateway  (rodar ANTES de apresentar)
#   ./gateway.sh down     # para o gateway    (rodar DEPOIS de apresentar)
#   ./gateway.sh status   # mostra estado + IP publico
#
# Requisito: az login  (e a assinatura correta selecionada)

set -euo pipefail

# ---- Ajuste se necessario ----
AKS_NAME="togglemaster-aks"
AKS_RG="AKS_RG_LAB"
# ------------------------------

# Descobre o App Gateway gerenciado pelo add-on AGIC a partir do AKS.
resolve_appgw() {
  APPGW_ID=$(az aks show -n "$AKS_NAME" -g "$AKS_RG" \
    --query "addonProfiles.ingressApplicationGateway.config.effectiveApplicationGatewayId" \
    -o tsv 2>/dev/null || true)
  if [ -z "${APPGW_ID:-}" ] || [ "$APPGW_ID" = "null" ]; then
    APPGW_ID=$(az aks show -n "$AKS_NAME" -g "$AKS_RG" \
      --query "addonProfiles.ingressApplicationGateway.config.applicationGatewayId" -o tsv)
  fi
  if [ -z "${APPGW_ID:-}" ] || [ "$APPGW_ID" = "null" ]; then
    echo "ERRO: nao encontrei o Application Gateway do AGIC. O add-on esta habilitado?" >&2
    exit 1
  fi
  APPGW_NAME="$(basename "$APPGW_ID")"
  APPGW_RG="$(echo "$APPGW_ID" | sed -n 's#.*/resourceGroups/\([^/]*\)/.*#\1#p')"
}

show_ip() {
  local pipid ip
  pipid=$(az network application-gateway show -n "$APPGW_NAME" -g "$APPGW_RG" \
    --query "frontendIPConfigurations[?publicIPAddress].publicIPAddress.id | [0]" -o tsv)
  if [ -n "${pipid:-}" ] && [ "$pipid" != "null" ]; then
    ip=$(az network public-ip show --ids "$pipid" --query ipAddress -o tsv)
    echo "IP publico do Application Gateway: ${ip:-<sem IP>}"
  fi
}

resolve_appgw

case "${1:-}" in
  up|start)
    echo ">> Iniciando o Application Gateway '$APPGW_NAME' (RG: $APPGW_RG)..."
    az network application-gateway start -n "$APPGW_NAME" -g "$APPGW_RG"
    echo ">> Gateway iniciado. Pode levar alguns minutos ate rotear."
    show_ip
    echo ">> Se o roteamento demorar, reaplique o Ingress:"
    echo "   kubectl apply -f K8S_AKS/ingress/ingress.yaml"
    ;;
  down|stop)
    echo ">> Parando o Application Gateway '$APPGW_NAME' (RG: $APPGW_RG)..."
    az network application-gateway stop -n "$APPGW_NAME" -g "$APPGW_RG"
    echo ">> Gateway parado. Cobranca de compute cessada; IP publico mantido."
    ;;
  status)
    az network application-gateway show -n "$APPGW_NAME" -g "$APPGW_RG" \
      --query "{nome:name, estado:operationalState, provisionamento:provisioningState}" -o table
    show_ip
    ;;
  *)
    echo "Uso: $0 {up|down|status}"
    echo "  up     - inicia o gateway (antes de apresentar)"
    echo "  down   - para o gateway (economiza custo apos apresentar)"
    echo "  status - mostra estado e IP publico"
    exit 1
    ;;
esac
