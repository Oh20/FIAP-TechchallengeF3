# ToggleMaster — Documentação (Tech Challenge Fase 2)

Sistema de **feature flags** (5 microsserviços) migrado para **Azure AKS**, com CI/CD no Azure DevOps.

> Diagrama: [desenhoArquitetural.jpg](desenhoArquitetural.jpg)

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

### Os 3 data stores (propósitos distintos)

- **PostgreSQL** (relacional) — definições de flags e regras. 1 banco por serviço.
- **Redis** (cache) — acelera o hot path do evaluation (2ª chamada = Cache HIT).
- **Cosmos DB** (NoSQL) — histórico de eventos de avaliação (analítico).

### Infra Azure

| Recurso | Uso |
|---|---|
| AKS | cluster Kubernetes (CNI Overlay) |
| ACR (`fiapdevopsadegj`) | registro de imagens |
| Application Gateway + AGIC | balanceador L7 / Ingress |
| PostgreSQL Flexible ×3 | auth_db, flags_db, targeting_db |
| Azure Managed Redis | cache do evaluation |
| Cosmos DB | eventos do analytics |
| Azure Service Bus | fila `togglemasterqueue` (evaluation → analytics) |

---

## 2. O que fizemos

1. **Refatoração AWS → Azure**: código do evaluation/analytics migrado de SQS/DynamoDB para **Service Bus + Cosmos**.
2. **Conteinerização**: Dockerfiles multi-stage; apps Python servidos por **gunicorn** (produção).
3. **Manifestos K8s** (`K8S_AKS/`): Deployment, Service (ClusterIP), ConfigMap, Secret, com `requests/limits` e probes `/health`.
4. **Migrations automatizadas**: Jobs K8s rodam o `db/init.sql` de cada serviço (ConfigMap gerado do repo).
5. **Ingress (AGIC)**: roteamento por path real (`/flags`, `/rules`, `/evaluate`, `/admin`, `/validate`).
6. **Escalabilidade**: HPA por CPU no evaluation (50%) e analytics (70%).
7. **CI/CD (Azure DevOps)** — 4 estágios (ver seção 3).
8. **Testes (Postman)**: `postman/ToggleMaster.postman_collection.json` — setup, carga aleatória e consultas.

---

## 3. Pipeline CI/CD (`azure-pipelines.yml`)

| Estágio | O que faz |
|---|---|
| **Build** | detecta serviços alterados, builda e faz push das imagens no ACR |
| **Prepare** | cria os Secrets (variáveis 🔒 do pipeline) e roda as migrations (Jobs) |
| **Deploy** | aplica os manifestos, `rollout restart` e aguarda a saúde dos pods |
| **Expose** | aplica o Ingress e os HPAs |

- **Secrets**: criados no cluster a partir de variáveis secretas do pipeline (nunca no git).
- **Namespaces/bancos**: bootstrap único de admin, fora do CD.

---

## 4. Desafios encontrados (e soluções)

| Desafio | Solução |
|---|---|
| Service connection como variável de runtime | usar nome **literal** em `kubernetesServiceEndpoint` |
| Secret/Namespace via CD davam `Forbidden` | a ServiceAccount é namespace-scoped; criar namespace no admin, secrets via task `createSecret` |
| Senha com `@` quebrava a connection string | **percent-encode** na URL (`@` → `%40`); chave do Cosmos crua (não é URL) |
| Redis: `invalid URL scheme` | Azure Managed Redis usa `rediss://:KEY@host:10000` (TLS, key encodada) |
| Service Bus: erro de parsing | usar a **connection string** (não a URL da fila) |
| Pod `Ready` mas API dava erro | banco existia, faltava o **schema** (`db/init.sql`) → viraram migrations |
| AGIC não subia (subnet) | subnet dedicada na **mesma VNet dos nós**; não pode reusar a subnet do AGfC |
| `/flags` dava 502 sob sondas | flag-service rodava no **Flask dev server**; trocado por **gunicorn** |
| 502 em massa sob carga | probes agressivos + CPU baixa → restart em cascata; probes tolerantes + mais CPU + carga com taxa limitada (`hey -q`) |

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

---

## 6. Estrutura do repositório

```
K8S_AKS/               manifestos (um diretório por serviço + ingress/ + scaling/)
postman/               collection de testes
azure-pipelines.yml    CI/CD (Build → Prepare → Deploy → Expose)
<servico>/             código + Dockerfile + db/init.sql
```
