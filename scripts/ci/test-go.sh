#!/bin/sh
# =============================================================================
# Testes unitários de um microsserviço Go do ToggleMaster.
#
# Roda dentro da imagem oficial golang (ver GO_IMAGE no Jenkinsfile), a partir
# do diretório do serviço. Também serve para rodar localmente:
#
#   docker run --rm -v "$PWD:/w" -w /w/app/auth-service -e REPORTS_DIR=/w/test-reports \
#       golang:1.25 sh /w/scripts/ci/test-go.sh auth-service
#
# Variáveis de ambiente:
#   REPORTS_DIR  onde gravar os relatórios (padrão: /reports)
#   GO_RACE      1 para ligar o detector de corrida de dados (padrão: 1)
#   SEM_REDE     1 para pular a instalação das ferramentas de relatório
# =============================================================================
set -eu

SERVICO="${1:?uso: test-go.sh <nome-do-servico>}"
REPORTS="${REPORTS_DIR:-/reports}"
GO_RACE="${GO_RACE:-1}"
SEM_REDE="${SEM_REDE:-0}"

export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOPATH="${GOPATH:-/tmp/gopath}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export PATH="$PATH:$GOPATH/bin"

mkdir -p "$REPORTS"

echo "=== [$SERVICO] Toolchain ==="
go version

# O repositório não versiona um go.sum confiável para todos os serviços
# (o do evaluation-service, por exemplo, é uma cópia antiga do go.mod).
# O tidy resolve as dependências reais a partir do go.mod.
echo "=== [$SERVICO] Resolvendo dependências ==="
go mod tidy

echo "=== [$SERVICO] Compilando ==="
# -o com diretório: o binário vai para /tmp em vez de sujar o workspace
# (que é um bind mount do repositório).
mkdir -p /tmp/build
go build -o /tmp/build/ ./...

# go vet aqui é informativo: quem reprova o build por qualidade de código é o
# stage de Linter/SAST (golangci-lint + gosec) do pipeline de DevSecOps.
go vet ./... || echo "AVISO: go vet apontou problemas — veja o stage de SAST."

FLAG_RACE=""
if [ "$GO_RACE" = "1" ]; then
    FLAG_RACE="-race"
fi

echo "=== [$SERVICO] Executando testes ${FLAG_RACE} ==="
set +e
go test -v $FLAG_RACE -covermode=atomic -coverprofile=/tmp/coverage.out ./... 2>&1 | tee /tmp/test.log
STATUS=$?
set -e

cp /tmp/test.log "$REPORTS/test-$SERVICO.log"

# --- Relatórios ------------------------------------------------------------

if [ "$SEM_REDE" != "1" ]; then
    echo "=== [$SERVICO] Gerando JUnit e Cobertura ==="
    go install github.com/jstemmer/go-junit-report/v2@v2.1.0 || true
    go install github.com/boumenot/gocover-cobertura@v1.2.0 || true
fi

if command -v go-junit-report >/dev/null 2>&1; then
    go-junit-report < /tmp/test.log > "$REPORTS/junit-$SERVICO.xml"
else
    echo "AVISO: go-junit-report indisponível — relatório JUnit não foi gerado."
fi

if [ -f /tmp/coverage.out ]; then
    if command -v gocover-cobertura >/dev/null 2>&1; then
        gocover-cobertura < /tmp/coverage.out > "$REPORTS/coverage-$SERVICO.xml"
    fi
    go tool cover -func=/tmp/coverage.out > "$REPORTS/cobertura-detalhada-$SERVICO.txt"
    tail -1 "$REPORTS/cobertura-detalhada-$SERVICO.txt" \
        | awk '{ print $NF }' | tr -d '%' > "$REPORTS/cobertura-$SERVICO.txt"
else
    echo "0" > "$REPORTS/cobertura-$SERVICO.txt"
fi

echo "=== [$SERVICO] Cobertura: $(cat "$REPORTS/cobertura-$SERVICO.txt")% ==="
exit $STATUS
