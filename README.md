# W10 — Secure & Operate: RBAC + Admission + Secrets + Supply Chain

GitOps platform triển khai đầy đủ security layers: RBAC phân quyền, Gatekeeper enforce policy, ESO rotate secret tự động, Cosign verify image signature, và multi-tenant isolation.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Repo                              │
│  push → GitHub Actions → Trivy scan → Push → Cosign sign       │
└─────────────────────┬───────────────────────────────────────────┘
                       │ GitOps (ArgoCD watches)
┌─────────────────────▼───────────────────────────────────────────┐
│                    ArgoCD (App-of-Apps)                         │
│                      argocd/root.yaml                           │
└──┬──────────┬──────────┬──────────┬──────────┬─────────────────┘
   │          │          │          │          │
   ▼          ▼          ▼          ▼          ▼
Gatekeeper  ESO      Policy     Prometheus  Argo
(policies)  (secrets) Controller  + Alert   Rollouts
   │          │          │                    │
   ▼          ▼          ▼                    ▼
ns: demo  ns: demo  ns: demo/payments    ns: demo
  RBAC    db-secret  image verify        canary deploy
  3 roles  rotate<60s  cosign sig        10%→50%→100%
   │
   ▼
ns: payments (tenant B)
  Role + RoleBinding (bó ns)
  ResourceQuota + LimitRange
  NetworkPolicy (cô lập demo)
  Guardrail tự kế thừa từ Gatekeeper
```

---

## Project Structure

```
.
├── .github/workflows/
│   └── build-push.yml          # CI: build → Trivy scan → push → Cosign sign
├── app-alert/                  # PrometheusRule SLO alerts
├── app-analysis/               # AnalysisTemplate canary validation
├── app-api/                    # API Rollout (canary, ns demo)
├── app-common/                 # Namespace demo
├── apps/
│   └── payments/               # Workload team B (ns payments)
├── argocd/
│   ├── root.yaml               # App-of-Apps entrypoint
│   └── apps/                   # 15 ArgoCD Application manifests
├── eso/                        # ExternalSecret + SecretStore (AWS)
├── gatekeeper/
│   └── policies/               # 5 ConstraintTemplate + Constraint (trong 1 file mỗi policy)
├── rbac/                       # Roles + RoleBindings (alice/bob/carol)
├── signing/
│   ├── cosign.pub              # Public key để verify
│   └── policies/               # ClusterImagePolicy
├── src/api/                    # Flask app source + Dockerfile
├── tenants/
│   └── payments/               # Namespace, RBAC, Quota, NetworkPolicy team B
└── evidence/
    ├── test-all.sh             # Test script tự động
    ├── test-violation.yaml     # Manifest vi phạm để test Gatekeeper
    └── README.md               # Hướng dẫn nghiệm thu
