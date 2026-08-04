#!/usr/bin/env bash
# Module 7 (external observability via Grafana): enables the global
# `prometheus` plugin directly via the Konnect Admin API — this is what
# feeds Kong's /metrics endpoint (scraped by the local Prometheus, see
# docker-compose.observability.yml), which the AI usage Grafana dashboard
# reads from. Not needed for module 6's Konnect-native dashboard, which is
# powered by Konnect's own analytics pipeline independent of this plugin.
# Idempotent: updates the existing global plugin if found (PUT), or creates it.
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

echo "==> prometheus plugin"
existing_plugin_id=$(curl -sf "${auth[@]}" \
  "${API}/v2/control-planes/${cp_id}/core-entities/plugins?size=200" \
  | jq -r '.data[] | select(.name == "prometheus" and .service == null and .route == null) | .id' \
  | head -n1)

if [[ -n "$existing_plugin_id" ]]; then
  echo "    updating existing global prometheus plugin (${existing_plugin_id})..."
  curl -sf "${auth[@]}" -X PUT \
    "${API}/v2/control-planes/${cp_id}/core-entities/plugins/${existing_plugin_id}" \
    --data @observability/prometheus-plugin.json > /dev/null
else
  echo "    creating global prometheus plugin..."
  curl -sf "${auth[@]}" -X POST \
    "${API}/v2/control-planes/${cp_id}/core-entities/plugins" \
    --data @observability/prometheus-plugin.json > /dev/null
fi

echo "==> Done. Kong metrics: http://localhost:8100/metrics (once kong-dp picks up the config)"
