# Walkthrough — W10 Security Lab

Tài liệu này giải thích **từng luồng hoạt động** của platform: cái gì chạy khi nào, tại sao cấu hình như vậy, và dữ liệu đi qua hệ thống ra sao.

---

## 1. Toàn cảnh: Platform khởi động từ 1 lệnh

```bash
kubectl apply -f argocd/root.yaml
```

Một lệnh duy nhất kéo toàn bộ platform lên. ArgoCD đọc `argocd/root.yaml` → phát hiện folder `argocd/apps/` → tạo 15 Application → tự sync theo thứ tự wave.

```
kubectl apply -f argocd/root.yaml
        │
        ▼
┌───────────────────┐
│   ArgoCD Root App │  ← watches argocd/apps/
└────────┬──────────┘
         │ tạo 15 child Application
         ▼
  Wave -1  Wave 0  Wave 1  Wave 2
  (infra)  (cfg)  (rules) (workload)
```

**Tại sao dùng App-of-Apps pattern?**
Một file duy nhất (`root.yaml`) làm "mục lục" — chỉ cần apply file đó, ArgoCD tự phát hiện và deploy mọi thứ còn lại. Không cần chạy nhiều lệnh, không bỏ sót bước nào.

---

## 2. Sync Wave — Thứ tự deploy có chủ ý

Kubernetes không đảm bảo thứ tự apply. ArgoCD sync-wave giải quyết vấn đề dependency:

```
Wave -1 ──────────────────────────────────────────────────────────
  gatekeeper        → Cài OPA Gatekeeper, tạo CRD ValidatingWebhook
  eso               → Cài External Secrets Operator, tạo CRD SecretStore
  policy-controller → Cài Sigstore Policy Controller, tạo CRD ClusterImagePolicy
  common            → Tạo namespace demo
         │
         │ ArgoCD chờ tất cả wave -1 Healthy
         ▼
Wave 0 ────────────────────────────────────────────────────────────
  gatekeeper-policies (templates)  → Apply 5 ConstraintTemplate
                                     Gatekeeper sinh 5 CRD mới
                                     (K8sNoLatestTag, K8sRequireOwnerLabel, ...)
  rbac              → Role/ClusterRole + Binding cho alice/bob/carol
  payments          → Namespace payments + RBAC + Quota + NetworkPolicy
  k8s-prometheus    → Prometheus + AlertManager + Grafana
  k8s-rollout       → Argo Rollouts controller
         │
         │ ArgoCD chờ tất cả wave 0 Healthy
         ▼
Wave 1 ────────────────────────────────────────────────────────────
  gatekeeper-policies (constraints) → Apply 5 Constraint
                                      (CRD đã có từ wave 0 → apply thành công)
  eso-config        → SecretStore + ExternalSecret
                      (ESO CRD đã có → apply thành công)
  signing-policies  → ClusterImagePolicy
                      (Policy Controller CRD đã có → apply thành công)
  analysis          → AnalysisTemplate cho canary
  alert             → PrometheusRule SLO alerts
         │
         ▼
Wave 2 ────────────────────────────────────────────────────────────
  api               → Argo Rollout (canary) cho team demo
  payments-app      → Deployment cho team payments
                      (Gatekeeper đã enforce → manifest phải hợp lệ)
```

**Tại sao tách wave 0 và wave 1 cho Gatekeeper?**

`ConstraintTemplate` khi apply sẽ trigger Gatekeeper controller sinh ra CRD mới (vd `K8sNoLatestTag`). Quá trình này mất vài giây. Nếu `Constraint` apply ngay lập tức (trong cùng wave), API server chưa biết CRD đó tồn tại → lỗi "no matches for kind". Tách ra 2 wave trong cùng 1 App, ArgoCD đảm bảo wave 0 hoàn thành trước khi wave 1 bắt đầu.

---

## 3. CI/CD Pipeline — Build → Scan → Sign

Mỗi khi push code vào `src/api/` hoặc sửa workflow file:

