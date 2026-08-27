# TCF3 - K8S — mock GitOps para o ArgoCD

Repositório que o ArgoCD observa para validar o loop GitOps ponta a ponta.
Uma Application do Argo aponta para a **raiz** deste repo (`path: .`) e sincroniza
os manifestos abaixo no AKS.

## Conteúdo

| Arquivo | Recurso | Para quê |
|---|---|---|
| `deployment.yaml` | Deployment `mock-nginx` (2 réplicas, `nginx:1.27-alpine`) | Carga de teste com probes — dá ao Argo um sinal real de *Healthy* |
| `service.yaml` | Service `mock-nginx` (ClusterIP :80) | Segundo recurso a reconciliar + endpoint para validar |

Imagem pública: **não** depende do ACR nem de secrets. Sem namespace fixo nos
manifestos — os objetos caem no `destination.namespace` que a Application do Argo define.

## Validar o loop

1. Confirme a sincronização:

```bash
argocd app get <nome-da-app> --grpc-web
kubectl -n <destination-namespace> get deploy,svc,pods -l app=mock-nginx
```

2. Provoque um drift e veja o Argo reconciliar — mude `replicas: 2 → 3` em
   `deployment.yaml`, faça commit e push. Com `automated` ligado, o Argo detecta o
   commit e sincroniza sozinho; senão, `argocd app sync <nome-da-app>`.

3. Teste o pod:

```bash
kubectl -n <destination-namespace> port-forward svc/mock-nginx 8080:80
# http://localhost:8080 → página padrão do nginx
```

## Remover

```bash
kubectl -n <destination-namespace> delete -f service.yaml -f deployment.yaml
# ou, se preferir pelo Argo: argocd app delete <nome-da-app>
```
