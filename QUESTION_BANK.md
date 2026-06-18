
# Question Bank — W10 Security Lab

Câu hỏi từ cơ bản đến nâng cao về toàn bộ dự án. Dùng để tự ôn tập, phỏng vấn, hoặc kiểm tra hiểu biết trước khi nộp bài.

---

## Level 1 — Cơ bản: Quan sát cluster

**Q1. Cluster này có bao nhiêu namespace? Kể tên tất cả.**

> **A:** 12 namespace:
> `argo-rollouts`, `argocd`, `cosign-system`, `default`, `demo`, `external-secrets`, `gatekeeper-system`, `kube-node-lease`, `kube-public`, `kube-system`, `monitoring`, `payments`
> ```bash
> kubectl get namespaces
> ```

---

**Q2. Có bao nhiêu ArgoCD Application trong cluster? Kể tên và trạng thái.**

> **A:** 15 Application:
> | App | Sync | Health |
> |-----|------|--------|
> | alert | Synced | Healthy |
> | analysis | Synced | Healthy |
> | api | Synced | Healthy |
> | argo-rollouts | Synced | Healthy |
> | common | Synced | Healthy |
> | eso | Synced | Healthy |
> | eso-config | OutOfSync | Healthy |
> | gatekeeper | OutOfSync | Healthy |
> | gatekeeper-policies | OutOfSync | Healthy |
> | kube-prometheus-stack | Synced | Healthy |
> | payments | Synced | Healthy |
> | payments-app | OutOfSync | Healthy |
> | policy-controller | OutOfSync | Healthy |
> | rbac | Synced | Healthy |
> | root | Synced | Healthy |
> ```bash
> kubectl get applications -n argocd
> ```

---

**Q3. Namespace `demo` đang chạy bao nhiêu pod? Tên gì?**

> **A:** 4 pod, tất cả đều là replica của Argo Rollout `api`:
> - `api-76dccfc8cd-d6wxh`
> - `api-76dccfc8cd-m6jkm`
> - `api-76dccfc8cd-vzfbr`
> - `api-76dccfc8cd-w9fdf`
> ```bash
> kubectl get pods -n demo
> ```

---

**Q4. Namespace `monitoring` có bao nhiêu pod? Mỗi pod làm gì?**

> **A:** 6 pod:
> | Pod | Vai trò |
> |-----|---------|
> | `alertmanager-kube-prometheus-stack-alertmanager-0` | Nhận alert từ Prometheus, route sang email |
> | `kube-prometheus-stack-grafana-*` | Dashboard visualization |
> | `kube-prometheus-stack-kube-state-metrics-*` | Export K8s object metrics |
> | `kube-prometheus-stack-operator-*` | Quản lý Prometheus/AlertManager lifecycle |
> | `kube-prometheus-stack-prometheus-node-exporter-*` | Export node-level metrics (CPU/RAM/disk) |
> | `prometheus-kube-prometheus-stack-prometheus-0` | Scrape metrics, evaluate rules, trigger alerts |

---

**Q5. Gatekeeper đang chạy bao nhiêu pod? Ở namespace nào? Mỗi pod làm gì?**

> **A:** 2 pod trong `gatekeeper-system`:
> - `gatekeeper-audit-*` — chạy nền, quét các resource **đã có** trong cluster xem có vi phạm policy không (audit mode)
> - `gatekeeper-controller-manager-*` — webhook server, chặn resource **mới** trước khi vào etcd (enforce mode)

---

**Q6. ArgoCD gồm những component gì? Mỗi component làm gì?**

> **A:** 7 pod trong `argocd`:
> | Pod | Vai trò |
> |-----|---------|
> | `argocd-application-controller` | Reconcile loop: so sánh desired (git) vs actual (cluster) |
> | `argocd-applicationset-controller` | Tạo Application tự động từ template |
> | `argocd-dex-server` | SSO/OIDC authentication provider |
> | `argocd-notifications-controller` | Gửi thông báo (Slack, email, webhook) khi sync |
> | `argocd-redis` | Cache session và app state |
> | `argocd-repo-server` | Clone git repo, render manifests (Helm, Kustomize) |
> | `argocd-server` | API server + Web UI |

---

**Q7. File nào là entrypoint để deploy toàn bộ platform?**

