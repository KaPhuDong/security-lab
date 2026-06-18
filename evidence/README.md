# Evidence - Take-home Challenge: Multi-tenant Isolation

## Chứng minh 4 yêu cầu

### 1. RBAC cô lập (payments-dev)

```bash
# payments-dev tạo deploy trong payments = yes
kubectl auth can-i create deployments -n payments --as payments-dev
# → yes

# payments-dev tạo deploy trong demo = no (cô lập!)
kubectl auth can-i create deployments -n demo --as payments-dev
# → no

# payments-dev sửa rolebinding = no (không leo thang quyền)
kubectl auth can-i update rolebindings -n payments --as payments-dev
# → no

# payments-dev đọc secrets = no (least-privilege)
kubectl auth can-i get secrets -n payments --as payments-dev
# → no
```

### 2. ResourceQuota + LimitRange

```bash
# Xem quota hiện tại
kubectl describe resourcequota payments-quota -n payments

# Test: pod không khai báo limits vẫn chạy (LimitRange inject default)
kubectl run test-nolimits --image=ghcr.io/kaphudong/w10-api:0.1.0 -n payments
kubectl get pod test-nolimits -n payments -o jsonpath='{.spec.containers[0].resources}'
# → có limits được inject bởi LimitRange

# Test: pod xin RAM vượt quota → bị từ chối
kubectl run test-overlimit --image=ghcr.io/kaphudong/w10-api:0.1.0 \
  --requests=memory=2Gi --limits=memory=2Gi -n payments
# → Error: exceeded quota
```

### 3. NetworkPolicy cô lập

```bash
# Test: payments gọi service demo → bị chặn
kubectl run test-netpol --image=curlimages/curl:8.6.0 -n payments --rm -i \
  --restart=Never -- curl -s --max-time 3 http://api.demo.svc.cluster.local/
# → curl: (28) Connection timed out (bị chặn bởi NetworkPolicy)
```

### 4. Guardrail cũ tự áp cho team B

```bash
# Test: deploy manifest vi phạm vào ns payments → bị Gatekeeper chặn
kubectl apply -f evidence/test-violation.yaml
# → Error from server (Forbidden):
#   [no-latest-tag] Container 'app' dùng image tag :latest
#   [require-owner-label] Workload 'bad-payments-deploy' thiếu label: owner
#   [require-resource-limit] Container 'app' thiếu resources.limits.cpu

# Test: deploy payments app hợp lệ → pass
kubectl get pods -n payments
# → payments-xxx Running
```

## Giải thích

### 1. Tại sao guardrail cũ tự áp cho team B mà không cần viết luật mới?

Gatekeeper Constraints (Lab 1) được định nghĩa với `match.namespaces: [demo]` hoặc không giới hạn namespace. Khi team B deploy vào ns `payments`, Gatekeeper webhook đã được cài ở **cluster level** — nó intercept **mọi** admission request trong cluster, không chỉ ns demo.

Constraints như `require-owner-label`, `require-resource-limit`, `no-latest-tag` match theo **kind** (Deployment, Pod) chứ không theo namespace → tự động áp cho mọi namespace mới mà không cần viết lại policy.

### 2. Role/RoleBinding khác ClusterRoleBinding ra sao để giữ cô lập?

| | Role + RoleBinding | ClusterRoleBinding |
|---|---|---|
| Phạm vi | 1 namespace | Toàn cluster |
| payments-dev tạo deploy trong `payments` | ✅ yes | ✅ yes |
| payments-dev tạo deploy trong `demo` | ❌ no | ✅ yes (nguy hiểm!) |
| Cô lập tenant | ✅ đảm bảo | ❌ không đảm bảo |

`payments-dev` chỉ có `RoleBinding` trong ns `payments` → API server chỉ cấp quyền trong scope đó. Dùng `ClusterRoleBinding` sẽ cho phép `payments-dev` thao tác trên **mọi namespace** — vi phạm nguyên tắc least-privilege và phá vỡ cô lập tenant.
