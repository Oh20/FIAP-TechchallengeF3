**🔗 Links do Projeto**
• 🎬 **Vídeo de Demonstração:** [\[Link do Vídeo\]](https://www.youtube.com/watch?v=U7REFyUZ9BQ)
• 💻 **Repositório da Aplicação (Microsserviços):** [\[Link do Repo\]](https://github.com/Oh20/FIAP---TechchallengeF2/blob/main/azure-pipelines.yml)

## 📌 Visão Geral

Nesta segunda fase do projeto, o **ToggleMaster** evoluiu de uma arquitetura monolítica (Fase 1) para uma arquitetura distribuída baseada em **Microsserviços**. O objetivo principal foi resolver as limitações de escalabilidade, acoplamento e resiliência identificadas anteriormente, adotando práticas Cloud Native.

A infraestrutura foi provisionada no **Microsoft Azure**, utilizando orquestração de contêineres via Kubernetes e serviços gerenciados de banco de dados e mensageria, cobrindo os seguintes requisitos técnicos:

- Orquestração de contêineres com Kubernetes (`AKS`).
- Comunicação síncrona e assíncrona entre microsserviços.
- Persistência poliglota (Uso de bancos de dados relacionais, NoSQL e Cache em memória).
- Escalabilidade horizontal baseada em métricas de CPU e tamanho de filas (`HPA` / `KEDA`).

## 🏗️ Arquitetura da Solução

Conforme o diagrama arquitetural desenhado, a solução foi projetada para alta disponibilidade e separação de responsabilidades.

Visando um alto nível de compatibilidade entre recursos, mantendo escalabilidade, alta disponibilidade e eficiência de custo máxima, optamos pela Stack inteiramente disponibilizada através do Azure, tirando proveito de integração de recuros do Azure DevOps

**Componentes Principais:**

- **Azure Kubernetes Service (AKS):** Orquestrador de contêineres responsável por gerenciar e escalar os *Pods* dos 5 microsserviços (`auth`, `flag`, `targeting`, `analytics` e `evaluation`).
- **Application Gateway:** Atua como ponto de entrada (Layer 7) da aplicação. Recebe o tráfego da internet e roteia diretamente para os IPs dos Pods internos de forma segura, permitindo o isolamento dos services do k8s e abstraindo a gestão de acesso para o Application Gateway.
- **Application Gateway Ingress Controller (AGIC):** Faz o mapeamento e controle de regras, integrando o Applicaition Gateway no AKS, fazendo o ingress para os nossos PODs
- **Bancos de Dados Relacionais (Azure Database for PostgreSQL):** Três instâncias ou bancos separados para garantir o isolamento de dados dos serviços `auth-service`, `flag-service` e `targeting-service`.
- **Cache em Memória (Azure Managed Redis):** Utilizado exclusivamente pelo `evaluation-service` para armazenar o estado das flags, reduzindo drasticamente a latência e o número de requisições aos bancos relacionais.
- **Mensageria Assíncrona (Azure Service Bus):** Atua como um *broker* de mensagens. O `evaluation-service` publica eventos de uso de flags nesta fila para não bloquear a resposta ao usuário.
- **Banco de Dados NoSQL (Azure CosmosDB):** Utilizado pelo `analytics-service` para consumir as mensagens do Service Bus e gravar os eventos em altíssima velocidade e esquema flexível.
- **Azure DevOps:** Centralizando nosso Repositório de código, e Pipeline de CI/CD, além de trazer segurança com as variáveis de ambiente
- **Azure Conteiner Registry (ACR):** Armazenando nossas imagens de forma eficiente no ACR, e integrando facilmente no Pipeline para provisionamento rápido no AKS

## 🔄 Fluxo da Aplicação (Hot Path)

No funcionamento da nova arquitetura, o fluxo de avaliação de uma flag ocorre da seguinte maneira:

1. **Requisição Externa:** O usuário acessa a API via HTTP/HTTPS batendo no IP público do Application Gateway.
2. **Roteamento Ingress:** O AGIC direciona a requisição `GET /evaluate` para um Pod disponível do `evaluation-service`.
3. **Validação de Cache:** O `evaluation-service` consulta o Redis. Se a flag estiver em cache (*Cache Hit*), ele pula o passo 4.
4. **Comunicação Síncrona:** Em caso de *Cache Miss*, o `evaluation-service` faz requisições HTTP internas para o `flag-service` e `targeting-service`. O `flag-service`, por sua vez, consulta o `auth-service` para validar a API Key.
5. **Retorno ao Cliente:** A decisão da flag é calculada e devolvida ao usuário (JSON `200 OK`).
6. **Mensageria Assíncrona:** Sem atrasar a resposta, o `evaluation-service` envia um evento para a fila do Azure Service Bus informando que a flag foi avaliada.
7. **Consumo e Persistência:** O `analytics-service` consome essa mensagem e a persiste permanentemente no CosmosDB.

## CI/CD - Automação de Build, Push e deploy

Visando agilizar o processo de desenvolvimento/provisionamento, implantamos um CI/CD visando o build da imagem para nosso repositório (ACR - Azure Container Instace), e deploy no nosso cluster (AKS - Azure Kubernetes Service), além de Provisionar de forma automatica as regras de AGIC, otimizando custos para o projeto, durante processo de teste, permitindo o provisionamento agíl com configurações pré setadas.

O CI/CD ficou responsável pelas etapas: 

- BUILD: Através de um Path-Filter, o nosso pipe observa alterações nas imagens, e avalia a necessidade de um novo Build ao ACR, monitorando alterações diretas no repositório da aplicação/imagem
- PUSH: Caso seja identificada alterações em quaisquer containers, o Pipeline se encarrega além do build, na publicação do container direto ao ACR, autenticando via variáveis de ambiente
- Deploy: Neste ponto, temos mais complexidade, o Deploy se encarrega de aplicar algumas politicas especificas, necessárias para fluidez do projeto
    - Secrets, ConfigMaps e Migrations: o Pipeline se encarrega de Aplicar os secrets com mapeamentos para Variaveis de ambiente do Azure DevOps, mantendo a segurança do nosso ambiente, e automatizando a migração do banco (Trazendo flexibilidade para apagar e provisionar o banco de acordo com necessidade de reduzir custos)
    - Deploy ao AKS: O Pipeline faz o deploy no AKS diretamente no Azure, autenticando de forma segura através de conections de serviços do Azure DevOps, esta etapa sobe todos os nossos containers.
- Expose: Etapa responsável pela exposição de seviços via Ingress e Setup de HPA
    - Ingress: Pela escolha do Application Gateway, vimos a necessidade de usar o AGIC (Application Gateway Ingress Controller), que é o responsável pelo mapeamento de regras ao nosso ambiente, entregando o controle de Ingress ao Application Gateway
    - HPA: Escala automaticamente recursos para atender a demanda da fila, sem a necessidade de ReplicaSets Fixos, e permitindo que nossos Consumers e Producers acompanhem a demanda de forma escalável

 

## 💰 Estimativa de Custos (Resumo)

Com a evolução para microsserviços gerenciados na nuvem, o custo deixa de ser focado em uma única VM e passa a ser distribuído pelos serviços do Azure, Considerando um ambiente produtivo.

| Descrição | Serviço Azure | Mensal (Estimativa) | OBS:  |
| --- | --- | --- | --- |
| **Orquestração de Contêineres** | Azure Kubernetes Service (AKS) | R$ **724.82** | Considerando a capacidade de escalonamento, 2x 2vCPUs e 8GB de Ram, montam nosso cluster |
| **Ponto de Entrada e WAF** | Application Gateway (AGIC) | R$ **755.02** | Para o uso do AGIC, precisamos do Standard V2 o que nos traz WAF, logo aumento de custo justificável  |
| **Bancos de Dados Relacionais** | Azure Database for PostgreSQL | R$ **192.53** | 1 vCore por banco, uma vez que nossa aplicação possui baixo consumo, e está separa entre 3 instancias diferentes (um para cada micro serviço) |
| **Cache em Memória** | Azure Managed Redis | R$ 241.61 | Custo minimo com HA |
| **Mensageria Assíncrona** | Azure Service Bus | R$ 6.21 | Considerando um consumo excessivo, e tirando proveito do free tier  |
| **Banco de Dados NoSQL** | Azure CosmosDB | R$ **2.59** | Modalidade Serverless, nos trazendo escalabilidade e economia  |
| **Repositório de Imagem** | Azure Container Registry | R$ 25.85 | Poucas imagens à serem armazenadas |
| **Total Estimado** | - | R$ 1,976.09 | - |

## 🎯 Conclusão

A migração do monolito para a arquitetura de microsserviços no Azure cumpriu seu papel estratégico. As limitações de engessamento de deploy e fragilidade do processo único da Fase 1 foram totalmente superadas através da conteinerização e do orquestrador Kubernetes.

Os desafios de comunicação de rede, vazamento de contexto de autenticação e criação automatizada de tabelas foram solucionados seguindo boas práticas de DevOps, como injeção segura de variáveis via `.env` e persistência de volumes.

O sistema atual está apto para receber picos de requisições, possuindo resiliência assíncrona com o Service Bus e escalabilidade autônoma baseada em métricas reais da operação, configurando um ambiente Cloud Native maduro e altamente disponível.

---

| Aluno | RM |
| --- | --- |
| Antony Matheus L Nascimento | 370340 |
| Daniel da Silva Junior | 370558 |
| Evandro Gomes da Silva | 373593 |
| Juan Rodrigues | 373074 |
| Gabriel Mota | 373164 |