> **A:** `argocd/root.yaml` — đây là Root Application theo pattern App-of-Apps. Apply file này, ArgoCD tự phát hiện tất cả file trong `argocd/apps/` và tạo 15 child Application.
> ```bash
> kubectl apply -f argocd/root.yaml
> ```

---

**Q8. Source code Flask API nằm ở đâu? Image được push lên registry nào?**

> **A:**
> - Source code: `src/api/app.py`
> - Dockerfile: `src/api/Dockerfile`
> - Registry: `ghcr.io/kaphudong/w10-api` (GitHub Container Registry)
> - Tag format: `<semver>` (vd `0.1.0`), `latest`, `v0.1.0-<short-sha>`

---

## Level 2 — Trung bình: Hiểu cấu hình

**Q9. Sync wave trong dự án này là bao nhiêu? Tại sao cần sync wave?**

> **A:** Có 4 wave: `-1`, `0`, `1`, `2`.
>
> Cần sync wave vì có **dependency**: ESO controller phải có trước khi apply `SecretStore` (vì SecretStore dùng CRD của ESO). Nếu apply cùng lúc → "no matches for kind SecretStore". Wave đảm bảo infra (wave -1) → config (wave 0) → rules (wave 1) → workload (wave 2).

---

**Q10. Tại sao `ConstraintTemplate` và `Constraint` nằm trong cùng 1 file nhưng dùng annotation wave khác nhau?**

> **A:** Trong cùng 1 ArgoCD App (`gatekeeper-policies`), resource có `argocd.argoproj.io/sync-wave: "0"` apply trước resource có `sync-wave: "1"`. ConstraintTemplate (wave 0) apply → Gatekeeper sinh CRD mới. Sau đó Constraint (wave 1) mới apply, lúc này CRD đã tồn tại → không lỗi.
>
> Tách 2 App riêng sẽ gây race condition (App B sync trước khi App A xong). Gộp 1 App + wave per-resource giải quyết gọn hơn.

---

**Q11. ESO đang sync secret nào? Từ đâu? Vào K8s Secret tên gì? Refresh bao lâu?**

> **A:**
> - ExternalSecret: `db-creds` (ns `demo`)
> - Nguồn: AWS Secrets Manager, region `ap-southeast-1`
> - Keys: `demo/db/password` và `demo/db/username`
> - K8s Secret tạo ra: `db-secret` (ns `demo`)
> - RefreshInterval: `1m` (poll AWS mỗi 60 giây)
> ```bash
> kubectl get externalsecret db-creds -n demo
> kubectl get secret db-secret -n demo
> ```

---

**Q12. Tại sao ESO webhook bị disable? Có ảnh hưởng gì không?**

> **A:** Webhook disabled qua Helm values (`webhook.create: false`, `certController.create: false`) để tránh race condition: khi `eso-config` app sync (wave 1), ESO controller đã ready nhưng webhook pod chưa kịp bind port 443 → `connection refused`. Webhook chỉ validate admission (không bắt buộc cho chức năng sync secret) nên disable không ảnh hưởng đến ESO hoạt động.

---

**Q13. CI pipeline có những bước bảo mật nào? Thứ tự ra sao?**

> **A:** 3 bước bảo mật theo thứ tự:
> 1. **Build local** (`push: false, load: true`) — image chỉ trong máy CI, chưa lên registry
> 2. **Trivy scan** — quét CVE HIGH/CRITICAL, `exit-code: 1` nếu tìm thấy → pipeline dừng, image không push
> 3. **Push + Cosign sign** — chỉ sau khi scan pass, push image lên GHCR rồi ký bằng private key
>
> Thứ tự này đảm bảo image xấu không bao giờ lên registry.

---

**Q14. Cosign signature được lưu ở đâu? Làm sao verify?**

> **A:** Signature được lưu dưới dạng **OCI artifact** trong cùng registry (`ghcr.io/kaphudong/w10-api`), được tag bằng digest của image gốc (format: `sha256-<digest>.sig`). Không phải file riêng.
> ```bash
> cosign verify --key signing/cosign.pub ghcr.io/kaphudong/w10-api:0.1.0
> ```

---

**Q15. Namespace `demo` và `payments` có label gì đặc biệt? Label đó làm gì?**

