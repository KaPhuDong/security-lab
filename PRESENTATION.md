# W10 Lab — Tóm tắt trình bày với Mentor

> Mục tiêu: Giải thích ngắn gọn những gì đã làm, tại sao làm vậy, và bằng chứng đã hoàn thành.

---

## Tổng quan

Bài lab W10 xây dựng một platform Kubernetes **production-ready** với đầy đủ các lớp bảo mật, triển khai hoàn toàn qua **GitOps (ArgoCD)**. Chỉ cần 1 lệnh `kubectl apply -f argocd/root.yaml` là toàn bộ hệ thống tự lên.

```
GitHub Repo → ArgoCD (App-of-Apps) → Cluster
                  ↓
    Wave -1: Controllers (Gatekeeper, ESO, Policy Controller)
    Wave  0: Config (RBAC, Templates, Namespaces)
    Wave  1: Rules (Constraints, ExternalSecret, ImagePolicy)
    Wave  2: Workloads (API, Payments app)
```

**Tại sao dùng sync-wave?** Kubernetes không đảm bảo thứ tự apply. Nếu `Constraint` apply trước `ConstraintTemplate`, API server sẽ báo lỗi "no matches for kind" vì CRD chưa tồn tại. Wave đảm bảo controller luôn sẵn sàng trước khi config được apply.

---

## Lab 1 — RBAC + Admission Policy (Gatekeeper)

### Lab 1.1 — Phân quyền 3 vai trò

**Vấn đề cần giải quyết:** Cluster mặc định "ai cũng admin", junior có thể xóa nhầm namespace production lúc 2h sáng.

**Giải pháp:** Tạo 3 role với quyền tối thiểu cần thiết (least-privilege).

| User | Loại | Scope | Được làm gì |
|------|------|-------|-------------|
| `alice` | Role | Chỉ ns `demo` | CRUD deployments, pods, services |
| `bob` | ClusterRole | Toàn cụm | Xem + xóa pods, xem nodes/services |
| `carol` | ClusterRole | Toàn cụm | Chỉ get/list/watch, không sửa gì |

**Tại sao alice dùng `Role` thay vì `ClusterRole`?**
`Role` + `RoleBinding` bó cứng quyền trong namespace `demo`. Nếu dùng `ClusterRole` + `ClusterRoleBinding`, alice có thể thao tác trên **mọi namespace** — phá vỡ nguyên tắc cô lập.

**Files:** `rbac/roles.yaml`, `rbac/rolebindings.yaml`

#### ✅ Checklist nghiệm thu Lab 1.1
- [ ] `kubectl auth can-i create deployments -n demo --as alice` → **yes**
- [ ] `kubectl auth can-i create deployments -n kube-system --as alice` → **no**
- [ ] `kubectl auth can-i get pods -A --as bob` → **yes**
- [ ] `kubectl auth can-i delete nodes --as carol` → **no**

---

### Lab 1.2 — 4 Constraints chặn manifest xấu

**Vấn đề cần giải quyết:** RBAC chỉ kiểm "ai làm gì", không kiểm "manifest có hợp lệ không". Dev được phép tạo Deployment nhưng Deployment đó có thể dùng image lạ, không set limits, chạy root.

**Giải pháp:** OPA Gatekeeper — webhook chặn manifest vi phạm **trước khi lưu vào cluster**.

```
kubectl apply → API Server → [RBAC pass] → [Gatekeeper check] → etcd
                                                    ↓
                                          vi phạm → 403 Forbidden
                                          hợp lệ → lưu vào cluster
```

**4 luật đã viết:**

| # | Tên file | Luật | Lý do |
|---|----------|------|-------|
| 1 | `no-latest-tag.yaml` | Cấm image `:latest` hoặc không có tag | `:latest` không rõ version, build lại là đổi behavior |
| 2 | `require-resource-limit.yaml` | Bắt buộc `resources.limits` | Pod không có limits → ăn hết RAM node → 20 pod khác bị evict |
| 3 | `no-run-as-root.yaml` | Cấm `runAsUser: 0` | Container chạy root = nếu bị exploit, attacker có quyền root trên node |
| 4 | `no-host-network.yaml` | Cấm `hostNetwork: true` | Pod share network với node → thấy được traffic của toàn node |

