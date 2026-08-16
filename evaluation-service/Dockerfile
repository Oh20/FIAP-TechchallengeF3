# ==========================================
# Estágio 1: Build
# ==========================================
FROM golang:1.25 AS builder

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /build

# Otimização do Cache: Copia go.mod e go.sum (se existir) antes do resto do código
COPY . .
RUN go mod tidy

# Copia o restante do código fonte

# Otimização do Binário: Adicionadas flags para reduzir o tamanho do executável
RUN go build -ldflags="-s -w" -o /app

# ==========================================
# Estágio 2: Final
# ==========================================

FROM debian:bookworm-slim AS final

# Segurança/Rede: Garante certificados atualizados para chamadas HTTPS externas
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Organização: Copia o binário para a pasta de trabalho atual
COPY --from=builder /app ./app

EXPOSE 8004

ENTRYPOINT ["./app"]
