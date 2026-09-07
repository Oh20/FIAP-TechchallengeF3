// =============================================================================
// ToggleMaster — Pipeline de CI/CD (Tech Challenge Fase 3)
// =============================================================================
//
// Substitui o pipeline.groovy. É o pipeline do dia a dia: para cada serviço
// alterado, roda build + testes unitários + lint + SAST + SCA, constrói e
// escaneia a imagem, publica no ACR e atualiza o repositório de GitOps para o
// ArgoCD sincronizar.
//
// Nome do arquivo: `Jenkinsfile` na raiz do repositório — é a convenção que o
// job Multibranch Pipeline reconhece sozinho, sem configurar Script Path.
//
// Requisitos do agente: apenas Docker e Git. Nenhuma ferramenta é instalada no
// agente — go, python, golangci-lint, gosec, flake8, bandit e trivy rodam todos
// em container. Era o problema central do pipeline.groovy, que chamava `go`,
// `pip`, `trivy` etc. direto no agente.
//
// A execução dos testes é a MESMA de scripts/ci/test-go.sh e test-python.sh,
// compartilhada com o pipeline_unit_tests.jenkinsfile — uma implementação só.
//
// Relação com os outros pipelines:
//   Jenkinsfile                      -> CI/CD por serviço (este)
//   pipeline_unit_tests.jenkinsfile  -> só os testes dos 5, em paralelo (check rápido)
//   pipeline_devsecops.jenkinsfile   -> varredura completa + DefectDojo + gate consolidado
//
// Credenciais esperadas no Jenkins:
//   azure-service-principal  Username/Password — App Registration: appId / client secret
//   azure-devops-pat         Username/Password — PAT para o push no repositório de GitOps
// =============================================================================

// --- Catálogo dos microsserviços -------------------------------------------
// A linguagem sai daqui, não de um parâmetro. No pipeline.groovy, SERVICE_NAME
// e SERVICE_LANG eram parâmetros independentes: escolher 'auth-service' +
// 'python' passava pela validação e quebrava lá na frente.

def servicos() {
    return [
        [nome: 'auth-service',       linguagem: 'go'],
        [nome: 'evaluation-service', linguagem: 'go'],
        [nome: 'flag-service',       linguagem: 'python'],
        [nome: 'targeting-service',  linguagem: 'python'],
        [nome: 'analytics-service',  linguagem: 'python'],
    ]
}

def linguagemDe(String nome) {
    return servicos().find { it.nome == nome }?.linguagem
}

// --- Path filter -----------------------------------------------------------
// Implementa o "Path-Filter" que o README do projeto descreve: só reconstrói o
// que mudou. Em caso de dúvida, roda tudo — errar para o lado de rodar demais
// é seguro; para o lado de rodar de menos, não.

def servicosAlterados() {
    def todos = servicos()*.nome

    def base = env.CHANGE_TARGET ? "origin/${env.CHANGE_TARGET}"
                                 : (env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: '')

    if (!base) {
        echo 'Sem commit de referência (primeira build da branch) — rodando todos os serviços.'
        return todos
    }

    def saida = sh(
        script: "git diff --name-only '${base}' HEAD 2>/dev/null || true",
        returnStdout: true
    ).trim()

    if (!saida) {
        echo "Não foi possível calcular o diff contra ${base} — rodando todos os serviços."
        return todos
    }

    def arquivos = saida.split('\n')

    // Mudança fora de app/ (Jenkinsfile, scripts/ci, Dockerfile de base...)
    // pode afetar qualquer serviço.
    if (arquivos.any { !it.startsWith('app/') }) {
        echo 'Alteração fora de app/ detectada — rodando todos os serviços.'
        return todos
    }

    def selecionados = todos.findAll { svc -> arquivos.any { it.startsWith("app/${svc}/") } }

    if (!selecionados) {
        echo 'Nenhum serviço afetado pelas alterações.'
    }
    return selecionados
}

// --- Execução em container --------------------------------------------------

