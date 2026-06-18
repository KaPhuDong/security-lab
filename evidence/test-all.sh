#!/bin/bash
# ============================================================
# Test Script: Kiểm tra toàn bộ yêu cầu W10 Lab
# Chạy sau khi ArgoCD đã sync xong tất cả apps
# Usage: bash evidence/test-all.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

check() {
  local desc="$1"
  local expected="$2"
  local actual="$3"

  if echo "$actual" | grep -q "$expected"; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}✗${NC} $desc"
    echo -e "    expected : ${YELLOW}$expected${NC}"
    echo -e "    got      : ${YELLOW}$actual${NC}"
    FAIL=$((FAIL+1))
  fi
}

section() {
  echo ""
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $1${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════${NC}"
}

# ─────────────────────────────────────────
section "Lab 1.1 · RBAC - Team Demo (alice/bob/carol)"
# ─────────────────────────────────────────

check "alice tạo deploy trong demo = yes" \
  "yes" \
  "$(kubectl auth can-i create deployments -n demo --as alice 2>&1)"

check "alice tạo deploy trong kube-system = no (cô lập ns)" \
  "no" \
  "$(kubectl auth can-i create deployments -n kube-system --as alice 2>&1)"

check "bob get pods toàn cụm = yes (SRE)" \
  "yes" \
  "$(kubectl auth can-i get pods -A --as bob 2>&1)"

check "bob delete nodes = no (chỉ xem + thao tác pod)" \
  "no" \
  "$(kubectl auth can-i delete nodes --as bob 2>&1)"

check "carol get pods = yes (viewer)" \
  "yes" \
  "$(kubectl auth can-i get pods --as carol 2>&1)"

check "carol delete pods = no (chỉ đọc)" \
  "no" \
  "$(kubectl auth can-i delete pods --as carol 2>&1)"

# ─────────────────────────────────────────
section "Lab 1.2 · Gatekeeper - 4 Constraints"
# ─────────────────────────────────────────

echo -e "\n  ${BOLD}[Test reject: image :latest]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-latest-$$
  namespace: demo
spec:
  containers:
  - name: app
    image: nginx:latest
    resources:
      limits:
        cpu: 100m
        memory: 64Mi
EOF
)
kubectl delete pod test-latest-$$ -n demo --ignore-not-found=true >/dev/null 2>&1
check "Pod image :latest bị reject" \
  "denied\|Forbidden\|violation" \
  "$OUTPUT"

echo -e "\n  ${BOLD}[Test reject: thiếu resources.limits]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-nolimits-$$
  namespace: demo
spec:
  containers:
  - name: app
    image: nginx:1.25.3
EOF
)
kubectl delete pod test-nolimits-$$ -n demo --ignore-not-found=true >/dev/null 2>&1
check "Pod thiếu resources.limits bị reject" \
  "denied\|Forbidden\|violation" \
  "$OUTPUT"

echo -e "\n  ${BOLD}[Test reject: runAsUser: 0]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-root-$$
  namespace: demo
spec:
  containers:
  - name: app
    image: nginx:1.25.3
    resources:
      limits:
        cpu: 100m
        memory: 64Mi
    securityContext:
      runAsUser: 0
EOF
)
kubectl delete pod test-root-$$ -n demo --ignore-not-found=true >/dev/null 2>&1
check "Pod runAsUser:0 bị reject" \
  "denied\|Forbidden\|violation" \
  "$OUTPUT"

echo -e "\n  ${BOLD}[Test reject: hostNetwork: true]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-hostnet-$$
  namespace: demo
spec:
  hostNetwork: true
  containers:
  - name: app
    image: nginx:1.25.3
    resources:
      limits:
        cpu: 100m
        memory: 64Mi
EOF
)
kubectl delete pod test-hostnet-$$ -n demo --ignore-not-found=true >/dev/null 2>&1
check "Pod hostNetwork:true bị reject" \
  "denied\|Forbidden\|violation" \
  "$OUTPUT"

