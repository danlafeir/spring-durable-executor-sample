#!/usr/bin/env bash
# Full chaos test: build → deploy → fresh PVCs → load + chaos → validate → report.
#
# Designed to be run by a human or an automated agent with no interactive steps.
#
# Usage:
#   ./run-chaos-test.sh [options]
#
# Options:
#   --skip-build          Use the already-built order-service:latest image
#   --skip-deploy         Skip kubectl apply / rollout restart (use running cluster)
#   --load-rate SECS      Seconds between order submissions (default: 0.5)
#   --chaos-interval SECS Seconds between pod kills (default: 8)
#   --chaos-pg-every N    Kill postgres every Nth app kill (default: 5)
#   --duration SECS       Seconds to run load+chaos (default: 180)
#   --validate-timeout S  Seconds for validate.sh to wait (default: 600)
#   --namespace NS        Kubernetes namespace (default: default)
#   --output-dir DIR      Where to write results (default: output/run-TIMESTAMP)
#
# Exit codes:
#   0  validate.sh passed (all orders FULFILLED, durable stores empty)
#   1  validate.sh timed out or orders remain incomplete
#   2  deployment or pre-flight failure
#
# What the script checks for (written to summary.md in the output directory):
#   - All orders reach FULFILLED with an empty durable store (validate.sh exit 0)
#   - DLQ entries present (expected when postgres is killed with an app pod)
#   - No liveness-probe-triggered pod restarts (indicates concurrent recovery is working)

set -uo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
SKIP_BUILD=false
SKIP_DEPLOY=false
LOAD_RATE=0.5
CHAOS_INTERVAL=8
CHAOS_PG_EVERY=5
DURATION=180
VALIDATE_TIMEOUT=600
NAMESPACE=default
OUTPUT_DIR=""

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)        SKIP_BUILD=true ;;
        --skip-deploy)       SKIP_DEPLOY=true ;;
        --load-rate)         LOAD_RATE="$2"; shift ;;
        --chaos-interval)    CHAOS_INTERVAL="$2"; shift ;;
        --chaos-pg-every)    CHAOS_PG_EVERY="$2"; shift ;;
        --duration)          DURATION="$2"; shift ;;
        --validate-timeout)  VALIDATE_TIMEOUT="$2"; shift ;;
        --namespace)         NAMESPACE="$2"; shift ;;
        --output-dir)        OUTPUT_DIR="$2"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/output/run-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"

LOG="$OUTPUT_DIR/run.log"
exec > >(tee -a "$LOG") 2>&1

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'