```
Developer push code
        │
        ▼
GitHub Actions (.github/workflows/build-push.yml)
        │
        ├─ Step 1: Checkout + tính semantic version
        │          paulhatch/semantic-version đọc commit message:
        │          "feat: ..." → bump minor (0.1.0 → 0.2.0)
        │          "fix: ..."  → bump patch (0.1.0 → 0.1.1)
        │          "BREAKING CHANGE:" → bump major
        │
        ├─ Step 2: Login GHCR
        │          docker login ghcr.io với GITHUB_TOKEN
        │
        ├─ Step 3: Build image (local only, chưa push)
        │          docker buildx build --load
        │          Tags: latest, 0.2.0, v0.2.0-abc1234
        │
        ├─ Step 4: Trivy scan ← SECURITY GATE
        │          aquasecurity/trivy-action@0.30.0
        │          Quét image local vừa build
        │          severity: HIGH, CRITICAL
        │          exit-code: 1 → CI fail nếu có CVE
        │          ignore-unfixed: true → bỏ qua CVE chưa có patch
        │          ┌──────────────────────────────┐
        │          │ Nếu PASS → tiếp tục          │
        │          │ Nếu FAIL → pipeline dừng,    │
        │          │ image KHÔNG được push        │
        │          └──────────────────────────────┘
        │
        ├─ Step 5: Push image → ghcr.io/kaphudong/w10-api
        │          Chỉ push sau khi scan pass
        │
        ├─ Step 6: Cosign sign ← SUPPLY CHAIN
        │          cosign sign --key env://COSIGN_PRIVATE_KEY
        │          Signature lưu trong registry cạnh image
        │          (dạng OCI artifact, không phải file riêng)
        │
        ├─ Step 7: Update rollout.yaml
        │          sed đổi image tag trong app-api/rollout.yaml
        │          git commit + push → trigger ArgoCD sync
        │
        └─ Step 8: Create git tag v0.2.0
```

**Tại sao build 2 lần (load + push)?**

Trivy chỉ scan được image đang có local. Nếu push trước rồi scan, image xấu đã lên registry rồi mới phát hiện — quá muộn. Flow đúng: build local → scan → nếu pass mới push.

---

## 4. Gatekeeper — Manifest bị chặn như thế nào

Mỗi lần `kubectl apply` hoặc ArgoCD sync một resource, API server gọi Gatekeeper webhook **trước khi** lưu vào etcd:

```
kubectl apply -f deployment.yaml
        │
        ▼
API Server
  │
  ├─ Authentication (bạn là ai?)
  ├─ Authorization / RBAC (bạn có quyền không?)
  │
  └─ Admission Webhooks ← Gatekeeper ở đây
       │
       ▼
  Gatekeeper evaluates tất cả Constraints match resource này
       │
       ├─ K8sNoLatestTag.check(image)
       │    image = "nginx:latest" → violation!
       │
       ├─ K8sRequireResourceLimit.check(containers)
       │    limits.cpu = nil → violation!
       │
       ├─ K8sRequireOwnerLabel.check(labels)
       │    labels["owner"] missing → violation!
       │
       └─ Kết quả:
            violations > 0 → HTTP 403 Forbidden
            "Error from server: admission webhook denied the request"
            Resource KHÔNG vào etcd, KHÔNG deploy
```

**5 Constraints và logic Rego:**

```
no-latest-tag (K8sNoLatestTag)
  Scope: Pod trong ns demo, payments
  Logic: endswith(image, ":latest") OR not contains(image, ":")
  → "nginx" (không có tag) cũng bị chặn

require-resource-limit (K8sRequireResourceLimit)
  Scope: Pod trong ns demo, payments
  Logic: not container.resources.limits.cpu
         OR not container.resources.limits.memory
  → Thiếu 1 trong 2 đều bị chặn

no-run-as-root (K8sNoRunAsRoot)
  Scope: Pod trong ns demo, payments
  Logic: container.securityContext.runAsUser == 0
         OR pod.spec.securityContext.runAsUser == 0
  → Check cả pod-level lẫn container-level

no-host-network (K8sNoHostNetwork)
  Scope: Pod TOÀN CỤM (không giới hạn namespace)
  Logic: input.review.object.spec.hostNetwork == true

require-owner-label (K8sRequireOwnerLabel)
  Scope: Deployment, Rollout trong ns demo, payments
  Logic: label "owner" không có trong metadata.labels
  → Áp cho Deployment và Argo Rollout (không phải Pod)
```

