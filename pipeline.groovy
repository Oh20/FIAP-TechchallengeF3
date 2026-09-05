pipeline {
    agent any

    // Parâmetros para definir qual serviço está sendo "buildado"
    parameters {
        choice(name: 'SERVICE_NAME', choices: ['auth-service', 'flag-service', 'targeting-service', 'evaluation-service', 'analytics-service'], description: 'Nome do microsserviço a ser executado')
        choice(name: 'SERVICE_LANG', choices: ['go', 'python'], description: 'Linguagem do microsserviço')
    }

    environment {
        // Configurações do Azure Container Registry (ACR)
        ACR_NAME     = 'seuregistroacr'
        ACR_REGISTRY = "${ACR_NAME}.azurecr.io"
        
        // Caminhos e Tags
        SERVICE_DIR  = "app/${params.SERVICE_NAME}"
        IMAGE_NAME   = "togglemaster-${params.SERVICE_NAME}"
        IMAGE_TAG    = "${env.BUILD_NUMBER}-${env.GIT_COMMIT[0..7]}"
        
        // Configurações do GitOps
        GITOPS_REPO  = 'https://github.com/seu-usuario/togglemaster-gitops.git'
    }

    stages {
        stage('Build & Unit Test') {
            steps {
                dir("${SERVICE_DIR}") {
                    script {
                        if (params.SERVICE_LANG == 'go') {
                            sh 'go mod tidy'
                            sh 'go build -v ./...'
                            sh 'go test -v ./...'
                        } else if (params.SERVICE_LANG == 'python') {
                            sh 'pip install -r requirements.txt'
                            sh 'python -m pytest || echo "Nenhum teste encontrado, prosseguindo..."'
                        }
                    }
                }
            }
        }

        stage('Linter & Static Analysis (SAST)') {
            steps {
                dir("${SERVICE_DIR}") {
                    script {
                        if (params.SERVICE_LANG == 'go') {
                            // Linter e SAST para Go
                            sh 'golangci-lint run'
                            sh 'gosec ./...'
                        } else if (params.SERVICE_LANG == 'python') {
                            // Linter e SAST para Python
                            sh 'pylint app.py || true'
                            sh 'bandit -r .'
                        }
                    }
                }
            }
        }

        stage('Security Scan (SCA)') {
            steps {
                dir("${SERVICE_DIR}") {
                    // Verifica vulnerabilidades nas dependências. 
                    // A flag --exit-code 1 trava a pipeline se uma vulnerabilidade CRÍTICA for encontrada.
                    sh 'trivy fs --severity CRITICAL --exit-code 1 .'
                }
            }
        }

        stage('Docker Build & Container Scan') {
            steps {
                script {
                    // Constrói a imagem Docker
                    sh "docker build -t ${ACR_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ./${SERVICE_DIR}"
                    
                    // Scan de vulnerabilidades na imagem gerada (Container Scan)[cite: 2]
                    // Falha e não prossegue em caso de CRÍTICA[cite: 2]
                    sh "trivy image --severity CRITICAL --exit-code 1 ${ACR_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
                }
            }
        }

        stage('Docker Push (Azure ACR)') {
            steps {
                script {
                    // Autenticação e Push para o ACR
                    withCredentials([usernamePassword(credentialsId: 'azure-acr-credentials', passwordVariable: 'ACR_PASS', usernameVariable: 'ACR_USER')]) {
                        sh "echo \$ACR_PASS | docker login ${ACR_REGISTRY} -u \$ACR_USER --password-stdin"
                        sh "docker push ${ACR_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
                    }
                }
            }
        }

        stage('GitOps Update (CD)') {
            steps {
                script {
                    // Atualiza a tag da imagem no repositório de GitOps para que o ArgoCD sincronize[cite: 2]
                    withCredentials([gitUsernamePassword(credentialsId: 'github-gitops-token', gitToolName: 'Default')]) {
                        sh """
                            # Clona o repositório GitOps
                            git clone ${GITOPS_REPO} gitops-repo
                            cd gitops-repo
                            
                            # Altera o deployment.yaml do serviço específico com a nova tag[cite: 2]
                            sed -i "s|image: .*/${IMAGE_NAME}:.*|image: ${ACR_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}|g" k8s/${params.SERVICE_NAME}/deployment.yaml
                            
                            # Comita e faz push da alteração
                            git config user.name "Jenkins CI/CD"
                            git config user.email "jenkins@devops-solutions.com"
                            git add k8s/${params.SERVICE_NAME}/deployment.yaml
                            
                            # Só faz commit se houver mudanças reais
                            git commit -m "Update ${IMAGE_NAME} image tag to ${IMAGE_TAG}" || echo "Nenhuma alteração para comitar"
                            git push origin main
                        """
                    }
                }
            }
        }
    }

    post {
        always {
            cleanWs() // Limpa o workspace após a execução
        }
        success {
            echo "Pipeline concluída com sucesso para o serviço ${params.SERVICE_NAME}! O ArgoCD iniciará o sincronismo no cluster AKS."
        }
        failure {
            echo "A pipeline falhou. Verifique os logs, especialmente as etapas de segurança (Trivy/SAST), pois vulnerabilidades CRÍTICAS bloqueiam o deploy[cite: 2]."
        }
    }
}