step() { echo -e "\n${CYAN}── $* ──${RESET}"; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
fail() { echo -e "${RED}✗ $*${RESET}"; }

# curl with automatic retry until the service responds (port-forward may be reconnecting)
curl_retry() {
    local url="$1"; shift
    local max=30
    for i in $(seq 1 $max); do
        local out
        if out=$(curl -s --max-time 5 "$@" "$url" 2>/dev/null); then
            echo "$out"
            return 0
        fi
        sleep 2
    done
    fail "curl $url did not succeed after ${max} attempts"
    return 1
}

# ── pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"
for cmd in kubectl docker curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { fail "$cmd not found"; exit 2; }
done
kubectl cluster-info >/dev/null 2>&1 || { fail "kubectl cannot reach cluster"; exit 2; }
ok "cluster reachable"

# ── build ─────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
    step "Building Docker image"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    docker build --no-cache \
        -f "$SCRIPT_DIR/Dockerfile" \
        -t order-service:latest \
        "$PARENT_DIR" 2>&1 | tail -5
    ok "image built: order-service:latest"
else
    ok "skipping build (--skip-build)"
fi

# ── deploy ────────────────────────────────────────────────────────────────────
if [[ "$SKIP_DEPLOY" == "false" ]]; then
    step "Deploying to Kubernetes (namespace: $NAMESPACE)"
    kubectl apply -n "$NAMESPACE" \
        -f "$SCRIPT_DIR/k8s/postgres.yaml" \
        -f "$SCRIPT_DIR/k8s/app.yaml" 2>&1
    kubectl rollout restart -n "$NAMESPACE" statefulset/order-service
    kubectl rollout status -n "$NAMESPACE" statefulset/postgres --timeout=120s
    kubectl rollout status -n "$NAMESPACE" statefulset/order-service --timeout=300s
    ok "all pods ready"
else
    ok "skipping deploy (--skip-deploy)"
fi

# ── fresh PVCs ────────────────────────────────────────────────────────────────
# Scale the StatefulSet to 0, delete all durable-store PVCs so every run
# starts from a clean slate, then scale back up.  This prevents leftover
# durable records or DLQ files from a previous run from polluting results.
step "Resetting PVCs for a clean durable store"
REPLICAS=$(kubectl get statefulset -n "$NAMESPACE" order-service \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 3)

kubectl scale -n "$NAMESPACE" statefulset/order-service --replicas=0 2>&1
kubectl wait -n "$NAMESPACE" pod \
    -l app=order-service --for=delete --timeout=90s 2>/dev/null || true

# Patch away the pvc-protection finalizer before deleting so we don't
# have to wait for the protection controller to release it.
for pvc in $(kubectl get pvc -n "$NAMESPACE" -l app=order-service \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    kubectl patch pvc "$pvc" -n "$NAMESPACE" \
        --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
        2>/dev/null || true
done
kubectl delete pvc -n "$NAMESPACE" -l app=order-service \
    --grace-period=0 --force 2>/dev/null || true

# Wait for all PVCs to be gone before scaling back up, otherwise the
# StatefulSet may reattach the old volumes instead of creating fresh ones.
ok "waiting for PVCs to terminate..."
until [[ $(kubectl get pvc -n "$NAMESPACE" -l app=order-service \
        --no-headers 2>/dev/null | wc -l | tr -d ' ') -eq 0 ]]; do
    sleep 2
done

kubectl scale -n "$NAMESPACE" statefulset/order-service --replicas="$REPLICAS" 2>&1
kubectl rollout status -n "$NAMESPACE" statefulset/order-service --timeout=300s
ok "fresh PVCs ready — durable store is empty"

# ── port-forward ──────────────────────────────────────────────────────────────
step "Starting port-forward (auto-reconnect)"
pkill -9 -f "kubectl port-forward" 2>/dev/null || true
sleep 1
(while true; do
    kubectl port-forward -n "$NAMESPACE" svc/order-service 8080:80 2>/dev/null
    sleep 1
done) &
PF_PID=$!
sleep 2

# Smoke test — retry for up to 30s to allow port-forward to connect
ok "waiting for service to respond..."
HEALTH_OK=false
for i in $(seq 1 30); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8080/actuator/health 2>/dev/null || echo "000")
    if [[ "$HTTP" == "200" ]]; then
        HEALTH_OK=true
        break
    fi
    sleep 1
done
if [[ "$HEALTH_OK" != "true" ]]; then
    fail "health check did not return 200 after 30s (last: HTTP $HTTP) — aborting"
    kill $PF_PID 2>/dev/null || true
    exit 2
fi
ok "service healthy (HTTP 200)"

# ── load + chaos ──────────────────────────────────────────────────────────────
step "Running load test + chaos for ${DURATION}s"
echo "  load rate      : 1 order every ${LOAD_RATE}s"
echo "  chaos interval : ${CHAOS_INTERVAL}s between pod kills"
echo "  postgres kill  : every ${CHAOS_PG_EVERY} app kills$([ "$CHAOS_PG_EVERY" = "0" ] && echo " (disabled)" || true)"
"$SCRIPT_DIR/load-test.sh" http://localhost:8080 "$LOAD_RATE" \
    > "$OUTPUT_DIR/load-test.log" 2>&1 &
LOAD_PID=$!

"$SCRIPT_DIR/chaos.sh" order-service "$CHAOS_INTERVAL" "$NAMESPACE" "$CHAOS_PG_EVERY" \
    > "$OUTPUT_DIR/chaos.log" 2>&1 &
CHAOS_PID=$!

sleep "$DURATION"

kill $LOAD_PID $CHAOS_PID 2>/dev/null || true
wait $LOAD_PID $CHAOS_PID 2>/dev/null || true
ok "load and chaos stopped"

# ── wait for recovery ─────────────────────────────────────────────────────────
step "Waiting for pods and postgres to stabilise"
kubectl rollout status -n "$NAMESPACE" statefulset/postgres --timeout=120s 2>&1 \
    | tee "$OUTPUT_DIR/rollout-status.log" || true
kubectl rollout status -n "$NAMESPACE" statefulset/order-service --timeout=300s 2>&1 \
    | tee -a "$OUTPUT_DIR/rollout-status.log" || true

sleep 5  # brief pause for concurrent recovery to start

# ── snapshot ──────────────────────────────────────────────────────────────────
step "Capturing pre-validate state"
curl_retry http://localhost:8080/admin/audit > "$OUTPUT_DIR/audit-pre-validate.json"
jq '{total, byStatus, pendingExecutions, stuckExecutions, allComplete}' "$OUTPUT_DIR/audit-pre-validate.json" || cat "$OUTPUT_DIR/audit-pre-validate.json"

curl_retry http://localhost:8080/durable/dlq > "$OUTPUT_DIR/dlq-pre-validate.json"
DLQ_COUNT=$(jq 'length // 0' "$OUTPUT_DIR/dlq-pre-validate.json" 2>/dev/null || echo "?")
echo "DLQ entries: $DLQ_COUNT"

# ── validate ──────────────────────────────────────────────────────────────────
step "Running validate.sh (timeout: ${VALIDATE_TIMEOUT}s)"
VALIDATE_EXIT=0
"$SCRIPT_DIR/validate.sh" http://localhost:8080 "$VALIDATE_TIMEOUT" \
    2>&1 | tee "$OUTPUT_DIR/validate.log" || VALIDATE_EXIT=$?

# ── final snapshot ────────────────────────────────────────────────────────────
step "Final state"
curl_retry http://localhost:8080/admin/audit > "$OUTPUT_DIR/audit-final.json"
jq '{total, byStatus, pendingExecutions, allComplete}' "$OUTPUT_DIR/audit-final.json" || cat "$OUTPUT_DIR/audit-final.json"

curl_retry http://localhost:8080/durable/dlq > "$OUTPUT_DIR/dlq-final.json"
DLQ_FINAL=$(jq 'length // 0' "$OUTPUT_DIR/dlq-final.json" 2>/dev/null || echo "0")
echo "DLQ entries (final): $DLQ_FINAL"

# Per-pod store counts
echo ""
echo "Per-pod durable store files:"
for pod in $(kubectl get pods -n "$NAMESPACE" -l app=order-service \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    PENDING=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
        sh -c 'ls /app/data/durable-executions/*.msgpack 2>/dev/null | wc -l || echo 0' 2>/dev/null || echo "?")
    DLQ_POD=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
        sh -c 'ls /app/data/durable-dlq/*.msgpack 2>/dev/null | wc -l || echo 0' 2>/dev/null || echo "?")
    echo "  $pod: pending=$PENDING  dlq=$DLQ_POD"
