#!/usr/bin/env bash
# Usage: ./load-test.sh [BASE_URL] [DELAY_SECONDS]
#   BASE_URL      defaults to http://localhost:8080
#   DELAY_SECONDS defaults to 0.5  (2 requests/sec)
#
# Tips:
#   Watch order statuses live:
#     watch -n2 'curl -s http://localhost:8080/orders | jq "[.[] | {id,status,product}]"'
#
#   Check pending durable executions:
#     curl -s http://localhost:8080/admin/executions | jq .
#
#   Demo recovery: run this script, then in another terminal:
#     docker-compose restart app
#   Watch the app recover in-flight orders on restart.

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
DELAY="${2:-0.5}"

PRODUCTS=("Widget" "Gadget" "Doohickey" "Thingamajig" "Sprocket" "Cog" "Flange")

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo -e "${CYAN}Sending orders to ${BASE_URL} every ${DELAY}s — Ctrl+C to stop${RESET}"
echo ""

COUNT=0
while true; do
    PRODUCT="${PRODUCTS[$RANDOM % ${#PRODUCTS[@]}]}"
    QTY=$(( RANDOM % 9 + 1 ))
    PRICE=$(( RANDOM % 90 + 10 ))

    RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/orders" \
        -H "Content-Type: application/json" \
        -d "{\"product\":\"${PRODUCT}\",\"quantity\":${QTY},\"pricePerUnit\":${PRICE}}" 2>/dev/null) \
        || { echo -e "${RED}Connection refused — is the server running at ${BASE_URL}?${RESET}"; sleep 2; continue; }

    CODE=$(tail -1 <<< "$RESP")
    BODY=$(head -1 <<< "$RESP")
    ID=$(echo "$BODY" | jq -r '.id // "error"' 2>/dev/null || echo "error")

    COUNT=$(( COUNT + 1 ))

    if [[ "$CODE" == "202" ]]; then
        COLOR="$GREEN"
    elif [[ "$CODE" == "4"* ]]; then
        COLOR="$YELLOW"
    else
        COLOR="$RED"
    fi

    printf "${COLOR}[%4d] [HTTP %s] order=%-36s  %dx %-14s @ \$%d${RESET}\n" \
        "$COUNT" "$CODE" "$ID" "$QTY" "$PRODUCT" "$PRICE"

    sleep "$DELAY"
done
