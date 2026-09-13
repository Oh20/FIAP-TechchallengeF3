# Testes Unitários — ToggleMaster (Fase 3)

Cobre o estágio **Build & Unit Test** exigido pelo Tech Challenge da Fase 3
("Compilar o código e rodar testes unitários") para os 5 microsserviços.

---

## Princípio de projeto

**Nenhum teste sobe infraestrutura.** Sem Postgres, sem Redis, sem Service Bus,
sem Cosmos DB, sem `docker compose` de apoio. Toda dependência externa é
substituída por um dublê no próprio código de teste.

Isso é o que torna a suíte utilizável num pipeline: ela roda em **menos de 1
segundo por serviço**, é determinística e não depende de rede nem de credencial
de nuvem. Testes que precisam de banco de verdade são testes de integração e
pertencem a outro estágio.

**Tudo roda dentro de containers Docker.** O agente Jenkins **não precisa ter Go
nem Python instalados** — só Docker. É isso que torna o pipeline portátil entre
a máquina do dev e a VM do Azure (ver [Provisionamento do agente](#provisionamento-do-agente-jenkins)).

---

## O que existe

Números medidos na execução completa via Docker (`golang:1.25` / `python:3.13-slim`):

| Serviço | Linguagem | Arquivos de teste | Casos | Cobertura | Mínimo no gate |
|---|---|---|---|---|---|
| `auth-service` | Go | `key_test.go`, `handlers_test.go`, `fakedb_test.go` | 24 | **61,0%** | 55% |
| `evaluation-service` | Go | `evaluator_test.go`, `cache_test.go`, `handlers_test.go`, `servicebus_test.go`, `types_test.go` | 57 | **66,5%** | 60% |
| `flag-service` | Python | `tests/test_health.py`, `test_auth_middleware.py`, `test_flags_crud.py` | 48 | **94%** | 85% |
| `targeting-service` | Python | `tests/test_health.py`, `test_auth_middleware.py`, `test_rules_crud.py` | 40 | **94%** | 85% |
| `analytics-service` | Python | `tests/test_health.py`, `test_process_message.py` | 24 | **80%** | 75% |
| **Total** | | | **193** | | |

### Por que os limites de cobertura são diferentes

Nos serviços Go, o `main()` é wiring de startup (conectar em Postgres, Redis,
Service Bus, registrar rotas, `ListenAndServe`) — nenhum teste unitário alcança
isso, e são cerca de 30% das linhas. Descontando `main()` e `connectDB`, a lógica
de negócio dos dois serviços Go está entre **88% e 100%** por função:

```
evaluation-service/evaluator.go  getDecision            100.0%
evaluation-service/evaluator.go  getCombinedFlagInfo    100.0%
evaluation-service/evaluator.go  fetchFromServices      100.0%
evaluation-service/evaluator.go  fetchFlag              100.0%
evaluation-service/evaluator.go  fetchRule               88.2%
evaluation-service/evaluator.go  runEvaluationLogic     100.0%
evaluation-service/evaluator.go  getDeterministicBucket 100.0%
evaluation-service/handlers.go   evaluationHandler      100.0%
evaluation-service/main.go       main                     0.0%   <- wiring
```

Nos serviços Python o `app.py` é quase todo lógica de rota, então o piso é bem
mais alto. Os mínimos ficam logo abaixo do medido hoje, com margem para
refatorações pequenas sem reprovar o build por ruído.

### Como cada dependência externa foi dublada

| Dependência | Serviço | Técnica |
|---|---|---|
| PostgreSQL | `auth-service` | Driver `database/sql` falso (`fakedb_test.go`), **stdlib pura** — sem adicionar dependência ao `go.mod` |
| PostgreSQL | `flag`, `targeting` | `SimpleConnectionPool` trocado por `MagicMock` **antes do import** do `app.py` |
| `auth-service` (HTTP) | `flag`, `targeting` | `requests.get` monkeypatched |
| `flag`/`targeting` (HTTP) | `evaluation` | `httptest.Server` real, em `localhost` |
| Redis | `evaluation` | `miniredis` — servidor Redis **in-process**, sem container e sem porta fixa |
| Azure Service Bus | `evaluation` | Cliente `nil` — o código já trata isso como modo degradado |
| Azure Service Bus | `analytics` | `ServiceBusClient.from_connection_string` monkeypatched |
| Cosmos DB | `analytics` | `CosmosClient` trocado por `MagicMock` **antes do import** |
| Thread do worker | `analytics` | `threading.Thread` trocado por objeto inerte durante o import |

> **Por que "antes do import"?** Os três serviços Python fazem trabalho pesado no
> nível de módulo: leem variáveis de ambiente, chamam `sys.exit(1)` se elas
> faltarem e abrem conexão de verdade. O `analytics-service` ainda sobe uma
> thread em loop infinito. Os `conftest.py` preparam o ambiente e trocam esses
> pontos antes de executar o `import app` — é o que permite testar sem
> refatorar o código de produção.

---

## Rodando localmente

Só é preciso ter **Docker**. É a mesma imagem e o mesmo script que o Jenkins usa,
então o resultado local é igual ao do CI.

Rode a partir da **raiz do repositório da aplicação** (a pasta `app/`, onde ficam
o `Jenkinsfile` e o `scripts/`).

```powershell
# Windows / PowerShell — todos os serviços
./scripts/run-unit-tests.ps1

# Um serviço só
./scripts/run-unit-tests.ps1 -Servico flag-service

# Sem o detector de corrida do Go (mais rápido)
./scripts/run-unit-tests.ps1 -SemRace
```

```bash
# Linux / macOS / Git Bash
./scripts/run-unit-tests.sh
./scripts/run-unit-tests.sh flag-service
SEM_RACE=1 ./scripts/run-unit-tests.sh
```

Os relatórios saem em `test-reports/` na raiz do repositório.

### Sem Docker (com toolchain nativo)

```bash
# Go
cd app/auth-service && go mod tidy && go test -v -race -cover ./...

# Python
cd app/flag-service
pip install -r requirements.txt -r requirements-dev.txt
pytest --cov=app --cov-report=term
```

---

## Rodando no Jenkins

O pipeline é o **`pipeline_unit_tests.jenkinsfile`**.

### Criar o job

1. Jenkins → **New Item** → *Pipeline* → nome `togglemaster-unit-tests`
2. **Pipeline** → *Pipeline script from SCM* → Git → URL do repositório
3. **Script Path**: `pipeline_unit_tests.jenkinsfile`
4. Salvar e **Build with Parameters**

### Etapas

| Etapa | O que faz |
|---|---|
| **0. Validar Ambiente** | Confere Docker, baixa as imagens `golang:1.25` e `python:3.13-slim` e verifica que cada serviço tem arquivos de teste. Falha cedo e com mensagem clara se algo faltar. |
| **1. Testes Unitários** | Roda os 5 serviços **em paralelo**, cada um no seu container. |
| **2. Quality Gate** | Reprova o build se algum serviço ficar abaixo da cobertura mínima. |

### Parâmetros

| Parâmetro | Padrão | Para que serve |
|---|---|---|
| `EXECUTAR_RACE_DETECTOR` | `true` | Liga o `-race` do Go. Importante no `evaluation-service`, que dispara duas goroutines em paralelo no `fetchFromServices`. |
| `COBERTURA_MINIMA_OVERRIDE` | *(vazio)* | Vazio = usa o mínimo por serviço definido no catálogo do Jenkinsfile. Preencha com um número para aplicar o mesmo piso a todos. |
| `FALHAR_NA_COBERTURA` | `true` | Se desmarcado, cobertura baixa marca `UNSTABLE` em vez de reprovar. |

### Relatórios publicados

- **JUnit** — a aba *Test Result* do build, com histórico e tendência
- **Cobertura** (formato Cobertura XML) — o plugin *Coverage* é opcional; se não
  estiver instalado, os XMLs ficam nos artefatos e o build não quebra
- **Artefatos** — `test-reports/*` (logs completos, cobertura detalhada por função)

### Plugins do Jenkins

| Plugin | Necessário? |
|---|---|
| Pipeline (workflow-aggregator) | **Sim** |
| JUnit | **Sim** |
| Workspace Cleanup (`cleanWs`) | **Sim** |
| Timestamper (`timestamps()`) | **Sim** |
| Coverage | Opcional — o pipeline degrada sozinho se faltar |

---

## Provisionamento do agente Jenkins

O agente precisa de **exatamente duas coisas**: Docker e Git. Nada de Go, nada de
Python, nada de `pip`. Toda a matriz de linguagens vive dentro das imagens.

### VM Azure (Ubuntu 22.04/24.04)

```bash
# Docker Engine
curl -fsSL https://get.docker.com | sh

# O usuário do Jenkins precisa falar com o daemon
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins   # ou reconecte o agente

# Verificação
sudo -u jenkins docker info
sudo -u jenkins docker pull golang:1.25
sudo -u jenkins docker pull python:3.13-slim
```

### Se o Jenkins roda ele mesmo em container

O socket precisa estar montado, senão o `docker run` de dentro do pipeline falha:

```bash
docker run -d --name jenkins \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker \
  jenkins/jenkins:lts
```

> **Atenção ao bind mount:** o pipeline monta `${WORKSPACE}` dentro dos
> containers de teste. Com Jenkins em container, o `WORKSPACE` precisa ser um
> caminho que exista **no host** também (é o daemon do host que resolve o
> `-v`). Se `jenkins_home` for um volume nomeado, monte-o com um caminho de host
> explícito (`-v /opt/jenkins_home:/var/jenkins_home`) para que os dois lados
> enxerguem o mesmo diretório.

### Rede e cache

Na **primeira** build o pipeline baixa as imagens base, os módulos Go
(`go mod tidy`) e os pacotes Python (`pip install`). Se a VM tiver saída
restrita, libere:

- `registry-1.docker.io` / `auth.docker.io` (imagens)
- `proxy.golang.org` e `sum.golang.org` (módulos Go)
- `pypi.org` e `files.pythonhosted.org` (pacotes Python)
- `deb.debian.org` (o `libpq5` do `flag`/`targeting-service`)

Para builds mais rápidas, adicione um volume de cache persistente nos scripts
(`-v go-cache:/tmp/gocache` e `-v pip-cache:/root/.cache/pip`).

---

## Onde os testes já estão integrados

A suíte é chamada por dois pipelines, e os dois usam **os mesmos**
`scripts/ci/test-go.sh` e `scripts/ci/test-python.sh` — uma implementação só.

| Pipeline | Papel | Testes |
|---|---|---|
| `Jenkinsfile` | CI/CD por serviço: build, testes, lint, SAST, SCA, imagem, push, GitOps | Etapa 1, só nos serviços alterados |
| `pipeline_unit_tests.jenkinsfile` | Check rápido dos 5 serviços em paralelo + quality gate de cobertura | Todos, sempre |
| `pipeline_devsecops.jenkinsfile` | Varredura completa + DefectDojo + gate consolidado | Não roda testes (foco em segurança) |

O `Jenkinsfile` substituiu o antigo `pipeline.groovy`, cujo estágio de testes
era `python -m pytest || echo "Nenhum teste encontrado, prosseguindo..."` — o
`|| echo` fazia o estágio passar mesmo com teste quebrado. Agora a falha
reprova o build e o resultado aparece na aba *Test Result*.

---

## O que os testes cobrem

### `auth-service` (Go)

- `hashAPIKey` determinístico, hex de 64 chars (cabe no `VARCHAR(64)` do schema),
  conferido contra SHA-256 de referência
- `generateAPIKey`: prefixo `tm_key_`, 71 caracteres, sem repetição em 200 chamadas
- `/validate`: 401 sem header, 200 com chave válida, 401 para chave inexistente,
  **401 também quando o banco falha** (fail-closed)
- **A chave em texto plano nunca chega ao SQL** — a query recebe o hash
- `/admin/keys`: 405, 400 (corpo inválido / nome vazio), 201 com a chave em texto
  plano, 500 em erro de banco sem vazar a chave na mensagem
- Middleware da `MASTER_KEY`: 403 sem header, 403 com chave errada, e uma chave
  de API comum **não** abre o endpoint de admin

### `evaluation-service` (Go)

- `getDeterministicBucket`: sempre em `[0,99]`, determinístico, boa dispersão
- `runEvaluationLogic`: kill switch global, flag nula, regra ausente, regra
  desativada, rollout de 0% / 50% / 100%
- **Rollout de 50% cai entre 45% e 55%** em 5.000 usuários — pega hash enviesado
- O mesmo usuário tem sempre a mesma decisão; o bucket varia por flag
- Valor de percentual não numérico e tipo de regra desconhecido → `false`
- `fetchFlag`/`fetchRule`: 200, 404 → `NotFoundError`, 500 → erro genérico,
  JSON inválido, serviço fora do ar
- **Propaga o `SERVICE_API_KEY`** no header (o bug de contexto de auth da Fase 2)
- `fetchFromServices`: combina os dois, tolera regra ausente, aborta com flag ausente
- **Cache (`cache_test.go`, com `miniredis`)**: cache MISS busca nos serviços e
  grava no Redis; cache HIT serve 10 requisições seguidas **sem tocar nos
  serviços**; o TTL de 30s é aplicado; após o TTL expirar o serviço é reconsultado;
  cache corrompido vira MISS em vez de derrubar o serviço; cada flag usa sua
  própria chave
- `getDecision` ponta a ponta e **a decisão é a mesma vindo do cache ou dos serviços**
- `evaluationHandler`: 200 com a decisão, 200 com `false` para flag inexistente
  (falha segura) e **502 quando os serviços estão fora do ar** — erro de
  infraestrutura não pode virar uma decisão falsa
- `CombinedFlagInfo` sobrevive ao round-trip do cache Redis **e a decisão não muda**
- `EvaluationEvent` mantém o contrato JSON com o `analytics-service`
- `sendEvaluationEvent` sem Service Bus não entra em pânico (roda como goroutine —
  um pânico ali mataria o processo inteiro)

### `flag-service` / `targeting-service` (Python)

- `/health`: 200, sem auth, sem tocar no banco, sem chamar o `auth-service`
- Middleware: 401 sem header, 401 para qualquer status ≠ 200 do `auth-service`
  (fail-closed), 504 em timeout, 503 em falha de conexão
- Repassa o header recebido, chama `/validate` e **usa `timeout=3`** — sem isso
  uma falha do `auth-service` prende todos os workers do gunicorn
- CRUD completo: 201/200/204, 400 de validação, 404, 409 de duplicata, 500
- **Queries parametrizadas**: um `name` com `'; DROP TABLE ...` vai como parâmetro
- `is_enabled` nasce `false` no `flag-service` e `true` no `targeting-service`
- `rules` (JSONB) vai via `psycopg2.extras.Json`, não como string concatenada
- **A conexão sempre volta ao pool**, inclusive nos caminhos de erro (o pool tem
  máximo de 5; vazar conexão esgota o serviço em poucos requests)

### `analytics-service` (Python)

- `/health` responde 200 mesmo com o Cosmos quebrado
- `process_message`: mapeia todos os campos, `id` == `event_id`, id único por
  evento, `flag_name` presente (é a partition key)
- **Poison pill**: JSON inválido é descartado com `True` (senão trava a fila)
- **Falha no Cosmos devolve `False`** — a mensagem volta para a fila em vez de
  ser perdida. É o teste que protege o at-least-once.
- Campo obrigatório ausente → `False`
- O worker sobe como `daemon=True` e reconecta após falha no Service Bus
- Lê o payload exatamente como o `evaluation-service` publica

---

## Achados durante a criação dos testes

Registrados aqui porque afetam o pipeline, não só os testes:

### ⚠️ Prioridade alta — credenciais versionadas

`.env/DBCredentials.txt` e `.env/ServiceBusConnection.txt` **estão rastreados
pelo Git** (`git ls-files .env/` os lista). São exatamente o problema que o
enunciado da Fase 3 cita: *"As credenciais do banco de dados estão sendo passadas
em arquivos de texto sem segurança"*.

**Não mexi neles** — remover segredo de repositório é decisão de vocês e envolve
rotação de credencial. O caminho é:

1. **Rotacionar** as senhas do Postgres e a connection string do Service Bus —
   uma vez commitado, o segredo tem de ser considerado vazado, mesmo depois de
   removido do histórico.
2. `git rm --cached .env/DBCredentials.txt .env/ServiceBusConnection.txt` e
   commitar. O `.gitignore` que criei já cobre `.env` para o futuro, mas
   `.gitignore` **não desrastreia** o que já está no índice.
3. Limpar o histórico com `git filter-repo` (ou BFG) se o repositório for
   publicado.
4. Mover os valores para o **Azure Key Vault** — o `IaC/modules/keyvault.tf` já
   existe — e consumir via `Secret` do Kubernetes ou Secrets Store CSI Driver.

Vale notar que o `pipeline_devsecops.jenkinsfile` já roda **Gitleaks**, mas com
`--exit-code=0`: ele reporta e não reprova. Trocar para `--exit-code=1` faria o
pipeline barrar exatamente este caso — e é um ótimo cenário para gravar no vídeo
de demonstração ("pipeline falhando no passo de segurança").

### Demais achados

1. **`evaluation-service/go.sum` era inválido** *(corrigido)* — o arquivo era uma
   cópia de um `go.mod` antigo, da época em que o serviço usava o AWS SDK; não
   era um `go.sum`. Qualquer `go build`/`go test` falharia com *malformed
   go.sum*. Foi substituído pelo `go.sum` real gerado por `go mod tidy`.

2. **`auth-service` nunca teve `go.sum`** *(corrigido)* — o `go mod tidy`
   gerou um. Sem ele, o build não é reprodutível nem verificável (é justamente o
   arquivo que o Trivy usa no SCA para casar as versões das dependências).

3. **`pipeline.groovy` engolia falha de teste** *(substituído)* — o
   `python -m pytest || echo "Nenhum teste encontrado, prosseguindo..."` fazia
   o estágio passar mesmo com teste quebrado. O arquivo foi substituído pelo
   `Jenkinsfile`, que reprova a build e publica o relatório JUnit.

4. **`auth-service/Dockerfile` tem os `COPY` fora de ordem** —
   `COPY . .` → `RUN go mod tidy` → `COPY go.mod go.sum* ./` sobrescreve o
   `go.mod` já resolvido pelo tidy e anula o cache de camada que a ordem
   pretendia criar. Não quebra o build hoje, mas o `COPY go.mod` deveria vir
   antes do `COPY . .`.

5. **`analytics-service/err`** é um log de erro antigo (da versão AWS) versionado
   por engano. Pode ser removido.

6. **`.dockerignore` criado nos três serviços Python** *(corrigido)* — o
   `flag-service` faz `COPY . .`, então sem isso `tests/` iria parar dentro da
   imagem de produção.

7. **`.gitattributes` criado** — o repositório é editado no Windows com
   `autocrlf`. Sem forçar `eol=lf` nos `*.sh`, os scripts de CI chegariam ao
   container Linux com CRLF e falhariam com *bad interpreter*.

---

## Estrutura dos arquivos criados

Todos os caminhos são relativos à raiz do repositório da aplicação (pasta `app/`,
que é o `${WORKSPACE}` do Jenkins).

```
.
├── pipeline_unit_tests.jenkinsfile      # pipeline dedicado aos testes unitários
├── TESTES-UNITARIOS.md                  # este documento
├── .gitignore                           # ignora test-reports/, __pycache__, .coverage
├── .gitattributes                       # força LF nos scripts que rodam em container
├── scripts/
│   ├── run-unit-tests.ps1               # runner local (Windows)
│   ├── run-unit-tests.sh                # runner local (Linux/macOS/Git Bash)
│   └── ci/
│       ├── test-go.sh                   # executado dentro do golang:1.25
│       └── test-python.sh               # executado dentro do python:3.13-slim
└── app/
    ├── auth-service/
    │   ├── fakedb_test.go               # driver database/sql falso (stdlib pura)
    │   ├── key_test.go
    │   ├── handlers_test.go
    │   └── go.sum                        # gerado por go mod tidy (não existia)
    ├── evaluation-service/
    │   ├── evaluator_test.go
    │   ├── cache_test.go                # cache Redis via miniredis
    │   ├── handlers_test.go
    │   ├── servicebus_test.go
    │   ├── types_test.go
    │   └── go.sum                        # substituiu o arquivo inválido
    ├── flag-service/
    │   ├── pytest.ini
    │   ├── requirements-dev.txt
    │   ├── .dockerignore
    │   └── tests/{conftest,test_health,test_auth_middleware,test_flags_crud}.py
    ├── targeting-service/
    │   ├── pytest.ini
    │   ├── requirements-dev.txt
    │   ├── .dockerignore
    │   └── tests/{conftest,test_health,test_auth_middleware,test_rules_crud}.py
    └── analytics-service/
        ├── pytest.ini
        ├── requirements-dev.txt
        ├── .dockerignore
        └── tests/{conftest,test_health,test_process_message}.py
```
