#!/usr/bin/env bash
# Module 6 (Kong observability): pushes a Konnect Advanced Analytics
# dashboard directly via the Konnect Admin API — no decK, no local infra.
# Idempotent: updates the existing dashboard by name if found (PUT — this
# API doesn't support PATCH), or creates it.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

: "${KONNECT_TOKEN:?Set KONNECT_TOKEN in .env}"
: "${KONNECT_CONTROL_PLANE:?Set KONNECT_CONTROL_PLANE in .env}"

API="https://${KONNECT_REGION}.api.konghq.com"
auth=(-H "Authorization: Bearer ${KONNECT_TOKEN}" -H "Content-Type: application/json")

cp_id=$(curl -sf "${auth[@]}" \
  "${API}/v2/control-planes?filter%5Bname%5D=${KONNECT_CONTROL_PLANE}" \
  | jq -r '.data[0].id // empty')
: "${cp_id:?Control plane '${KONNECT_CONTROL_PLANE}' not found}"

echo "==> Konnect Analytics dashboard (Claude Code Usage)"
route_id=$(curl -sf "${auth[@]}" \
  "${API}/v2/control-planes/${cp_id}/core-entities/routes?size=200" \
  | jq -r '.data[] | select(.name == "claude-chat-route") | .id')
: "${route_id:?claude-chat-route not found — apply kong/01-general-proxying.yaml (or later) first}"

dashboard_payload=$(jq --arg route_filter "${cp_id}:${route_id}" '{
  name: "Claude Code Usage",
  definition: {
    tiles: .tiles,
    preset_filters: (.preset_filters | map(if .field == "route" then .value = [$route_filter] else . end))
  }
}' observability/claude-code-usage-dashboard.json)

existing_dashboard_id=$(curl -sf "${auth[@]}" \
  "${API}/v2/dashboards?filter%5Bname%5D%5Beq%5D=Claude%20Code%20Usage" \
  | jq -r '.data[0].id // empty')

if [[ -n "$existing_dashboard_id" ]]; then
  echo "    updating existing dashboard (${existing_dashboard_id})..."
  curl -sf "${auth[@]}" -X PUT \
    "${API}/v2/dashboards/${existing_dashboard_id}" \
    --data "$dashboard_payload" > /dev/null
else
  echo "    creating dashboard..."
  curl -sf "${auth[@]}" -X POST \
    "${API}/v2/dashboards" \
    --data "$dashboard_payload" > /dev/null
fi

echo "==> Done. Konnect UI -> Analytics -> Dashboards -> Claude Code Usage"
