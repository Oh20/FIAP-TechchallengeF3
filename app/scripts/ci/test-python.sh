#!/bin/sh
# =============================================================================
# Testes unitários de um microsserviço Python do ToggleMaster.
#
# Roda dentro da imagem oficial python (ver PY_IMAGE no Jenkinsfile), a partir
# do diretório do serviço. Também serve para rodar localmente:
#
#   docker run --rm -v "$PWD:/w" -w /w/app/flag-service -e REPORTS_DIR=/w/test-reports \
#       python:3.13-slim sh /w/scripts/ci/test-python.sh flag-service
#
# Variáveis de ambiente:
#   REPORTS_DIR      onde gravar os relatórios (padrão: /reports)
#   INSTALAR_LIBPQ   1 para instalar libpq5 via apt (padrão: 1; necessário
#                    para o psycopg2-binary do flag/targeting-service)
# =============================================================================
set -eu

SERVICO="${1:?uso: test-python.sh <nome-do-servico>}"
REPORTS="${REPORTS_DIR:-/reports}"
INSTALAR_LIBPQ="${INSTALAR_LIBPQ:-1}"

export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_ROOT_USER_ACTION=ignore
export PYTHONDONTWRITEBYTECODE=1

mkdir -p "$REPORTS"

echo "=== [$SERVICO] Toolchain ==="
python --version

# psycopg2-binary precisa da libpq em runtime; a imagem slim não a traz.
if [ "$INSTALAR_LIBPQ" = "1" ] && grep -qi "psycopg2" requirements.txt 2>/dev/null; then
    echo "=== [$SERVICO] Instalando libpq5 ==="
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends libpq5 >/dev/null
    rm -rf /var/lib/apt/lists/*
fi

echo "=== [$SERVICO] Instalando dependências ==="
pip install --quiet --no-cache-dir -r requirements.txt -r requirements-dev.txt

echo "=== [$SERVICO] Executando testes ==="
# O status vai para um arquivo em vez de $?: depois de um pipeline, $? e o
# status do ULTIMO comando (o tee), que e sempre 0. Capturar $? aqui fazia
# suite quebrada terminar com exit 0 e o estagio do Jenkins passar verde.
# `set -o pipefail` nao resolve: /bin/sh nas imagens Debian e o dash.
set +e
{
    python -m pytest \
        --junitxml="$REPORTS/junit-$SERVICO.xml" \
        --cov=app \
        --cov-report="xml:$REPORTS/coverage-$SERVICO.xml" \
        --cov-report=term 2>&1
    echo $? > /tmp/status
} | tee "$REPORTS/test-$SERVICO.log"
STATUS=$(cat /tmp/status 2>/dev/null || echo 1)
set -e

# Linha "TOTAL   170   10   94%" do relatório de cobertura em texto.
if grep -q '^TOTAL' "$REPORTS/test-$SERVICO.log"; then
    grep '^TOTAL' "$REPORTS/test-$SERVICO.log" \
        | tail -1 | awk '{ print $NF }' | tr -d '%' > "$REPORTS/cobertura-$SERVICO.txt"
else
    echo "0" > "$REPORTS/cobertura-$SERVICO.txt"
fi

echo "=== [$SERVICO] Cobertura: $(cat "$REPORTS/cobertura-$SERVICO.txt")% ==="
exit $STATUS