> **A:** Cả 2 namespace đều có:
> ```yaml
> policy.sigstore.dev/include: "true"
> ```
> Label này báo cho Sigstore **Policy Controller** biết cần enforce `ClusterImagePolicy` trong namespace đó. Mọi Pod mới tạo trong namespace có label này sẽ bị kiểm tra signature trước khi schedule.

---

**Q16. RBAC của `alice` khác `bob` như thế nào? File nào định nghĩa?**

> **A:** Defined trong `rbac/roles.yaml` và `rbac/rolebindings.yaml`:
>
> | | alice | bob |
> |---|---|---|
> | Kind | `Role` (namespaced) | `ClusterRole` (cluster-wide) |
> | Binding | `RoleBinding` trong ns `demo` | `ClusterRoleBinding` |
> | Scope | Chỉ ns `demo` | Toàn cluster |
> | Quyền | CRUD deployments, pods, services | Get/list/watch/delete pods, get nodes |
> | Tạo deployment | ✅ trong demo | ❌ không thể tạo |

---

**Q17. Canary deployment dùng bao nhiêu replica? Các bước canary là gì?**

> **A:** 4 replicas (`spec.replicas: 4`) với canary strategy:
> 1. `setWeight: 10` → 1 pod canary / 3 pod stable
> 2. `pause: {duration: 2m}`
> 3. AnalysisRun bắt đầu (query Prometheus success rate ≥ 95%)
> 4. `setWeight: 50` → 2 pod canary / 2 pod stable
> 5. `pause: {duration: 2m}`
> 6. `setWeight: 100` → 4 pod canary, stable scale down
>
> Defined trong `app-api/rollout.yaml`.

---

**Q18. `payments` namespace có ResourceQuota và LimitRange. Số liệu cụ thể là bao nhiêu?**

> **A:** Defined trong `tenants/payments/quota.yaml`:
>
> **ResourceQuota `payments-quota`:**
> - CPU request: 500m / limit: 1000m
> - Memory request: 512Mi / limit: 1Gi
> - Max pods: 10, services: 5, PVCs: 3
>
> **LimitRange `payments-limitrange`:**
> - Default limit per container: 200m CPU, 128Mi memory
> - Default request per container: 100m CPU, 64Mi memory
> - Max per container: 500m CPU, 512Mi memory

---

## Level 3 — Khó: Hiểu sâu + Reasoning

**Q19. Gatekeeper có mấy constraint? Mỗi cái scope namespace nào? Tại sao `no-host-network` không giới hạn namespace?**

> **A:** 5 constraints:
> | Constraint | Namespace scope | Kind |
> |-----------|----------------|------|
> | `no-latest-tag` | demo, payments | Pod |
> | `require-resource-limit` | demo, payments | Pod |
> | `no-run-as-root` | demo, payments | Pod |
> | `no-host-network` | **toàn cụm** | Pod |
> | `require-owner-label` | demo, payments | Deployment, Rollout |
>
> `no-host-network` không giới hạn namespace vì `hostNetwork: true` cho phép pod truy cập trực tiếp network interface của node — đây là risk ở **node level**, không phải namespace level. Một pod trong `monitoring` hoặc `kube-system` cũng không nên dùng hostNetwork trừ khi cố ý (như `node-exporter`).

---

**Q20. Tại sao payments-app bị OutOfSync mà vẫn Healthy?**

> **A:** OutOfSync nghĩa là desired state (git) khác actual state (cluster) — thường do image tag trong `apps/payments/deployment.yaml` (`0.1.0`) chưa phải phiên bản mới nhất, hoặc có field diff nhỏ. Healthy nghĩa là pod đang chạy bình thường (`Running`, readiness probe pass). Hai trạng thái này độc lập: app có thể chạy tốt nhưng git manifest đã thay đổi chưa sync.

---

**Q21. Tại sao không dùng `ClusterRoleBinding` cho `payments-dev` dù tiện hơn?**

> **A:** `ClusterRoleBinding` cho phép `payments-dev` thao tác trên **mọi namespace** trong cluster — kể cả `demo`, `kube-system`, `monitoring`. Điều này phá vỡ mục tiêu multi-tenant: team payments có thể đọc/sửa resource của team demo.
>
> `RoleBinding` trong namespace `payments` bó cứng scope: API server chỉ grant permission khi request namespace = `payments`. Đây là nguyên tắc **least privilege** — chỉ cấp đúng quyền cần thiết, không hơn.

