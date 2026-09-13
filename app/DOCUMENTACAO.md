# ToggleMaster — Documentação (Tech Challenge Fase 3)

Sistema de **feature flags** com 5 microsserviços rodando em **Azure AKS**, com CI/CD no **Jenkins** e
deploy por **GitOps com Argo CD**.

Este documento cobre o **repositório da aplicação**. A infraestrutura e a entrega vivem em repositórios
separados:

| Repositório | Conteúdo |
| --- | --- |
| `FIAP - ToggleMaster F3` (este) | Código dos 5 serviços, Dockerfiles, pipelines Jenkins, scripts de teste |
| `terraform - F3` | Terraform do ambiente Azure |
| `TCF3 - K8S` | Manifestos Kustomize observados pelo Argo CD |

---

## 1. Arquitetura

```
Cliente
   │
   ▼
Application Gateway (L7)  ──configurado pelo──►  AGIC (Ingress Controller)
   │  roteia por path
   ▼
┌───────────────────────── Cluster AKS (namespace toggle-apps) ─────────────────────────┐
│  /admin,/validate → auth-service ──► PostgreSQL (auth_db)                              │
│  /flags           → flag-service ──► PostgreSQL (flags_db)        ┌──► valida token no │
│  /rules           → targeting-service ► PostgreSQL (targeting_db) ┤    auth-service     │
│  /evaluate        → evaluation-service ─┬─► Redis (cache)         └────────────────────│
│                                         ├─► flag + targeting (no cache miss)           │
│                                         └─► Azure Service Bus (evento)                 │
│                        analytics-service (worker) ◄── consome da fila ──► Cosmos DB    │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

### Serviços

| Serviço | Stack | Porta | Papel | Depende de |
|---|---|---|---|---|
| auth-service | Go | 8001 | cria/valida API keys | PostgreSQL |
| flag-service | Python (gunicorn) | 8002 | CRUD das flags | PostgreSQL + auth |
| targeting-service | Python (gunicorn) | 8003 | regras de segmentação | PostgreSQL + auth |
| evaluation-service | Go | 8004 | hot path: decide true/false | Redis + Service Bus + flag/targeting |
| analytics-service | Python (worker) | 8005 | consome eventos e grava | Service Bus + Cosmos |

Os `Service` do Kubernetes expõem todos na porta 80 e traduzem para a porta do contêiner.

### Os 3 data stores (propósitos distintos)

- **PostgreSQL** (relacional) — definições de flags e regras. 1 servidor por serviço.
- **Redis** (cache) — acelera o hot path do evaluation (2ª chamada = Cache HIT).
- **Cosmos DB** (NoSQL) — histórico de eventos de avaliação (analítico).

### Infra Azure

Provisionada por Terraform no repositório `terraform - F3`.

| Recurso | Uso |
|---|---|
| AKS | cluster Kubernetes (Azure CNI, `network_policy = azure`) |
| ACR | registro de imagens, `admin_enabled = false` (pull via role `AcrPull`) |
| Application Gateway + AGIC | balanceador L7 / Ingress |
| PostgreSQL Flexible ×3 | auth_db, flags_db, targeting_db |
| Azure Cache for Redis (Basic C0) | cache do evaluation — TLS na porta 6380 |
| Cosmos DB (serverless) | eventos do analytics |
| Azure Service Bus (Standard) | fila `togglemasterqueue` (evaluation → analytics) |
| Azure Key Vault ×2 | segredos da aplicação e da esteira |
| Log Analytics | logs e métricas do cluster |

> O nome do ACR e os endpoints variam por ambiente — pegue com `terraform output` em `env/`, nunca fixe
> no código.

---

## 2. O que fizemos

### Fase 2 — a aplicação

1. **Refatoração AWS → Azure**: código do evaluation/analytics migrado de SQS/DynamoDB para **Service Bus + Cosmos**.
2. **Conteinerização**: Dockerfiles multi-stage; apps Python servidos por **gunicorn** (produção).
3. **Manifestos K8s**: Deployment, Service (ClusterIP), ConfigMap, Secret, com `requests/limits` e probes `/health`.
4. **Migrations automatizadas**: Jobs K8s rodam o `db/init.sql` de cada serviço (ConfigMap gerado do repo).
5. **Ingress (AGIC)**: roteamento por path real (`/flags`, `/rules`, `/evaluate`, `/admin`, `/validate`).
6. **Escalabilidade**: HPA por CPU no evaluation (50%) e analytics (70%).
7. **Testes (Postman)**: `postman/ToggleMaster.postman_collection.json` — setup, carga aleatória e consultas.

### Fase 3 — a entrega

8. **Infraestrutura como código**: todo o ambiente Azure em Terraform, com state remoto.
9. **CI/CD no Jenkins**: quatro pipelines, toda ferramenta rodando em contêiner (ver seção 3).
10. **GitOps com Argo CD**: os manifestos saíram deste repositório e foram para o `TCF3 - K8S`. Nenhum
    pipeline aplica manifesto no cluster.
11. **Testes unitários**: suíte nos 5 serviços com dependências dubladas, mais quality gate de cobertura
    (ver `TESTES-UNITARIOS.md`).
12. **DevSecOps**: Gitleaks, Trivy (IaC/FS/Image), Hadolint, gosec, bandit, Horusec, OWASP ZAP e SBOM,
    com achados no DefectDojo e gate que reprova em `CRITICAL`.
13. **Segredos no Key Vault**: saíram dos `.env` e das variáveis de pipeline; os Pods leem via CSI driver
    com rotação automática.

---

## 3. Pipelines CI/CD (Jenkins)

O agente Jenkins precisa apenas de **Docker e Git** — go, python, trivy, terraform e os linters rodam
todos em contêiner.

| Arquivo | Papel |
|---|---|
| `Jenkinsfile` | CI/CD do dia a dia, por serviço alterado |
| `pipeline_unit_tests.jenkinsfile` | Os 5 serviços em paralelo + quality gate de cobertura |
| `pipeline_devsecops.jenkinsfile` | Varredura de segurança completa + DefectDojo + gate consolidado |

### `Jenkinsfile` — estágios

| Estágio | O que faz |
|---|---|
| 0. Preparar | Clone e detecção dos serviços alterados (path filter) |
| 1. Build & Testes Unitários | Compila e roda a suíte do serviço em contêiner |
| 2. Linter & SAST | golangci-lint + gosec (Go), flake8 + bandit (Python) |
| 3. SCA (Trivy FS) | Vulnerabilidades nas dependências |
| 4. Docker Build & Container Scan | Build da imagem e Trivy Image |
| 5. Push no ACR | `docker login` com a App Registration |
| 6. GitOps: atualizar tag | Commit da nova tag no overlay do Kustomize |

**O pipeline termina no commit.** Quem aplica no cluster é o Argo CD, que observa o repositório de GitOps
e reconcilia — é a fronteira que separa CI de CD nesta arquitetura.

### `pipeline_devsecops.jenkinsfile` — estágios

| # | Etapa | Ferramentas |
|---|---|---|
| 1 | Shift-Left: segredos, IaC e Dockerfiles | Gitleaks, Trivy IaC, Hadolint |
| 2 | Linter & SAST | golangci-lint, gosec, flake8, bandit, Horusec |
| 3 | SCA | Trivy FS |
| 4 | SBOM, Build & Container Scan | Trivy Image |
| 5 | DAST | OWASP ZAP Baseline (pulado se `APP_URL` vazio) |
| 6 | Centralização de achados | DefectDojo (um *engagement* por build) |
| 7 | **Quality Gate** | Reprova em `CRITICAL` |
| 8 | Push no ACR | Só chega aqui se o gate passou |
| 9 | GitOps | Atualiza a tag da imagem |

O gate é a etapa **7**, antes do push da etapa 8: imagem reprovada nunca chega ao registry. O parâmetro
`IGNORAR_SEM_CORRECAO` (ligado por padrão) restringe o Trivy a vulnerabilidades com patch disponível —
sem ele o gate trava em CVEs de imagem base sem correção publicada.

### Segredos

Criados no cluster a partir do **Key Vault**, pelos scripts do repositório de IaC. Nunca no Git, nunca
como variável de pipeline.

---

## 4. Desafios encontrados (e soluções)

### Fase 2 — aplicação e cluster

| Desafio | Solução |
|---|---|
| Senha com `@` quebrava a connection string | **percent-encode** na URL (`@` → `%40`); chave do Cosmos crua (não é URL) |
| Service Bus: erro de parsing | usar a **connection string** (não a URL da fila) |
| Pod `Ready` mas API dava erro | banco existia, faltava o **schema** (`db/init.sql`) → viraram migrations |
| AGIC não subia (subnet) | subnet dedicada na **mesma VNet dos nós**; não pode reusar outra subnet |
| `/flags` dava 502 sob sondas | flag-service rodava no **Flask dev server**; trocado por **gunicorn** |
| 502 em massa sob carga | probes agressivos + CPU baixa → restart em cascata; probes tolerantes + mais CPU + carga com taxa limitada (`hey -q`) |

### Fase 3 — esteira e infraestrutura

| Desafio | Solução |
|---|---|
| Pipeline quebrava por ferramenta faltando no agente | **tudo em contêiner**: o agente só precisa de Docker e Git |
| `SERVICE_NAME` + `SERVICE_LANG` como parâmetros independentes | catálogo único no código do pipeline — a linguagem sai do nome do serviço |
| Sessão do `az login` não sobrevivia entre estágios | cada `docker run --rm` é um contêiner novo; autenticação direta no `docker login` do ACR |
| Redis: `invalid URL scheme` | é **Azure Cache for Redis**, não Managed Redis: `rediss://:KEY@host.redis.cache.windows.net:6380` |
| Argo CD revertia o autoscaling | `ignoreDifferences` em `spec/replicas` nos apps com HPA — sem isso o `selfHeal` briga com o HPA e o app fica `OutOfSync` para sempre |
| Gate de segurança travava em CVE sem correção | `--ignore-unfixed` no Trivy: o gate só considera o que tem patch, senão não é acionável |
| DefectDojo subestimava a contagem de achados | a API pagina em 25 — usar o campo `count` da resposta, não o tamanho de `results` |
| Testes dependiam de Postgres/Redis/Service Bus | dependências dubladas no próprio código de teste: suíte em segundos e determinística |