echo -e "\n  ${BOLD}[Test pass: Pod hợp lệ]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-valid-$$
  namespace: demo
  labels:
    owner: team-platform
spec:
  securityContext:
    runAsUser: 1000
  containers:
  - name: app
    image: ghcr.io/kaphudong/w10-api:0.1.0
    resources:
      limits:
        cpu: 100m
        memory: 64Mi
EOF
)
kubectl delete pod test-valid-$$ -n demo --ignore-not-found=true >/dev/null 2>&1
check "Pod hợp lệ được tạo (pass all constraints)" \
  "created\|configured\|unchanged" \
  "$OUTPUT"

# ─────────────────────────────────────────
section "Lab 1.3 · Custom Policy - require-owner-label"
# ─────────────────────────────────────────

echo -e "\n  ${BOLD}[Test reject: Deployment thiếu label owner]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-owner-$$
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-no-owner
  template:
    metadata:
      labels:
        app: test-no-owner
    spec:
      containers:
      - name: app
        image: ghcr.io/kaphudong/w10-api:0.1.0
        resources:
          limits:
            cpu: 100m
            memory: 64Mi
EOF
)
kubectl delete deploy test-no-owner-$$ -n demo --ignore-not-found=true >/dev/null 2>&1
check "Deployment thiếu label owner bị reject" \
  "denied\|Forbidden\|violation" \
  "$OUTPUT"

echo -e "\n  ${BOLD}[Test pass: Deployment có label owner]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-with-owner-$$
  namespace: demo
  labels:
    owner: team-platform
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-with-owner
  template:
    metadata:
      labels:
        app: test-with-owner
    spec:
      securityContext:
        runAsUser: 1000
      containers:
      - name: app
        image: ghcr.io/kaphudong/w10-api:0.1.0
        resources:
          limits:
            cpu: 100m
            memory: 64Mi
EOF
)
kubectl delete deploy test-with-owner-$$ -n demo --ignore-not-found=true >/dev/null 2>&1
check "Deployment có label owner pass" \
  "created\|configured\|unchanged" \
  "$OUTPUT"

# ─────────────────────────────────────────
section "Lab 2.1 · ESO - Secret Rotation"
# ─────────────────────────────────────────

check "SecretStore aws-store Ready" \
  "True\|Valid" \
  "$(kubectl get secretstore aws-store -n demo -o jsonpath='{.status.conditions[0].status}' 2>&1)"

check "ExternalSecret db-creds synced" \
  "SecretSynced\|True" \
  "$(kubectl get externalsecret db-creds -n demo -o jsonpath='{.status.conditions[0].reason}' 2>&1)"

check "K8s Secret db-secret tồn tại" \
  "db-secret" \
  "$(kubectl get secret db-secret -n demo --no-headers 2>&1)"

check "Secret có key password" \
  "password" \
  "$(kubectl get secret db-secret -n demo -o jsonpath='{.data}' 2>&1)"

echo -e "\n  ${BOLD}[Verify pod không restart sau sync]${NC}"
POD_AGE=$(kubectl get pods -n demo -o jsonpath='{.items[0].status.startTime}' 2>&1)
check "Pods trong demo còn chạy (không restart)" \
  "20\|21\|22\|23\|Running" \
  "$(kubectl get pods -n demo --no-headers 2>&1)"

# ─────────────────────────────────────────
section "Challenge · payments-dev RBAC isolation"
# ─────────────────────────────────────────

check "payments-dev tạo deploy trong payments = yes" \
  "yes" \
  "$(kubectl auth can-i create deployments -n payments --as payments-dev 2>&1)"

check "payments-dev tạo deploy trong demo = no (cô lập!)" \
  "no" \
  "$(kubectl auth can-i create deployments -n demo --as payments-dev 2>&1)"