**Tại sao Gatekeeper tự áp cho team payments mà không cần viết luật mới?**

Constraints khai `match.namespaces: [demo, payments]`. Khi team payments deploy Deployment mới, API server gọi Gatekeeper webhook → constraint check → nếu vi phạm thì reject. Không cần biết đây là team nào, Gatekeeper không quan tâm — nó chỉ nhìn resource manifest.

---

## 5. ESO — Secret Rotation không restart Pod

```
AWS Secrets Manager
  secret: demo/db/password = "pass123"
        │
        │ ESO controller poll mỗi refreshInterval (1m)
        ▼
External Secrets Operator
  ExternalSecret "db-creds" (ns demo)
    refreshInterval: 1m
    secretStoreRef: aws-store
    target: db-secret
        │
        │ Mỗi 60s ESO gọi AWS API GetSecretValue
        ▼
K8s Secret "db-secret" (ns demo)
  data:
    password: cGFzczEyMw==  ← base64("pass123")
    username: ZGJ1c2Vy
        │
        │ Pod mount Secret dưới dạng volume file
        ▼
Pod containers
  /etc/secrets/password  ← Linux kernel tự update file
  App đọc file → thấy password mới ngay
  Không cần restart process
```

**Tại sao mount volume thay vì env var?**

- `env var`: giá trị được inject lúc container khởi động, không thay đổi cho đến khi restart
- `volume mount`: Kubelet watch Secret object, khi Secret thay đổi → Kubelet update file trên disk trong vài giây

Đây là lý do pod không cần restart khi rotate.

**SecretStore — 2 cách authenticate với AWS:**

```yaml
# Cách 1: EKS thật (IRSA - không hardcode key)
auth:
  jwt:
    serviceAccountRef:
      name: eso-sa   # SA có IAM role annotation

# Cách 2: minikube lab (access key)
auth:
  secretRef:
    accessKeyIDSecretRef:
      name: aws-creds   # K8s Secret chứa key
      key: access-key
```

Lab này dùng cách 2. `aws-creds` Secret tạo tay bằng `kubectl create secret` — không bao giờ commit vào git.

---

## 6. Cosign — Image Signature Verification

### Luồng sign (CI)

```
CI build image → push → ghcr.io/kaphudong/w10-api:0.2.0
                                    │
cosign sign --key cosign.key        │
                                    ▼
                         ghcr.io/kaphudong/w10-api
                           ├── :0.2.0          (image)
                           └── :sha256-abc...  (signature OCI artifact)
```

Signature không phải file riêng — nó là một OCI artifact khác trong cùng registry, được tag bằng digest của image gốc.

### Luồng verify (Admission)

```
kubectl apply deployment với image: ghcr.io/kaphudong/w10-api:0.2.0
        │
        ▼
Sigstore Policy Controller (webhook)
        │
        ├─ Namespace có label policy.sigstore.dev/include=true?
        │    demo: yes, payments: yes → enforce
        │
        ├─ Image match glob "ghcr.io/kaphudong/w10-api*"?
        │    yes → check signature
        │
        ├─ Pull signature artifact từ registry
        │    ghcr.io/kaphudong/w10-api:sha256-abc...
        │
        ├─ Verify với public key trong ClusterImagePolicy
        │    cosign.pub:
        │    -----BEGIN PUBLIC KEY-----
        │    MFkwEwYHKoZI...
        │    -----END PUBLIC KEY-----
        │
        └─ Kết quả:
             verify OK  → cho deploy
             verify FAIL → HTTP 403, image chưa ký hoặc key không khớp
```

**Tại sao enable label TRƯỚC khi ký sẽ gây vấn đề?**

Nếu gắn `policy.sigstore.dev/include: "true"` vào namespace `demo` khi image chưa có signature, tất cả Pod mới (kể cả Pod của Argo Rollouts đang chạy canary) sẽ bị reject → platform sập. Thứ tự đúng: CI ký image trước → sau đó mới enable label.

---

## 7. RBAC — Phân quyền 3 tầng

### Team demo (Lab 1.1)