**Files:** `gatekeeper/policies/*.yaml`

#### ✅ Checklist nghiệm thu Lab 1.2
- [ ] `kubectl apply` Pod image `:latest` → **reject**
- [ ] `kubectl apply` Pod thiếu `resources.limits` → **reject**
- [ ] `kubectl apply` Pod `runAsUser: 0` → **reject**
- [ ] `kubectl apply` Pod `hostNetwork: true` → **reject**
- [ ] `kubectl apply` Pod hợp lệ (version pinned + limits + non-root) → **pass**
- [ ] Platform W9 (api Rollout) vẫn xanh sau khi bật enforce

---

### Lab 1.3 — Custom Policy (require-owner-label)

**Luật tự viết:** Mọi Deployment/Rollout trong ns `demo` và `payments` phải có label `owner`.

**Tại sao cần label owner?** Khi incident xảy ra, cần biết ngay team nào chịu trách nhiệm resource đó. Không có label → mất thêm 30 phút tìm owner lúc production down.

**File:** `gatekeeper/policies/require-owner-label.yaml`

#### ✅ Checklist nghiệm thu Lab 1.3
- [ ] Deploy không có label `owner` → **reject** với message "Thiếu label: owner"
- [ ] Deploy có label `owner: team-platform` → **pass**

---

## Lab 2 — Secrets Rotation + Supply Chain Security

### Lab 2.1 — ESO: Secret Rotation < 60s

**Vấn đề cần giải quyết:**
- DB password commit thẳng vào git → ai clone repo là có password
- Khi rotate, phải restart pod → downtime mỗi lần đổi password

**Giải pháp:** External Secrets Operator (ESO) sync secret từ AWS Secrets Manager vào K8s tự động.

```
AWS Secrets Manager (demo/db/password)
        ↓ ESO poll mỗi 60 giây
K8s Secret "db-secret" (tự động cập nhật)
        ↓ mount dưới dạng volume file
Pod đọc file /etc/secrets/password → thấy password mới ngay
                                    → KHÔNG restart
```

**Tại sao không restart pod?**
- `env var`: giá trị bị "đóng băng" lúc container start, muốn đổi phải restart
- `volume mount`: Kubelet watch Secret, khi Secret thay đổi → tự update file trên disk trong vài giây → app đọc file mới mà không cần restart

**Files:** `eso/secret-store.yaml`, `eso/external-secret.yaml`

> **Lưu ý bảo mật:** AWS credentials tạo bằng `kubectl create secret` — **KHÔNG commit vào git**. Chạy 1 lần thủ công trên cluster.

#### ✅ Checklist nghiệm thu Lab 2.1
- [ ] `kubectl get externalsecret db-creds -n demo` → STATUS: **SecretSynced**
- [ ] Đổi giá trị trên AWS → `kubectl get secret db-secret -o jsonpath='{.data.password}' | base64 -d` → đổi theo trong < 60s
- [ ] `kubectl get pods -n demo` sau khi rotate → **AGE không đổi** (không restart)
- [ ] `git log -p | grep -i password` → **không có secret thật** trong git history

---

### Lab 2.2 — Trivy + Cosign: Supply Chain Security

**Vấn đề cần giải quyết:** Không ai biết image đang chạy trong cluster có CVE không, do ai build, có bị sửa lén không.

**Giải pháp: 3 lớp bảo vệ**

```
[CI] Build image
        ↓
[CI] Trivy scan CVE HIGH/CRITICAL → fail ngay nếu có lỗ hổng
        ↓ (chỉ tiếp tục nếu scan pass)
[CI] Push image lên ghcr.io
        ↓
[CI] Cosign ký image bằng private key → signature lưu trong registry
        ↓
[Cluster] Sigstore Policy Controller verify chữ ký
        → image chưa ký / sai key → reject, không cho chạy
```

**File CI:** `.github/workflows/build-push.yml`

