# ==========================================
# Estágio 1: Build
# ==========================================
FROM golang:1.25 AS builder

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /build

# Copia e baixa as dependências primeiro (aproveita o cache do Docker)
COPY . .
RUN go mod tidy
COPY go.mod go.sum* ./

# Compila o binário estático e remove símbolos de debug para reduzir o tamanho
RUN go build -ldflags="-s -w" -o /app

# ==========================================
# Estágio 2: Final
# ==========================================
FROM debian:bookworm-slim AS final

# Atualiza os certificados CA (necessário se o Go fizer chamadas HTTPS/APIs externas)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copia o binário do estágio de build
COPY --from=builder /app ./app

# Porta
EXPOSE 8001

ENTRYPOINT ["./app"]
