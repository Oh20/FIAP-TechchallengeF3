#!/usr/bin/env bash
# =============================================================================
# Roda localmente a mesma suíte de testes unitários que o Jenkins executa.
#
# Usa os mesmos scripts (scripts/ci/*.sh) e as mesmas imagens Docker do
# pipeline_unit_tests.jenkinsfile — o resultado local é idêntico ao do CI.
# Não é preciso ter Go nem Python instalados, só Docker.
#
# Uso:
#   ./scripts/run-unit-tests.sh                 # todos os serviços
#   ./scripts/run-unit-tests.sh flag-service    # um serviço só
#   SEM_RACE=1 ./scripts/run-unit-tests.sh      # sem o detector de corrida
#
# Relatórios ficam em test-reports/ na raiz do repositório.
# =============================================================================
set -uo pipefail

RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELATORIOS="$RAIZ_REPO/test-reports"

GO_IMAGE="${GO_IMAGE:-golang:1.25}"
PY_IMAGE="${PY_IMAGE:-python:3.13-slim}"
GO_RACE="$([ "${SEM_RACE:-0}" = "1" ] && echo 0 || echo 1)"

SERVICOS_GO="auth-service evaluation-service"
SERVICOS_PY="flag-service targeting-service analytics-service"
FILTRO="${1:-todos}"

# --- Validação do ambiente -------------------------------------------------

echo "=== Validando o ambiente ==="

command -v docker >/dev/null 2>&1 || {
    echo "ERRO: Docker não encontrado no PATH." >&2
    exit 1
}

docker info >/dev/null 2>&1 || {
    echo "ERRO: o daemon do Docker não está respondendo. Suba o Docker e tente de novo." >&2
    exit 1
}

echo "  Docker : $(docker --version)"
echo "  Repo   : $RAIZ_REPO"

rm -rf "$RELATORIOS"
mkdir -p "$RELATORIOS"

# --- Execução ---------------------------------------------------------------

falhas=""

rodar() {
    local nome="$1" linguagem="$2"

    if [ "$FILTRO" != "todos" ] && [ "$FILTRO" != "$nome" ]; then
        return 0
    fi

    echo
    echo "=== $nome ($linguagem) ==="

    local imagem script extras=""
    if [ "$linguagem" = "go" ]; then
        imagem="$GO_IMAGE"; script="test-go.sh"; extras="-e GO_RACE=$GO_RACE"
    else
        imagem="$PY_IMAGE"; script="test-python.sh"
    fi

    # shellcheck disable=SC2086
    docker run --rm \
        -v "$RAIZ_REPO:/workspace" \
        -w "/workspace/app/$nome" \
        -e REPORTS_DIR=/workspace/test-reports \
        $extras \
        "$imagem" \
        sh "/workspace/scripts/ci/$script" "$nome" || falhas="$falhas $nome"
}

for s in $SERVICOS_GO; do rodar "$s" go; done
for s in $SERVICOS_PY; do rodar "$s" python; done

# --- Resumo -----------------------------------------------------------------

echo
echo "=== Cobertura ==="
for s in $SERVICOS_GO $SERVICOS_PY; do
    arquivo="$RELATORIOS/cobertura-$s.txt"
    valor="n/d"
    [ -f "$arquivo" ] && valor="$(cat "$arquivo")"
    printf '  %-22s %6s %%\n' "$s" "$valor"
done

echo
if [ -n "$falhas" ]; then
    echo "Serviços com falha:$falhas"
    echo "Relatórios em: $RELATORIOS"
    exit 1
fi

echo "Todos os testes unitários passaram."
echo "Relatórios em: $RELATORIOS"