---

**Q22. Nếu một pod trong `payments` cố gọi `http://api.demo.svc.cluster.local`, điều gì xảy ra ở tầng nào?**

> **A:** Có 2 tầng kiểm soát:
>
> 1. **DNS resolve thành công** — CoreDNS vẫn resolve `api.demo.svc.cluster.local` ra IP (vì DNS query dùng port 53 UDP, được phép trong NetworkPolicy egress)
>
> 2. **TCP connection bị drop** — Calico CNI đọc NetworkPolicy `deny-egress-to-demo`: egress đến namespace `demo` không có rule allow → packet bị **DROP ở kernel level** (iptables/eBPF). Kết quả: `curl: (28) Connection timed out`
>
> NetworkPolicy hoạt động ở **layer 3/4** (IP + port), không phải layer 7. Nó không inspect HTTP header mà drop packet dựa trên source/destination IP và port.

---

**Q23. Nếu dev push image `nginx:latest` vào ns `payments`, bao nhiêu Gatekeeper constraint sẽ vi phạm?**

> **A:** Tùy manifest, tối thiểu **3 constraint** vi phạm:
> 1. `no-latest-tag` — image dùng `:latest`
> 2. `require-resource-limit` — nếu không khai `resources.limits`
> 3. `require-owner-label` — nếu Deployment thiếu label `owner`
>
> Cộng thêm nếu set `hostNetwork: true` → `no-host-network` (4 vi phạm), hoặc `runAsUser: 0` → `no-run-as-root` (5 vi phạm).
>
> Tất cả reject trong **một response duy nhất** — Gatekeeper gom tất cả violation messages vào 1 HTTP 403.

---

**Q24. Tại sao dùng `ignore-unfixed: true` trong Trivy? Rủi ro là gì?**

> **A:** `ignore-unfixed: true` bỏ qua CVE chưa có patch từ vendor. Nếu không set flag này, CI sẽ fail vĩnh viễn vì có CVE trong base image mà không làm gì được (vendor chưa release fix). Điều này block toàn bộ deployment pipeline.
>
> **Rủi ro:** Bỏ qua CVE dù HIGH/CRITICAL khi chưa có patch. Mitigation đúng là: ghi **exception ADR** (Architecture Decision Record) có thời hạn (vd 30 ngày), theo dõi CVE tracker của vendor, update ngay khi có patch.

---

**Q25. Flow đầy đủ khi dev đổi `ERROR_RATE` từ `0` lên `0.15` và push git?**

> **A:** End-to-end flow:
>
> ```
> git push (sửa app-api/rollout.yaml ERROR_RATE: "0.15")
>   → ArgoCD detect diff trong 3 phút
>   → Sync rollout.yaml → Argo Rollouts controller
>   → Canary step 1: 1/4 pod chạy version mới (ERROR_RATE=0.15)
>   → Pause 2m
>   → AnalysisRun query Prometheus:
>       success_rate = (total - 500s) / total
>       = (requests - 15%) / requests = 85%
>       85% < 95% threshold → FAIL
>   → Argo Rollouts tự rollback: scale canary xuống 0
>   → 4 pod quay về image cũ (ERROR_RATE=0)
>   → Prometheus metrics bình thường lại
>   → PrometheusRule check: error rate < 5% → alert resolve
>   → AlertManager gửi email "RESOLVED"
> ```

---

**Q26. Điều gì xảy ra nếu apply `argocd/root.yaml` lên cluster đã có platform đang chạy?**

> **A:** **Idempotent — không có gì thay đổi** nếu git repo không đổi. ArgoCD reconcile loop so sánh desired state (git) với actual state (cluster):
> - Nếu identical → `Synced`, không apply gì
> - Nếu có diff → apply diff (chỉ resource thay đổi, không recreate toàn bộ)
> - `automated.prune: true` → resource không còn trong git sẽ bị xóa khỏi cluster
> - `automated.selfHeal: true` → ai đó sửa tay trên cluster → ArgoCD tự revert về git
>
> Đây là nguyên tắc **GitOps**: git là source of truth duy nhất.