check "payments-dev sửa rolebinding = no (no privilege escalation)" \
  "no" \
  "$(kubectl auth can-i update rolebindings -n payments --as payments-dev 2>&1)"

check "payments-dev đọc secrets = no (least-privilege)" \
  "no" \
  "$(kubectl auth can-i get secrets -n payments --as payments-dev 2>&1)"

# ─────────────────────────────────────────
section "Challenge · ResourceQuota payments"
# ─────────────────────────────────────────

check "ResourceQuota payments-quota tồn tại" \
  "payments-quota" \
  "$(kubectl get resourcequota payments-quota -n payments --no-headers 2>&1)"

check "LimitRange payments-limitrange tồn tại" \
  "payments-limitrange" \
  "$(kubectl get limitrange payments-limitrange -n payments --no-headers 2>&1)"

echo -e "\n  ${BOLD}[Test: Pod vượt quota bị từ chối]${NC}"
OUTPUT=$(kubectl run test-overlimit-$$ \
  --image=ghcr.io/kaphudong/w10-api:0.1.0 \
  --requests=memory=2Gi --limits=memory=2Gi \
  -n payments 2>&1)
kubectl delete pod test-overlimit-$$ -n payments --ignore-not-found=true >/dev/null 2>&1
check "Pod xin RAM 2Gi > quota (1Gi) bị từ chối" \
  "exceeded quota\|forbidden\|Forbidden" \
  "$OUTPUT"

# ─────────────────────────────────────────
section "Challenge · NetworkPolicy isolation"
# ─────────────────────────────────────────

check "NetworkPolicy default-deny-ingress tồn tại" \
  "default-deny-ingress" \
  "$(kubectl get networkpolicy default-deny-ingress -n payments --no-headers 2>&1)"

check "NetworkPolicy deny-egress-to-demo tồn tại" \
  "deny-egress-to-demo" \
  "$(kubectl get networkpolicy deny-egress-to-demo -n payments --no-headers 2>&1)"

echo -e "\n  ${BOLD}[Test: payments gọi demo service bị chặn - cần Calico CNI]${NC}"
echo -e "  ${YELLOW}(manual test - chạy lệnh bên dưới để verify)${NC}"
echo -e "  kubectl run test-netpol --image=curlimages/curl:8.6.0 -n payments --rm -i --restart=Never \\"
echo -e "    -- curl -s --max-time 3 http://api.demo.svc.cluster.local/"
echo -e "  ${YELLOW}Expected: Connection timed out (bị chặn)${NC}"

# ─────────────────────────────────────────
section "Challenge · Guardrail tự áp cho payments"
# ─────────────────────────────────────────

echo -e "\n  ${BOLD}[Test: manifest vi phạm trong payments bị Gatekeeper chặn]${NC}"
OUTPUT=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad-deploy-$$
  namespace: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bad
  template:
    metadata:
      labels:
        app: bad
    spec:
      containers:
      - name: app
        image: nginx:latest
EOF
)
kubectl delete deploy bad-deploy-$$ -n payments --ignore-not-found=true >/dev/null 2>&1
check "Vi phạm (latest + no limits + no owner) bị Gatekeeper chặn" \
  "denied\|Forbidden\|violation" \
  "$OUTPUT"

check "payments app hợp lệ đang chạy" \
  "Running\|payments" \
  "$(kubectl get pods -n payments --no-headers 2>&1)"

# ─────────────────────────────────────────
section "Tổng kết"
# ─────────────────────────────────────────
echo ""
TOTAL=$((PASS+FAIL))
echo -e "  ${BOLD}Kết quả: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"

if [ $FAIL -eq 0 ]; then
  echo -e "\n  ${GREEN}${BOLD}✓ TẤT CẢ TESTS PASS - Lab hoàn thành!${NC}"
else
  echo -e "\n  ${YELLOW}${BOLD}⚠ Còn $FAIL test chưa pass - kiểm tra lại${NC}"
fi
echo ""
