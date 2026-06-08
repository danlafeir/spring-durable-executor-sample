#!/usr/bin/env bash
# Chaos driver — kills a random order-service pod every INTERVAL seconds.
#
# Optional escalations on a per-N-kills cadence:
#   POSTGRES_KILL_EVERY  — also kills postgres, forcing recovery failures → DLQ entries.
#   PV_KILL_EVERY        — deletes the pod's PVC after killing the pod.
#                          The pod restarts with an empty durable store; any
#                          in-flight executions for that pod are permanently lost
#                          (no record to recover from).  Tests the case where the
#                          storage layer itself is destroyed, not just the JVM.
#
# Usage:
#   ./chaos.sh [STATEFULSET] [INTERVAL_SECONDS] [NAMESPACE] [POSTGRES_KILL_EVERY] [PV_KILL_EVERY] [PVC_PREFIX]
#
# Defaults:
#   STATEFULSET          order-service
#   INTERVAL             15
#   NAMESPACE            default
#   POSTGRES_KILL_EVERY  5    (0 = disabled)
#   PV_KILL_EVERY        0    (disabled by default — destructive)
#   PVC_PREFIX           durable-store   (volumeClaimTemplate name in app.yaml)
#
# Typical workflow:
#   terminal 1:  ./load-test.sh &
#   terminal 2:  ./chaos.sh order-service 8 default 5 7
#   (wait a while, then Ctrl-C both)
#   terminal 3:  kubectl rollout status statefulset/order-service
#               ./validate.sh

set -uo pipefail

STATEFULSET="${1:-order-service}"
INTERVAL="${2:-15}"
NAMESPACE="${3:-default}"
POSTGRES_KILL_EVERY="${4:-5}"
PV_KILL_EVERY="${5:-0}"
PVC_PREFIX="${6:-durable-store}"

CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
RESET='\033[0m'

echo -e "${CYAN}Chaos driver started${RESET}"
echo -e "  target          : statefulset/${STATEFULSET}"
echo -e "  interval        : ${INTERVAL}s between kills"
echo -e "  postgres kill   : every ${POSTGRES_KILL_EVERY} kills$([ "$POSTGRES_KILL_EVERY" = "0" ] && echo " (disabled)" || true)"
echo -e "  pv kill         : every ${PV_KILL_EVERY} kills$([ "$PV_KILL_EVERY" = "0" ] && echo " (disabled)" || true)"
echo -e "  pvc prefix      : ${PVC_PREFIX}"
echo -e "  namespace       : ${NAMESPACE}"
echo -e "  stop            : Ctrl-C"
echo ""

COUNT=0
while true; do
    PODS=()
    while IFS= read -r pod; do
        [[ -n "$pod" ]] && PODS+=("$pod")
    done < <(kubectl get pods -n "$NAMESPACE" \
        -l "app=${STATEFULSET}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

    if (( ${#PODS[@]} == 0 )); then
        echo -e "${YELLOW}No running pods found for ${STATEFULSET} — waiting...${RESET}"
        sleep 5
        continue
    fi

    TARGET="${PODS[$((RANDOM % ${#PODS[@]}))]}"
    COUNT=$(( COUNT + 1 ))
    TS=$(date '+%H:%M:%S')

    echo -e "${RED}[${TS}] kill #${COUNT}: ${TARGET}${RESET}"
    kubectl delete pod "$TARGET" -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true

    # Delete the PVC so the pod restarts with an empty durable store
    if (( PV_KILL_EVERY > 0 && COUNT % PV_KILL_EVERY == 0 )); then
        PVC_NAME="${PVC_PREFIX}-${TARGET}"
        echo -e "${BLUE}[${TS}] deleting PVC ${PVC_NAME} (pod restarts with empty store)${RESET}"

        # Remove pvc-protection finalizer first — the pod is gone from etcd after
        # force deletion so the finalizer should release, but patching is instant
        # and avoids a race with the protection controller.
        kubectl patch pvc "$PVC_NAME" -n "$NAMESPACE" \
            --type=json \
            -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
            2>/dev/null || true

        kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE" \
            --grace-period=0 --force 2>/dev/null || true
    fi

    # Kill postgres to force recovery failures → DLQ entries
    if (( POSTGRES_KILL_EVERY > 0 && COUNT % POSTGRES_KILL_EVERY == 0 )); then
        echo -e "${MAGENTA}[${TS}] killing postgres to trigger recovery failures${RESET}"
        kubectl delete pod postgres-0 -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true
    fi

    sleep "$INTERVAL"
done