```
alice ──→ RoleBinding "alice-developer" ──→ Role "developer" (ns demo)
                                             rules:
                                             - apps: deployments, rollouts → CRUD
                                             - core: pods, services → CRUD
                                             # KHÔNG có: nodes, secrets, clusterroles

bob ───→ ClusterRoleBinding "bob-sre" ───→ ClusterRole "sre" (toàn cụm)
                                           rules:
                                           - pods: get/list/watch/delete
                                           - nodes, namespaces: get/list/watch
                                           # KHÔNG có: create/update/delete deployments

carol ─→ ClusterRoleBinding "carol-viewer" → ClusterRole "viewer" (toàn cụm)
                                             rules:
                                             - "*": get/list/watch
                                             # KHÔNG có: create/update/delete/patch
```

**API server flow khi alice chạy `kubectl create deployment`:**

```
kubectl create deploy test -n demo --as alice
        │
        ▼
API Server Authorization
  Check: User "alice" có verb "create" trên "deployments" trong ns "demo"?
  Tìm: RoleBinding "alice-developer" trong ns "demo"
  RoleRef: Role "developer"
  Role rules: apiGroups["apps"] resources["deployments"] verbs["create"] ✓
  → ALLOW

kubectl create deploy test -n kube-system --as alice
        │
        ▼
API Server Authorization
  Check: User "alice" có verb "create" trên "deployments" trong ns "kube-system"?
  Tìm: Không có RoleBinding nào cho alice trong kube-system
  Không có ClusterRoleBinding nào
  → DENY (403 Forbidden)
```

### Team payments (Challenge)

```
payments-dev ──→ RoleBinding "payments-dev-binding" ──→ Role "payments-developer"
                 (ns payments)                           (ns payments)
                                                         rules:
                                                         - apps: deployments → CRUD
                                                         - core: pods, services → CRUD
                                                         # BỎ: secrets (least-privilege)
                                                         # BỎ: rolebindings (no escalation)
```

**Tại sao dùng Role thay vì ClusterRole?**

`ClusterRole` + `ClusterRoleBinding` cho phép payments-dev thao tác trên **mọi namespace** trong cluster. `Role` + `RoleBinding` bó cứng trong ns `payments` — payments-dev không biết ns `demo` tồn tại từ góc độ RBAC.

---

## 8. Multi-tenant Isolation — payments namespace

### ResourceQuota + LimitRange phối hợp

```
Pod không khai resources:
        │
        ▼
LimitRange "payments-limitrange" inject default:
  limits.cpu: 200m
  limits.memory: 128Mi
  requests.cpu: 100m
  requests.memory: 64Mi
        │
        ▼
ResourceQuota "payments-quota" kiểm tổng:
  Tổng limits.cpu hiện tại + 200m ≤ 1000m? → OK
  Tổng limits.memory hiện tại + 128Mi ≤ 1Gi? → OK
        │
        ▼ (nếu vượt quota)
  API Server: exceeded quota → 403
```

**Tại sao cần cả 2?**

- Chỉ có Quota: Pod không khai limits → Quota không biết tính bao nhiêu → Pod chạy unlimited → node OOM
- Chỉ có LimitRange: Inject default nhưng không giới hạn tổng → 100 pod mỗi pod 200m = 20 CPU → node sập
- Có cả 2: LimitRange inject default → Pod luôn có limits → Quota đếm được chính xác → giới hạn tổng ngân sách

### NetworkPolicy flow

```
Pod trong payments cố gọi api.demo.svc.cluster.local:
        │
        ▼
Linux kernel (iptables/eBPF, enforce bởi Calico CNI)
  Check NetworkPolicy "deny-egress-to-demo":
    policyTypes: Egress
    egress rules:
      - allow DNS (port 53)
      - allow to podSelector: {} trong cùng ns
      - allow to namespaceSelector NOT IN [demo]
    → Packet đến demo namespace → không match rule nào → DROP
        │
        ▼
curl: (28) Connection timed out
```

**Tại sao cần 2 NetworkPolicy riêng?**

