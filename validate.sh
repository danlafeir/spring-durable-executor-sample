#!/usr/bin/env bash
# Validates that every submitted order eventually reached FULFILLED status.
#
# Usage:
#   ./validate.sh [BASE_URL] [TIMEOUT_SECONDS]
#
# Typical chaos-test workflow:
#   1. docker-compose up  (or kubectl apply -f k8s/)
#   2. ./load-test.sh &   (submit orders continuously)
#   3. Kill pods randomly while load-test runs
#   4. Stop load-test (Ctrl+C)
#   5. ./validate.sh      (wait for all orders to complete, then report pass/fail)
#
# Exit codes:
#   0 — all orders reached FULFILLED, durable store empty
#   1 — timeout or service unreachable
#
# Kubernetes tip: after stopping chaos, wait for all pods to be Ready before
# running this script so recovery has had a chance to replay open executions:
#   kubectl rollout status statefulset/order-service

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
TIMEOUT="${2:-300}"
POLL_INTERVAL=5

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

echo -e "${CYAN}Validating durable execution completeness${RESET}"
echo -e "  endpoint : ${BASE_URL}/admin/audit"
echo -e "  timeout  : ${TIMEOUT}s"
echo -e "  polling  : every ${POLL_INTERVAL}s"
echo ""
printf "%-6s  %-8s  %-10s  %-9s  %-7s  %s\n" \
    "time" "total" "fulfilled" "pending" "stuck" "incomplete"
printf "%-6s  %-8s  %-10s  %-9s  %-7s  %s\n" \
    "------" "--------" "----------" "---------" "-------" "----------"

START=$(date +%s)
while true; do
    ELAPSED=$(( $(date +%s) - START ))

    if (( ELAPSED >= TIMEOUT )); then
        echo ""
        echo -e "${RED}FAIL: timed out after ${TIMEOUT}s — not all orders completed${RESET}"
        echo ""
        echo "Final audit:"
        curl -s "${BASE_URL}/admin/audit" | jq .
        exit 1
    fi

    AUDIT=$(curl -s --max-time 5 "${BASE_URL}/admin/audit" 2>/dev/null) || {
        printf "${YELLOW}%-6s  service unreachable — waiting...${RESET}\n" "${ELAPSED}s"
        sleep "$POLL_INTERVAL"
        continue
    }

    TOTAL=$(echo     "$AUDIT" | jq -r '.total')
    FULFILLED=$(echo "$AUDIT" | jq -r '.byStatus.FULFILLED // 0')
    PENDING=$(echo   "$AUDIT" | jq -r '.pendingExecutions')
    STUCK=$(echo     "$AUDIT" | jq -r '.stuckExecutions')
    INCOMPLETE=$(echo "$AUDIT" | jq -r '.incompleteOrders | length')
    ALL_COMPLETE=$(echo "$AUDIT" | jq -r '.allComplete')

    STUCK_COLOR="$RESET"
    [[ "$STUCK" != "0" ]] && STUCK_COLOR="$YELLOW"

    printf "%-6s  %-8s  %-10s  %-9s  ${STUCK_COLOR}%-7s${RESET}  %s\n" \
        "${ELAPSED}s" "$TOTAL" "$FULFILLED" "$PENDING" "$STUCK" "$INCOMPLETE"

    if [[ "$ALL_COMPLETE" == "true" ]]; then
        echo ""
        echo -e "${GREEN}PASS: all ${TOTAL} orders reached FULFILLED — durable store empty${RESET}"
        exit 0
    fi

    sleep "$POLL_INTERVAL"
done
