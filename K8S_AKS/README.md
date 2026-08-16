# K8S_AKS — Manifestos Kubernetes (AKS)

Manifestos para implantar o ToggleMaster no AKS. Um diretório por serviço,
mais pastas transversais (`ingress/`, `scaling/`).

## Contratos (combinem estes nomes antes de escrever o resto dos YAMLs)

Um serviço acha o outro pelo **DNS interno do K8s**: `http://<service>.<namespace>:80`
(ou só `http://<service>` no mesmo namespace). Isso substitui os `http://localhost:800X`.

| Serviço | Porta container | Service (ClusterIP) | Namespace | Secret | ConfigMap |
|---|---|---|---|---|---|
| auth-service | 8001 | `auth-service:80` | toggle-apps | `auth-service-secret` | `auth-service-config` |
| flag-service | 8002 | `flag-service:80` | toggle-apps | `flag-service-secret` | `flag-service-config` |
| targeting-service | 8003 | `targeting-service:80` | toggle-apps | `targeting-service-secret` | `targeting-service-config` |
| evaluation-service | 8004 | `evaluation-service:80` | toggle-apps | `evaluation-service-secret` | `evaluation-service-config` |
| analytics-service | 8005 | (worker — sem rota no Ingress) | toggle-apps | `analytics-service-secret` | `analytics-service-config` |

> Ex.: no flag-service, `AUTH_SERVICE_URL` passa a ser `http://auth-service.toggle-apps`
> (não `http://localhost:8001`).

## Ordem de aplicação

```bash
# 1) Namespaces
kubectl apply -f 00-namespaces.yaml

# 2) Config + Secret ANTES do Deployment (o Pod precisa deles pra subir)
kubectl apply -f auth-service/configmap.yaml
# Secret real via kubectl (NÃO comitar valores). Veja auth-service/secret.example.yaml:
kubectl create secret generic auth-service-secret -n toggle-apps \
  --from-literal=DATABASE_URL="postgres://USER:PASS@HOST:5432/auth_db?sslmode=require" \
  --from-literal=MASTER_KEY="valor-forte"

# 3) Deployment + Service
kubectl apply -f auth-service/deployment.yaml
kubectl apply -f auth-service/service.yaml

# 4) Verificar
kubectl get pods -n toggle-apps
kubectl logs -n toggle-apps deploy/auth-service
```

Quando o auth-service estiver `Ready`, replique o template para os outros 4,
depois faça `ingress/` e por fim `scaling/`.

## ⚠️ Segurança
- O **Secret real NUNCA** vai pro git. Só `secret.example.yaml` (modelo com placeholders).
- Adicionem ao `.gitignore` qualquer arquivo de secret real (ex.: `*-secret.yaml` que não seja `.example`).