---

**Q27. Tại sao ESO dùng `creationPolicy: Owner` trong ExternalSecret?**

> **A:** `creationPolicy: Owner` nghĩa là ESO **sở hữu** lifecycle của K8s Secret `db-secret`:
> - ESO tạo Secret khi ExternalSecret sync lần đầu
> - Nếu xóa ExternalSecret → ESO tự xóa Secret đi kèm (không để lại orphan)
> - Nếu ai xóa Secret thủ công → ESO recreate ngay trong lần sync tiếp theo
>
> Nếu dùng `creationPolicy: Merge` — ESO chỉ cập nhật Secret đã có sẵn (không tạo mới, không xóa).

---

**Q28. Sigstore Policy Controller enforce ở tầng nào? Tại sao không enforce trong CI?**

> **A:** Policy Controller enforce ở **admission webhook** — tầng API server, ngay trước khi Pod vào etcd. Đây là **cluster-level enforcement**: dù ai apply manifest (kubectl tay, ArgoCD, Helm), đều phải qua webhook này.
>
> Enforce trong CI (chỉ verify trước khi push) thì không đủ vì:
> 1. Dev có thể bypass CI và push thẳng bằng kubectl
> 2. Image từ registry khác (không qua CI) vẫn chạy được
> 3. Không có gì ngăn người dùng deploy image cũ chưa ký
>
> Admission webhook là **hard enforcement** — không ai bypass được kể cả admin (trừ khi xóa webhook).

---

**Q29. Kể toàn bộ file YAML trong `tenants/payments/`. Thứ tự sync-wave của chúng là gì?**

> **A:** 4 file:
> | File | Resource | Wave |
> |------|----------|------|
> | `namespace.yaml` | Namespace `payments` | `-1` |
> | `rbac.yaml` | Role `payments-developer` + RoleBinding | `0` |
> | `quota.yaml` | ResourceQuota + LimitRange | `0` |
> | `networkpolicy.yaml` | 2 NetworkPolicy | `0` |
>
> Namespace phải có trước (wave -1) thì mới apply được resource vào namespace đó (wave 0).

---

**Q30. Dự án này nếu deploy lên fresh cluster, mất bao lâu để tất cả app Healthy? Bottleneck ở đâu?**

> **A:** Ước tính ~10-15 phút. Bottleneck theo thứ tự:
>
> 1. **Gatekeeper Helm install** (~2-3 phút) — pull image, deploy controller, register webhook
> 2. **kube-prometheus-stack** (~3-5 phút) — stack lớn nhất, nhiều CRD, nhiều component
> 3. **Gatekeeper policies** — ConstraintTemplate → CRD sinh ra (~5-10s sau khi controller ready)
> 4. **ESO + eso-config** (~1-2 phút) — pull image, start controller, sync ExternalSecret
> 5. **api Rollout** — canary analysis mất 4+ phút (2 lần pause 2m)
>
> `kube-prometheus-stack` thường là bottleneck nhất vì size lớn (Prometheus image ~200MB+).

---

## Bonus — Câu hỏi thực hành

**B1.** Chạy lệnh nào để xem tất cả vi phạm constraint hiện tại trong cluster (audit mode)?
```bash
kubectl get k8snolatesttag,k8srequireresourcelimit,k8snorunasroot,k8snohostnetwork,k8srequireownerlabel -A
```

**B2.** Làm sao xem logs của ESO controller để debug sync error?
```bash
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets -f
```

**B3.** Lệnh nào kiểm tra nhanh tất cả RBAC permissions cho `payments-dev`?
```bash
kubectl auth can-i --list --as payments-dev -n payments
kubectl auth can-i --list --as payments-dev -n demo
```

**B4.** Làm sao force ESO sync ngay lập tức mà không chờ refreshInterval?
```bash
kubectl annotate externalsecret db-creds -n demo \
  force-sync=$(date +%s) --overwrite
```

**B5.** Kiểm tra Cosign signature của image hiện tại trong rollout:
```bash
IMAGE=$(kubectl get rollout api -n demo -o jsonpath='{.spec.template.spec.containers[0].image}')
cosign verify --key signing/cosign.pub $IMAGE
```