def rodarTestes(String nome) {
    def ehGo   = linguagemDe(nome) == 'go'
    def imagem = ehGo ? env.GO_IMAGE : env.PY_IMAGE
    def script = ehGo ? 'test-go.sh' : 'test-python.sh'

    sh """
        docker run --rm \\
            -v "${WORKSPACE}:/workspace" \\
            -w "/workspace/app/${nome}" \\
            -e REPORTS_DIR=/workspace/${env.REPORTS_DIR} \\
            ${ehGo ? '-e GO_RACE=1' : ''} \\
            ${imagem} \\
            sh /workspace/scripts/ci/${script} ${nome}
    """
}

// =============================================================================

pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
        skipDefaultCheckout(false)
    }

    parameters {
        choice(
            name: 'SERVICO',
            choices: ['auto', 'todos', 'auth-service', 'evaluation-service',
                      'flag-service', 'targeting-service', 'analytics-service'],
            description: 'auto = só os serviços alterados desde a última build bem-sucedida (path filter). A linguagem é deduzida do catálogo — não há mais parâmetro separado para isso.'
        )
        string(
            name: 'ACR_NAME',
            defaultValue: 'fiapdevopsadegj',
            description: 'Nome do Azure Container Registry (só alfanumérico — o Azure não aceita hífen). Precisa bater com os manifestos do repositório de GitOps.'
        )
        booleanParam(
            name: 'IGNORAR_SEM_CORRECAO',
            defaultValue: true,
            description: 'Passa --ignore-unfixed ao Trivy: só bloqueia em vulnerabilidade que TEM patch. Sem isso o build nunca passa — as imagens base têm CRITICALs sem correção publicada.'
        )
        booleanParam(
            name: 'PUBLICAR',
            defaultValue: true,
            description: 'Publica a imagem no ACR. Desmarque para rodar só a parte de verificação (build, testes e scans).'
        )
        booleanParam(
            name: 'ATUALIZAR_GITOPS',
            defaultValue: true,
            description: 'Atualiza a tag no repositório de GitOps para o ArgoCD sincronizar. Só roda na branch main.'
        )
        choice(
            name: 'AMBIENTE_GITOPS',
            choices: ['prod', 'dev'],
            description: 'Overlay do Kustomize a atualizar. O ArgoCD está apontado para overlays/prod.'
        )
    }

    environment {
        GO_IMAGE  = 'golang:1.25'
        PY_IMAGE  = 'python:3.13-slim'

        REPORTS_DIR = 'reports'
        GITOPS_DIR  = "${WORKSPACE}/gitops"
        GITOPS_REPO = 'dev.azure.com/Oh20Tony/FIAP%20-%20TechChallenge/_git/TCF3%20-%20K8S'

        ACR_REGISTRY   = "${params.ACR_NAME}.azurecr.io"
        TRIVY_FIX_FLAG = "${params.IGNORAR_SEM_CORRECAO ? '--ignore-unfixed' : ''}"
    }

    stages {

        // =====================================================================
        // ETAPA 0: PREPARAÇÃO
        // =====================================================================
        stage('0. Preparar') {
            steps {
                script {
                    sh """
                        rm -rf ${env.REPORTS_DIR}
                        mkdir -p ${env.REPORTS_DIR}
                        chmod 777 ${env.REPORTS_DIR}
                    """

                    // Tag = build + commit curto, como o desafio pede.
                    // O pipeline.groovy montava isso no bloco environment{} com
                    // env.GIT_COMMIT[0..7]: se o GIT_COMMIT não estiver definido
                    // (job com script inline, por exemplo), vira null[0..7] e o
                    // pipeline morre antes da primeira etapa.
                    def sha = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${sha}"

                    def alvo
                    if (params.SERVICO == 'auto') {
                        alvo = servicosAlterados()
                    } else if (params.SERVICO == 'todos') {
                        alvo = servicos()*.nome
                    } else {
                        alvo = [params.SERVICO]
                    }

                    env.SERVICOS_ALVO = alvo.join(',')

                    echo """
=== Build ${env.IMAGE_TAG} ===
  Registry : ${env.ACR_REGISTRY}
  Serviços : ${alvo ? alvo.join(', ') : '(nenhum)'}
"""

                    if (!alvo) {
                        currentBuild.result = 'NOT_BUILT'
                        error 'Nenhum serviço para construir. Encerrando sem trabalho.'
                    }

                    sh """
                        docker pull -q ${env.GO_IMAGE}
                        docker pull -q ${env.PY_IMAGE}
                    """
                }
            }
        }

        // =====================================================================
        // ETAPA 1: BUILD & TESTES UNITÁRIOS
        // =====================================================================
        // Usa scripts/ci/test-*.sh, que compila (go build), roda os testes e
        // gera JUnit + cobertura. No pipeline.groovy esta etapa terminava em
        // `python -m pytest || echo "Nenhum teste encontrado, prosseguindo..."`,
        // que fazia o estágio passar mesmo com teste quebrado.
        stage('1. Build & Testes Unitários') {
            steps {
                script {
                    env.SERVICOS_ALVO.split(',').each { nome ->
                        echo "=== Build & testes: ${nome} (${linguagemDe(nome)}) ==="
                        rodarTestes(nome)
                    }
                }
            }
            post {
                always {
                    junit testResults: "${env.REPORTS_DIR}/junit-*.xml", allowEmptyResults: true
                }
            }
        }

        // =====================================================================
        // ETAPA 2: LINTER & SAST
        // =====================================================================
        // Lint é informativo; SAST bloqueia só em severidade alta.
        // No pipeline.groovy o `bandit -r .` não tinha limiar nem `|| true` e
        // sai com código 1 em QUALQUER achado — inclusive LOW. Medido no
        // flag-service: 2 MEDIUM, exit 1. Ou seja, todo serviço Python
        // reprovava aqui, sempre, antes mesmo de chegar ao build da imagem.
        stage('2. Linter & SAST') {
            steps {
                script {
                    env.SERVICOS_ALVO.split(',').each { nome ->
                        echo "=== Lint & SAST: ${nome} ==="

                        if (linguagemDe(nome) == 'go') {
                            sh """
                                docker run --rm \\
                                    -v "${WORKSPACE}:/src" \\
                                    -w "/src/app/${nome}" \\
                                    -e GOFLAGS=-mod=mod \\
                                    golangci/golangci-lint:latest \\
                                    sh -c 'go mod tidy && golangci-lint run --timeout 5m' || true

                                docker run --rm \\
                                    -v "${WORKSPACE}:/src" \\
                                    -w "/src/app/${nome}" \\
                                    securego/gosec:latest \\
                                    -fmt=json -out=/src/${env.REPORTS_DIR}/gosec-${nome}.json \\
                                    -severity=high -confidence=medium ./...
                            """
                        } else {
                            sh """
                                docker run --rm \\
                                    -v "${WORKSPACE}:/src" \\
                                    -w "/src/app/${nome}" \\
                                    -e PIP_DISABLE_PIP_VERSION_CHECK=1 \\
                                    -e PIP_ROOT_USER_ACTION=ignore \\
                                    ${env.PY_IMAGE} \\
                                    sh -c '
                                        pip install --quiet --no-cache-dir flake8 bandit
                                        flake8 --max-line-length=120 --exclude=tests . || true
                                        bandit -r . -x ./tests -lll -f json \\
                                            -o /src/${env.REPORTS_DIR}/bandit-${nome}.json
                                    '
                            """
                        }
                    }
                }
            }
        }

        // =====================================================================
        // ETAPA 3: SCA — DEPENDÊNCIAS
        // =====================================================================
        // Bloqueia em CRITICAL, como manda o desafio.
        stage('3. SCA (Trivy FS)') {
            steps {
                script {
                    env.SERVICOS_ALVO.split(',').each { nome ->
                        echo "=== SCA: ${nome} ==="
                        sh """
                            docker run --rm \\
                                -v "${WORKSPACE}:/src" \\
                                aquasec/trivy:latest fs \\
                                --scanners vuln ${env.TRIVY_FIX_FLAG} \\
                                --format json --output /src/${env.REPORTS_DIR}/trivy-sca-${nome}.json \\
                                "/src/app/${nome}"

                            docker run --rm \\
                                -v "${WORKSPACE}:/src:ro" \\
                                aquasec/trivy:latest fs \\
                                --scanners vuln ${env.TRIVY_FIX_FLAG} \\
                                --severity CRITICAL --exit-code 1 \\
                                "/src/app/${nome}"
                        """
                    }
                }
            }
        }

        // =====================================================================
        // ETAPA 4: DOCKER BUILD & CONTAINER SCAN
        // =====================================================================
        stage('4. Docker Build & Container Scan') {
            steps {
                script {
                    env.SERVICOS_ALVO.split(',').each { nome ->
                        // Nome da imagem = nome do serviço, sem prefixo. O
                        // pipeline.groovy usava "togglemaster-${servico}", que
                        // não bate com o que os manifestos de GitOps e o ACR
                        // referenciam (fiapdevopsadegj.azurecr.io/auth-service).
                        def imagem = "${env.ACR_REGISTRY}/${nome}:${env.IMAGE_TAG}"

                        echo "=== Build & scan: ${imagem} ==="
                        sh """
                            docker build \\
                                -t ${imagem} \\
                                -t ${env.ACR_REGISTRY}/${nome}:latest \\
                                "${WORKSPACE}/app/${nome}"

                            # O socket do Docker é obrigatório: sem ele o Trivy
                            # não enxerga a imagem local e tenta puxá-la do
                            # registry, onde ela ainda não existe.
                            docker run --rm \\
                                -v /var/run/docker.sock:/var/run/docker.sock \\
                                -v "${WORKSPACE}:/src" \\
                                aquasec/trivy:latest image ${env.TRIVY_FIX_FLAG} \\
                                --format json --output /src/${env.REPORTS_DIR}/trivy-image-${nome}.json \\
                                ${imagem}

                            docker run --rm \\
                                -v /var/run/docker.sock:/var/run/docker.sock \\
                                aquasec/trivy:latest image ${env.TRIVY_FIX_FLAG} \\
                                --severity CRITICAL --exit-code 1 \\
                                ${imagem}
                        """
                    }
                }
            }
        }

        // =====================================================================
        // ETAPA 5: PUSH NO ACR (App Registration)
        // =====================================================================
        // O ACR aceita a App Registration direto como credencial do Docker.
        // Não é preciso `az login` — e assim não existe sessão de az CLI para
        // se perder entre containers.
        // A App Registration precisa da role AcrPush:
        //   az role assignment create --assignee <appId> --scope <acrId> --role AcrPush
        stage('5. Push no ACR') {
            when {
                expression { return params.PUBLICAR }
            }
            steps {
                script {
                    withCredentials([usernamePassword(
                        credentialsId: 'azure-service-principal',
                        usernameVariable: 'AZURE_CLIENT_ID',
                        passwordVariable: 'AZURE_CLIENT_SECRET'
                    )]) {
                        sh '''
                            set -eu
                            echo "$AZURE_CLIENT_SECRET" \
                                | docker login "${ACR_REGISTRY}" -u "$AZURE_CLIENT_ID" --password-stdin
                        '''

                        env.SERVICOS_ALVO.split(',').each { nome ->
                            echo "=== Push: ${env.ACR_REGISTRY}/${nome}:${env.IMAGE_TAG} ==="
                            sh """
                                docker push ${env.ACR_REGISTRY}/${nome}:${env.IMAGE_TAG}
                                docker push ${env.ACR_REGISTRY}/${nome}:latest
                            """
                        }
                    }
                }
            }
        }

        // =====================================================================
        // ETAPA 6: GITOPS — ATUALIZA A TAG PARA O ARGOCD
        // =====================================================================
        // O repositório de GitOps usa Kustomize (overlays/<amb>/<servico>/
        // kustomization.yaml), não `k8s/<servico>/deployment.yaml` — que é o
        // caminho que o pipeline.groovy tentava editar e não existe.
        stage('6. GitOps: atualizar tag') {
            when {
                allOf {
                    branch 'main'
                    expression { return params.PUBLICAR && params.ATUALIZAR_GITOPS }
                }
            }
            steps {
                script {
                    withCredentials([usernamePassword(
                        credentialsId: 'azure-devops-pat',
                        usernameVariable: 'AZ_USER',
                        passwordVariable: 'AZ_PAT'
                    )]) {
                        sh '''
                            set -eu
                            rm -rf "${GITOPS_DIR}"
                            git clone --quiet "https://${AZ_USER}:${AZ_PAT}@${GITOPS_REPO}" "${GITOPS_DIR}"
                        '''

                        env.SERVICOS_ALVO.split(',').each { nome ->
                            withEnv([
                                "DIR_OVERLAY=overlays/${params.AMBIENTE_GITOPS}/${nome}",
                                "IMAGEM_NOVA=${env.ACR_REGISTRY}/${nome}",
                                "SERVICO=${nome}"
                            ]) {
                                // `kustomize edit set image` em vez de sed: o
                                // campo `name` é o SELETOR (tem de continuar
                                // batendo com a imagem do base/) e o destino vai
                                // em newName/newTag. Sobrescrever o `name` faz o
                                // Kustomize não casar nada e a tag continuar em
                                // `latest`, sem erro nenhum. O comando também é
                                // idempotente.
                                sh '''
                                    set -eu
                                    cd "${GITOPS_DIR}"

                                    if [ ! -f "${DIR_OVERLAY}/kustomization.yaml" ]; then
                                        echo "AVISO: ${DIR_OVERLAY} não existe — ${SERVICO} pulado."
                                        exit 0
                                    fi

                                    SELETOR=$(awk '/^images:/{f=1;next} f&&/- name:/{sub(/.*name:[ ]*/,"");print;exit}' \
                                        "${DIR_OVERLAY}/kustomization.yaml")

                                    if [ -z "$SELETOR" ]; then
                                        echo "AVISO: ${DIR_OVERLAY} sem bloco images: — ${SERVICO} pulado."
                                        exit 0
                                    fi

                                    docker run --rm \
                                        -v "${GITOPS_DIR}:/w" -w "/w/${DIR_OVERLAY}" \
                                        registry.k8s.io/kustomize/kustomize:v5.4.3 \
                                        edit set image "${SELETOR}=${IMAGEM_NOVA}:${IMAGE_TAG}"

                                    echo "  ${SERVICO}: ${SELETOR} -> ${IMAGEM_NOVA}:${IMAGE_TAG}"
                                '''
                            }
                        }

                        sh '''
                            set -eu
                            cd "${GITOPS_DIR}"
                            git config user.email "jenkins@ci.local"
                            git config user.name  "Jenkins CI"
                            git add -A

                            if git diff --cached --quiet; then
                                echo "Nenhuma alteração no GitOps — as tags já estavam atualizadas."
                            else
                                git commit -q -m "ci: ToggleMaster ${IMAGE_TAG} (build #${BUILD_NUMBER})"
                                git push --quiet "https://${AZ_USER}:${AZ_PAT}@${GITOPS_REPO}" HEAD:main
                                echo "=== GitOps atualizado. O ArgoCD vai sincronizar automaticamente. ==="
                            fi
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: "${env.REPORTS_DIR}/*", allowEmptyArchive: true
        }
        success {
            script {
                if (env.SERVICOS_ALVO) {
                    echo "Build ${env.IMAGE_TAG} concluída para: ${env.SERVICOS_ALVO}."
                }
            }
        }
        failure {
            echo 'Build reprovada. Veja o relatório de testes (aba Test Result) e os scans em reports/.'
        }
        cleanup {
            // Cada build deixa vários GB de imagens no agente.
            sh 'docker image prune -f --filter "until=24h" || true'
            cleanWs deleteDirs: true, notFailBuild: true
        }
    }
}