**Tại sao build local trước khi push?**
Trivy chỉ scan được image đang có local. Nếu push trước rồi scan, image xấu đã lên registry — quá muộn. Flow đúng: build → scan → nếu pass mới push.

**Bẫy quan trọng:** Gắn label `policy.sigstore.dev/include=true` cho namespace **TRƯỚC** khi image được ký → Policy Controller chặn luôn tất cả pod → platform sập. Thứ tự đúng: CI ký image trước → sau đó mới enable label trên namespace.

**Files:** `signing/cosign.pub`, `signing/policies/cluster-image-policy.yaml`

#### ✅ Checklist nghiệm thu Lab 2.2
- [ ] Push image có CVE HIGH → **CI đỏ**, image không được push
- [ ] Deploy image chưa ký → **admission reject**
- [ ] Deploy image đã ký từ CI → **pass**, pod chạy bình thường
- [ ] `cosign verify --key signing/cosign.pub ghcr.io/kaphudong/w10-api:<version>` → **verified**

---

## Bài tập lớn (Take-home) — Multi-tenant: Onboard Team Payments

**Vấn đề cần giải quyết:** Onboard team thứ 2 (payments) vào cùng cluster, đảm bảo 2 team cô lập hoàn toàn: không xóa được tài nguyên của nhau, không gọi được qua lại network.

**Yêu cầu quan trọng nhất:** Các guardrail đã đặt từ Lab 1 (Gatekeeper policies) phải **tự động áp** cho team mới — không viết thêm luật.

### 4 thứ đã làm:

#### 1. RBAC least-privilege cho payments-dev

`payments-dev` chỉ được CRUD workload trong ns `payments`, không đọc được secrets, không sửa rolebindings.

**Dùng `Role` + `RoleBinding` (không phải `ClusterRoleBinding`):**

| | Role + RoleBinding | ClusterRoleBinding |
|---|---|---|
| Trong ns `payments` | ✅ có quyền | ✅ có quyền |
| Trong ns `demo` | ❌ không quyền | ✅ có quyền ← nguy hiểm! |

**File:** `tenants/payments/rbac.yaml`

##### ✅ Checklist
- [ ] `kubectl auth can-i create deployments -n payments --as payments-dev` → **yes**
- [ ] `kubectl auth can-i create deployments -n demo --as payments-dev` → **no** ← cô lập
- [ ] `kubectl auth can-i get secrets -n payments --as payments-dev` → **no** ← least-privilege
- [ ] `kubectl auth can-i update rolebindings -n payments --as payments-dev` → **no** ← no escalation

---

#### 2. ResourceQuota + LimitRange

**Tại sao cần cả 2?**
- Chỉ có Quota: pod không khai limits → Quota không biết tính bao nhiêu → pod chạy vô hạn → node OOM
- Chỉ có LimitRange: inject default cho từng pod nhưng không giới hạn **tổng** → 100 pod × 200m = 20 CPU → node sập
- Có cả 2: LimitRange inject default → pod luôn có limits → Quota đếm chính xác → giới hạn tổng ngân sách team

```
Pod không khai limits
    ↓ LimitRange inject: cpu=200m, memory=128Mi
    ↓ ResourceQuota kiểm tổng: (đang dùng + 200m) ≤ 1000m ?
    → OK: pod được tạo
    → Vượt: 403 - exceeded quota
```

**File:** `tenants/payments/quota.yaml`

##### ✅ Checklist
- [ ] Pod xin RAM vượt quota → **từ chối**
- [ ] Pod không khai `limits` → **vẫn chạy** (LimitRange inject default)
- [ ] `kubectl get pod <tên> -o jsonpath='{.spec.containers[0].resources}'` → có limits được inject

---

#### 3. NetworkPolicy cô lập 2 chiều

2 NetworkPolicy riêng cho 2 hướng traffic:

```
default-deny-ingress  → chặn ai GỌI VÀO payments từ ngoài
deny-egress-to-demo   → chặn payments GỌI RA sang ns demo
```