- `default-deny-ingress`: Chặn traffic **vào** payments từ bên ngoài → team demo không gọi được vào payments
- `deny-egress-to-demo`: Chặn traffic **ra** từ payments sang demo → payments không gọi được sang demo

Chỉ có `default-deny-ingress` → payments vẫn gọi **ra** demo được (egress không bị chặn). Cần cả 2 để cô lập 2 chiều.

**Lưu ý:** NetworkPolicy chỉ hoạt động khi CNI hỗ trợ (Calico, Cilium). Flannel mặc định của minikube **không enforce** NetworkPolicy. Cần: `minikube start --cni=calico`.

---

## 9. Canary Deployment Flow (Argo Rollouts)

Khi CI push image mới và update `app-api/rollout.yaml`:

```
ArgoCD detect rollout.yaml thay đổi → sync
        │
        ▼
Argo Rollouts controller
        │
        ├─ Step 1: setWeight 10%
        │    4 pods total → 1 pod chạy image mới (canary)
        │                   3 pod chạy image cũ (stable)
        │    Service "api" load balance 25% traffic → canary
        │
        ├─ Step 2: pause 2m
        │    Đợi 2 phút, collect metrics
        │
        ├─ Step 3: AnalysisRun bắt đầu (startingStep: 1)
        │    AnalysisTemplate "success-rate" query Prometheus:
        │    rate(flask_http_request_total{status!~"5.."}[5m])
        │    / rate(flask_http_request_total[5m]) ≥ 0.95
        │    ┌─────────────────────────────────────┐
        │    │ success rate ≥ 95% → continue       │
        │    │ success rate < 95% → auto rollback  │
        │    └─────────────────────────────────────┘
        │
        ├─ Step 4: setWeight 50% (nếu pass)
        │    2 pod canary, 2 pod stable
        │
        ├─ Step 5: pause 2m + analysis
        │
        └─ Step 6: setWeight 100%
             4 pod chạy image mới hoàn toàn
             old ReplicaSet scale down → 0
```

**Tại sao canary thay vì rolling update?**

Rolling update thay thế từng pod nhưng không kiểm metric tự động. Nếu image mới có bug, rolling update vẫn tiếp tục cho đến khi tất cả pod bị thay. Canary + analysis dừng lại và rollback tự động khi metric xấu.

---

## 10. Alerting Flow

```
Flask API trả 500 (ERROR_RATE > 0)
        │
        ▼
Prometheus scrape /metrics qua ServiceMonitor
  flask_http_request_total{status="500"} tăng
        │
        ▼
PrometheusRule "api-slo-alerts" evaluate mỗi 1m
  alert: ApiHighErrorRate
  expr: rate(flask_http_request_total{status=~"5.."}[5m]) > 0.05
  for: 2m  ← alert chỉ fire sau 2 phút liên tục
        │
        ▼
AlertManager nhận alert
  route → receiver "email-notifications"
        │
        ▼
Gmail SMTP → email tới vuongbachdoan@gmail.com
  Subject: 🚨 [W10 Demo Alert] ApiHighErrorRate - critical
```

---

## 11. Tóm tắt các quyết định thiết kế

| Quyết định | Lý do |
|-----------|-------|
| App-of-Apps thay vì apply từng file | 1 lệnh deploy toàn platform, không bỏ sót |
| Sync wave thay vì manual ordering | Tự động, idempotent, không cần người giám sát |
| Gộp Template + Constraint trong 1 file | Wave annotation trên resource level → sync nhanh, không cần 2 App |
| Disable ESO webhook | Tránh race condition với CRD chưa sẵn sàng |
| Build local trước khi push | Trivy chỉ scan được image local → không push image xấu |
| Role thay vì ClusterRole cho payments-dev | Bó scope trong namespace → cô lập tenant thật sự |
| LimitRange + ResourceQuota kết hợp | LimitRange inject default để Quota đếm được chính xác |
| 2 NetworkPolicy (ingress + egress) | Cô lập 2 chiều: không gọi vào được, không gọi ra được |
| `ignore-unfixed: true` trong Trivy | Tránh block CI vĩnh viễn vì CVE chưa có patch từ vendor |
| `refreshInterval: 1m` trong ESO | Đủ nhanh để demo rotate < 60s, không spam AWS API |
