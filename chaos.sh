#!/usr/bin/env bash
# Chaos driver — kills a random order-service pod every INTERVAL seconds,
# and every POSTGRES_KILL_EVERY kills also kills the postgres pod.
# A postgres kill during active recovery guarantees DLQ entries because
# the DB exception causes retryExecution to fail.
#
# Usage:
#   ./chaos.sh [STATEFULSET] [INTERVAL_SECONDS] [NAMESPACE] [POSTGRES_KILL_EVERY]
#
# Defaults:
#   STATEFULSET          order-service
#   INTERVAL             15
#   NAMESPACE            default
#   POSTGRES_KILL_EVERY  5   (0 = disabled)
#
# Typical workflow:
#   terminal 1:  ./load-test.sh &
#   terminal 2:  ./chaos.sh order-service 8
#   (wait a while, then Ctrl-C both)
#   terminal 3:  kubectl rollout status statefulset/order-service
#               ./validate.sh

set -uo pipefail

STATEFULSET="${1:-order-service}"
INTERVAL="${2:-15}"
NAMESPACE="${3:-default}"
POSTGRES_KILL_EVERY="${4:-5}"

CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

echo -e "${CYAN}Chaos driver started${RESET}"
echo -e "  target          : statefulset/${STATEFULSET}"
echo -e "  interval        : ${INTERVAL}s between kills"
echo -e "  postgres kill   : every ${POSTGRES_KILL_EVERY} kills$([ "$POSTGRES_KILL_EVERY" = "0" ] && echo " (disabled)" || true)"
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

    # Periodically kill postgres to force recovery failures → DLQ entries
    if (( POSTGRES_KILL_EVERY > 0 && COUNT % POSTGRES_KILL_EVERY == 0 )); then
        echo -e "${MAGENTA}[${TS}] killing postgres to trigger recovery failures${RESET}"
        kubectl delete pod postgres-0 -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true
    fi

    sleep "$INTERVAL"
done