**Tại sao cần 2 policy?**
Chỉ có `default-deny-ingress` → payments vẫn gọi **ra** được sang demo (đây là egress, không bị chặn). Cần policy thứ 2 để chặn cả chiều ra.

**Lưu ý:** Phải start minikube với `--cni=calico`. Flannel mặc định **không enforce** NetworkPolicy.

**File:** `tenants/payments/networkpolicy.yaml`

##### ✅ Checklist
- [ ] `kubectl exec` trong payments → `curl http://api.demo.svc.cluster.local` → **Connection timed out**
- [ ] Traffic trong nội bộ payments → **vẫn đi được**

---

#### 4. Guardrail cũ tự áp — không viết luật mới

**Đây là điểm quan trọng nhất của bài:**

Gatekeeper là **cluster-level admission webhook** — nó không quan tâm resource đến từ team nào, namespace nào. Miễn là Constraint khai `match.namespaces: [demo, payments]`, bất kỳ manifest nào apply vào ns `payments` đều phải qua kiểm tra.

Kết quả: team payments muốn deploy manifest vi phạm (`:latest`, thiếu limits, thiếu label owner) → **bị chặn ngay**, không cần viết thêm 1 dòng policy nào.

**Tương tự với Cosign:** namespace `payments` có label `policy.sigstore.dev/include=true` → Policy Controller verify signature tự động → image chưa ký không chạy được.

**App payments deploy qua GitOps:** `argocd/apps/payments.yaml` (hạ tầng tenant) + `argocd/apps/payments-app.yaml` (workload team B).

##### ✅ Checklist
- [ ] Apply manifest vi phạm trong ns `payments` → **bị Gatekeeper chặn**
- [ ] App payments hợp lệ (đã ký + đủ limits + có owner label) → **chạy xanh**
- [ ] Fresh cluster `kubectl apply -f argocd/root.yaml` → tất cả tự lên xanh

---

## Tóm tắt kiến trúc bảo mật

```
                     ┌─────────────────────────────────────────┐
CI Pipeline          │  1. Trivy scan → fail nếu CVE HIGH/CRIT │
(GitHub Actions)     │  2. Push image (chỉ khi scan pass)      │
                     │  3. Cosign ký image                      │
                     └─────────────────┬───────────────────────┘
                                       │ image đã ký
                     ┌─────────────────▼───────────────────────┐
Admission Layer      │  RBAC: chỉ user có quyền mới apply được │
(API Server)         │  Gatekeeper: chặn manifest vi phạm      │
                     │  Policy Controller: verify chữ ký image │
                     └─────────────────┬───────────────────────┘
                                       │ manifest hợp lệ
                     ┌─────────────────▼───────────────────────┐
Runtime              │  ns demo: team A (api, canary deploy)   │
                     │  ns payments: team B (cô lập hoàn toàn) │
                     │  Secret: ESO rotate tự động < 60s       │
                     │  NetworkPolicy: 2 team không gọi nhau   │
                     └─────────────────────────────────────────┘
```

---

## Câu hỏi hay bị hỏi

**Q: Base64 trong K8s Secret có phải encryption không?**
Không. Base64 chỉ là encoding để tránh ký tự đặc biệt. Ai có quyền đọc Secret là đọc được ngay. ESO + AWS Secrets Manager mới là encryption thật.

**Q: Tại sao không dùng `ClusterRoleBinding` cho payments-dev?**
`ClusterRoleBinding` cho phép payments-dev thao tác trên **toàn cluster**, phá vỡ cô lập tenant. `RoleBinding` bó quyền trong namespace → payments-dev không biết ns `demo` tồn tại từ góc độ RBAC.

**Q: Gatekeeper tự áp cho team mới như thế nào?**
Constraints khai `match.namespaces: [demo, payments]`. Khi team B deploy, API server gọi webhook → Gatekeeper check → không phân biệt team nào. Không cần viết thêm policy.

**Q: Tại sao cần 2 NetworkPolicy riêng?**
`default-deny-ingress` chỉ chặn traffic **vào**. Muốn chặn payments gọi **ra** sang demo, cần `deny-egress-to-demo` riêng. Cô lập 1 chiều không đủ.