---

## 5. Como testar

```bash
IP=<IP-do-Application-Gateway>

# 1) criar chave (usa a MASTER_KEY)
curl -X POST "http://$IP/admin/keys" -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" -d '{"name":"cli"}'

# 2) criar flag / 3) criar regra (com a tm_key retornada)
curl -X POST "http://$IP/flags" -H "Authorization: Bearer <APIKEY>" \
  -H "Content-Type: application/json" -d '{"name":"demo","is_enabled":true}'
curl -X POST "http://$IP/rules" -H "Authorization: Bearer <APIKEY>" \
  -H "Content-Type: application/json" -d '{"flag_name":"demo","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}'

# 4) avaliar (público)
curl "http://$IP/evaluate?user_id=user-123&flag_name=demo"

# 5) provar persistência / cache / eventos
curl "http://$IP/flags" -H "Authorization: Bearer <APIKEY>"        # Postgres
kubectl logs -n toggle-apps -l app=evaluation-service --tail=20    # Cache HIT (Redis)
kubectl logs -n toggle-apps -l app=analytics-service --tail=20     # gravou no Cosmos
```

Ou importe a collection do Postman (`postman/`) e rode o Runner.

### Demonstrar o HPA

```bash
kubectl get hpa -n toggle-apps -w
hey -z 180s -q 50 -c 10 "http://$IP/evaluate?user_id=load&flag_name=demo"   # use -q para limitar a taxa
```

### Testes unitários (local)

```bash
./scripts/run-unit-tests.sh          # Linux/macOS
./scripts/run-unit-tests.ps1         # Windows
```

Rodam em contêiner, sem dependência externa. Saídas em `test-reports/`. Detalhes em
`TESTES-UNITARIOS.md`.

---

## 6. Estrutura do repositório

```
app/<servico>/                    código + Dockerfile + testes + db/init.sql
postman/                          collection de testes
scripts/
  ci/test-go.sh, test-python.sh   execução dos testes (mesma no Jenkins e no dev)
  run-unit-tests.sh / .ps1        atalho local
  env.sh, gateway.sh              utilitários de ambiente
test-reports/                     saídas dos testes (JUnit, Cobertura) — não versionado
Jenkinsfile                       CI/CD por serviço (Build → ... → Push → GitOps)
pipeline_unit_tests.jenkinsfile   testes dos 5 em paralelo + gate de cobertura
pipeline_devsecops.jenkinsfile    varredura completa + DefectDojo + gate
DOCUMENTACAO.md                   este documento
TESTES-UNITARIOS.md               estratégia e cobertura dos testes
```

Os manifestos do Kubernetes **não moram mais aqui** — foram para o repositório de GitOps `TCF3 - K8S`.