```

---

## Sync Wave Ordering

ArgoCD deploy theo thứ tự wave để đảm bảo dependency:

| Wave | App | Mục đích |
|------|-----|---------|
| `-1` | `gatekeeper` | OPA Gatekeeper controller + CRDs |
| `-1` | `eso` | External Secrets Operator controller + CRDs |
| `-1` | `policy-controller` | Sigstore Policy Controller + CRDs |
| `-1` | `common` | Namespace `demo` |
| `0` | `gatekeeper-policies` (templates) | ConstraintTemplates → sinh CRD mới |
| `0` | `rbac` | Role/ClusterRole/Binding cho alice/bob/carol |
| `0` | `payments` | Namespace payments + RBAC + Quota + NetworkPolicy |
| `0` | `k8s-prometheus` | Prometheus + AlertManager + Grafana |
| `0` | `k8s-rollout` | Argo Rollouts controller |
| `1` | `gatekeeper-policies` (constraints) | Constraints dùng CRD vừa tạo |
| `1` | `eso-config` | SecretStore + ExternalSecret (sau khi ESO CRD có) |
| `1` | `signing-policies` | ClusterImagePolicy (sau khi policy-controller CRD có) |
| `1` | `analysis` | AnalysisTemplate |
| `1` | `alert` | PrometheusRule |
| `2` | `api` | API Rollout (pass tất cả constraints) |
| `2` | `payments-app` | Payments Deployment (kế thừa guardrail) |

---

## Lab 1 — RBAC + Gatekeeper

### 1.1 RBAC — 3 Roles

| User | Role | Scope | Quyền |
|------|------|-------|-------|
| `alice` | `developer` (Role) | ns `demo` only | CRUD deployments, pods, services |
| `bob` | `sre` (ClusterRole) | Toàn cụm | Get/list/watch/delete pods |
| `carol` | `viewer` (ClusterRole) | Toàn cụm | Get/list/watch mọi resource |

```bash
# Nghiệm thu
kubectl auth can-i create deployments -n demo --as alice      # yes
kubectl auth can-i create deployments -n kube-system --as alice  # no
kubectl auth can-i get pods -A --as bob                       # yes
kubectl auth can-i delete nodes --as carol                    # no
```

### 1.2 Gatekeeper — 4 Constraints

| # | Rule | Risk | Namespace |
|---|------|------|-----------|
| 1 | Cấm image tag `:latest` | F-01 | demo, payments |
| 2 | Bắt buộc `resources.limits` | F-02 | demo, payments |
| 3 | Cấm `runAsUser: 0` | F-04 | demo, payments |
| 4 | Cấm `hostNetwork: true` | — | toàn cụm |

### 1.3 Custom Policy — require-owner-label

Mọi Deployment/Rollout trong `demo` và `payments` phải có label `owner`.

```bash
# Test reject
kubectl apply -f evidence/test-violation.yaml
# → Error: [no-latest-tag] [require-owner-label] [require-resource-limit]
```

**Chạy test tự động:**
```bash
bash evidence/test-all.sh
```

---

## Lab 2 — ESO + Trivy + Cosign

### 2.1 ESO — Secret Rotation < 60s

Secret lưu trên **AWS Secrets Manager**, ESO sync vào K8s Secret mỗi 60s. Pod mount qua volume → tự reload, không cần restart.

```
AWS Secrets Manager (demo/db/password)
    ↓ poll mỗi 60s (refreshInterval: 1m)
ESO Controller
    ↓ update
K8s Secret db-secret (ns demo)
    ↓ volume mount auto-reload
Pod (không restart, AGE không đổi)
```

**Setup (chạy 1 lần, không commit):**
```bash
# Tạo AWS credentials secret
kubectl create secret generic aws-creds -n demo \
  --from-literal=access-key=<AWS_ACCESS_KEY_ID> \
  --from-literal=secret-key=<AWS_SECRET_ACCESS_KEY>

# Tạo secret trên AWS
aws secretsmanager create-secret \
  --region ap-southeast-1 \
  --name demo/db/password \
  --secret-string "your-password"
```

**Nghiệm thu:**
```bash
kubectl get secretstore aws-store -n demo          # READY: True
kubectl get externalsecret db-creds -n demo        # STATUS: SecretSynced
kubectl get secret db-secret -n demo -o jsonpath='{.data.password}' | base64 -d
kubectl get pods -n demo                           # AGE không đổi sau khi rotate
```

### 2.2 Trivy + Cosign — Supply Chain Security

**CI Pipeline flow:**
```
git push → GitHub Actions
  1. Build image (local, load: true)
  2. Trivy scan CVE HIGH/CRITICAL → fail nếu có
  3. Push image → ghcr.io/kaphudong/w10-api:<semver>
  4. Cosign sign với COSIGN_PRIVATE_KEY secret
  5. Update app-api/rollout.yaml → commit
```

**GitHub Secrets cần setup:**
- `COSIGN_PRIVATE_KEY` — nội dung `cosign.key`
- `COSIGN_PASSWORD` — passphrase khi generate

**Admission verify:**
- Namespace `demo` và `payments` có label `policy.sigstore.dev/include: "true"`
- Sigstore Policy Controller reject image chưa ký

**Verify thủ công:**
```bash
cosign verify --key signing/cosign.pub ghcr.io/kaphudong/w10-api:<version>
```

---

## Challenge — Multi-tenant: Payments

### 4 yêu cầu cần chứng minh

**1. RBAC least-privilege (payments-dev)**

```bash
kubectl auth can-i create deployments -n payments --as payments-dev  # yes
kubectl auth can-i create deployments -n demo --as payments-dev      # no  ← cô lập
kubectl auth can-i update rolebindings -n payments --as payments-dev # no  ← no escalation
kubectl auth can-i get secrets -n payments --as payments-dev         # no  ← least-privilege
```

**2. ResourceQuota + LimitRange**

```bash
# Xem quota
kubectl describe resourcequota payments-quota -n payments

