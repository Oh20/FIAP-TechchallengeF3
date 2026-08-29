# TCF3 - K8S — GitOps via ArgoCD

Repositório que o ArgoCD observa. O padrão é **App-of-Apps**: um único root app é
aplicado à mão uma vez; a partir daí **adicionar/alterar app = commit**, o Argo reconcilia.

## Estrutura

```
TCF3-K8S/
├── argocd/
│   ├── root-app.yaml            # App-of-Apps — o UNICO aplicado a mao (bootstrap)
│   └── apps/                    # o root observa esta pasta; cada arquivo = 1 Application
│       ├── apache-test.yaml         # path .          -> ns agrmudoufeladapulta (teste)
│       ├── auth-service.yaml        # overlays/prod/auth-service        -> ns toggle-apps
│       ├── analytics-service.yaml   # overlays/prod/analytics-service   -> ns toggle-apps
│       ├── evaluation-service.yaml  # overlays/prod/evaluation-service  -> ns toggle-apps
│       ├── flag-service.yaml        # overlays/prod/flag-service        -> ns toggle-apps
│       ├── targeting-service.yaml   # overlays/prod/targeting-service   -> ns toggle-apps
│       └── platform.yaml            # overlays/prod/platform (ingress+HPAs) -> ns toggle-apps
├── kustomization.yaml           # raiz: apache-test (ns agrmudoufeladapulta)
├── apache-deployment.yaml / apache-service.yaml
├── teste-apache/                # apache em ns toggle-apps (deploy imperativo, fora do Argo)
├── base/<serviço>/              # bases kustomize: configmap + deployment + service
└── overlays/{dev,prod}/<serviço>/  # overlays: namespace + tag da imagem
```

Regra que trava se ignorada: manifesto de **Application** e **workload** não moram no mesmo
path. O root observa `argocd/apps/`; cada Application aponta para o overlay/raiz do workload.

## Bootstrap (uma vez só)

O repo, o cluster (`in-cluster`) e o project (`default`) já estão registrados no Argo.
Falta aplicar o root:

```bash
kubectl --context fiaptc3 -n argocd apply -f argocd/root-app.yaml
```

O `tcf3-root` cria as 7 Applications sozinho e sincroniza. Tudo o mais é Git.

> Os manifestos precisam estar **no remoto** antes disto — o Argo lê do Git, não do disco.

## Decisões

- **apache-test** é auto-contido (`httpd:2.4-alpine`, imagem pública): prova o loop sem ACR.
- **analytics/evaluation** declaram `ignoreDifferences` em `spec/replicas` — o HPA (app
  `platform`) gerencia esse campo; sem isso o `selfHeal` reverteria o autoscaling e o app
  ficaria `OutOfSync` para sempre.
- **Secrets e migrations fora do Git** (`secret.example.yaml`, `migration-job.yaml` ficam
  fora das bases) — vêm do pipeline. Por isso os 5 serviços podem subir `Degraded`
  (ImagePull/secret ausente) até o pipeline prover imagem e segredo; o **sync** em si valida.

## Adicionar um app novo

1. Crie o workload (`base/` + `overlays/prod/<novo>/`).
2. Crie `argocd/apps/<novo>.yaml` apontando para o overlay.
3. Commit + push. O `tcf3-root` cria a Application e sincroniza.

## Validar / testar drift

```bash
kubectl --context fiaptc3 -n argocd get applications
kubectl --context fiaptc3 -n agrmudoufeladapulta get deploy,svc,pods
# drift: mude replicas no apache-deployment.yaml, commit+push -> Argo reconcilia sozinho
```