done

# Liveness probe failures (regression check for the sequential-recovery death spiral)
LIVENESS_FAILS=$(kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' \
    2>/dev/null | grep "liveness probe failed" | wc -l)
echo ""
echo "Liveness probe failures during test: $LIVENESS_FAILS"

# ── summary ───────────────────────────────────────────────────────────────────
KILLS=$(grep -c "kill #" "$OUTPUT_DIR/chaos.log" 2>/dev/null || echo 0)
PG_KILLS=$(grep -c "killing postgres" "$OUTPUT_DIR/chaos.log" 2>/dev/null || echo 0)
ORDERS_SUBMITTED=$(wc -l < "$OUTPUT_DIR/load-test.log" 2>/dev/null || echo "?")
TOTAL=$(jq -r '.total // 0' "$OUTPUT_DIR/audit-final.json")
FULFILLED=$(jq -r '.byStatus.FULFILLED // 0' "$OUTPUT_DIR/audit-final.json")

if [[ "$VALIDATE_EXIT" -eq 0 ]]; then
    RESULT="PASS"
    RESULT_COLOR="$GREEN"
else
    RESULT="FAIL"
    RESULT_COLOR="$RED"
fi

cat > "$OUTPUT_DIR/summary.md" << SUMMARY
# Chaos Test: $(basename "$OUTPUT_DIR")

## Result: ${RESULT}

| Metric | Value |
|---|---|
| Orders submitted | ${ORDERS_SUBMITTED} |
| Orders total in DB | ${TOTAL} |
| FULFILLED | ${FULFILLED} |
| DLQ entries | ${DLQ_FINAL} |
| Liveness probe failures | ${LIVENESS_FAILS} |
| App pod kills | ${KILLS} |
| Postgres kills | ${PG_KILLS} |
| validate.sh exit | ${VALIDATE_EXIT} |

## Configuration
- load-rate: ${LOAD_RATE}s / order
- chaos-interval: ${CHAOS_INTERVAL}s
- postgres-kill-every: ${CHAOS_PG_EVERY}
- duration: ${DURATION}s
- validate-timeout: ${VALIDATE_TIMEOUT}s

## Checks
- validate.sh: ${RESULT}
- DLQ populated: $([ "$DLQ_FINAL" -gt 0 ] && echo "YES ($DLQ_FINAL entries)" || echo "NO — postgres may not have been down during recovery")
- Liveness probe deaths: $([ "$LIVENESS_FAILS" -eq 0 ] && echo "NONE (concurrent recovery working)" || echo "WARNING: $LIVENESS_FAILS failures detected")
SUMMARY

echo ""
echo -e "${RESULT_COLOR}Result: ${RESULT}${RESET}"
echo "Output: $OUTPUT_DIR"

# ── cleanup ───────────────────────────────────────────────────────────────────
kill $PF_PID 2>/dev/null || true

exit "$VALIDATE_EXIT"