# Test vượt quota bị từ chối
kubectl run test --image=ghcr.io/kaphudong/w10-api:0.1.0 \
  --requests=memory=2Gi --limits=memory=2Gi -n payments
# → Error: exceeded quota

# Test pod không khai limits vẫn chạy (LimitRange inject default)
kubectl run test-nolimits --image=ghcr.io/kaphudong/w10-api:0.1.0 -n payments
kubectl get pod test-nolimits -n payments -o jsonpath='{.spec.containers[0].resources}'
# → có limits 200m/128Mi được inject
```

**3. NetworkPolicy cô lập**

```bash
# payments gọi demo bị chặn (cần minikube --cni=calico)
kubectl run test-netpol --image=curlimages/curl:8.6.0 -n payments --rm -i \
  --restart=Never -- curl -s --max-time 3 http://api.demo.svc.cluster.local/
# → curl: (28) Connection timed out
```

**4. Guardrail cũ tự áp — không viết luật mới**

```bash
# Manifest vi phạm trong payments bị Gatekeeper chặn tự động
kubectl apply -f evidence/test-violation.yaml
# → Error: [no-latest-tag] [require-owner-label] [require-resource-limit]

# App hợp lệ chạy được
kubectl get pods -n payments
# → payments-xxx Running
```

### Giải thích

**Tại sao guardrail cũ tự áp cho team B mà không cần viết luật mới?**

Gatekeeper là **cluster-level admission webhook** — nó intercept mọi admission request đến API server, không phân biệt namespace. Constraints đã khai `match.namespaces: [demo, payments]`, khi team B deploy vào ns `payments`, webhook kiểm tra ngay — không cần viết policy mới.

**Role/RoleBinding vs ClusterRoleBinding để giữ cô lập:**

| | Role + RoleBinding | ClusterRoleBinding |
|---|---|---|
| Phạm vi | Chỉ trong 1 namespace | Toàn cluster |
| `payments-dev` trong `payments` | ✅ có quyền | ✅ có quyền |
| `payments-dev` trong `demo` | ❌ không quyền | ✅ có quyền (nguy hiểm!) |
| Cô lập tenant | ✅ đảm bảo | ❌ phá vỡ cô lập |

`RoleBinding` bó scope trong namespace → `payments-dev` chỉ hoạt động trong `payments`, không với được sang `demo` hay namespace khác.

---

## Quick Start — Fresh Cluster

```bash
# 1. Start minikube với Calico CNI (cần cho NetworkPolicy)
minikube start -p w10 --driver=docker --cni=calico

# 2. Install ArgoCD
kubectl create ns argocd
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

# 3. Lấy password ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Deploy App-of-Apps
kubectl apply -f argocd/root.yaml
# ArgoCD tự sync toàn bộ platform theo sync-wave order

# 5. Tạo AWS credentials (cho ESO)
kubectl create secret generic aws-creds -n demo \
  --from-literal=access-key=<AWS_ACCESS_KEY_ID> \
  --from-literal=secret-key=<AWS_SECRET_ACCESS_KEY>

# 6. Chạy test kiểm tra
bash evidence/test-all.sh
```

---

## Components

| Component | Tool | Namespace | Purpose |
|-----------|------|-----------|---------|
| GitOps | ArgoCD | `argocd` | App-of-Apps, sync-wave orchestration |
| Progressive Delivery | Argo Rollouts | `argo-rollouts` | Canary 10%→50%→100% + auto rollback |
| Admission Policy | OPA Gatekeeper | `gatekeeper-system` | 5 constraints enforce |
| Secret Rotation | External Secrets | `external-secrets` | AWS SM → K8s Secret, refresh 60s |
| Image Signing | Sigstore/Cosign | `cosign-system` | Verify signature trước khi deploy |
| CVE Scanning | Trivy | CI (GitHub Actions) | Block HIGH/CRITICAL CVE |
| Monitoring | kube-prometheus-stack | `monitoring` | Metrics + Alerts + Grafana |
| Team A workload | Flask API | `demo` | Canary deploy, metrics |
| Team B workload | Payments | `payments` | Isolated tenant |
