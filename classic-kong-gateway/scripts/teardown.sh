#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Stopping local stack (kong, prometheus, grafana, jaeger, otel-collector)..."
docker compose -f docker-compose.yml -f docker-compose.observability.yml -f docker-compose.otel.yml down -v

set -a
source .env
set +a

read -rp "Also delete the Konnect control plane? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  : "${KONNECT_TOKEN:?Set KONNECT_TOKEN in .env}"
  : "${KONNECT_CONTROL_PLANE:?Set KONNECT_CONTROL_PLANE in .env}"

  API="https://${KONNECT_REGION}.api.konghq.com"
  cp_id=$(curl -sf -H "Authorization: Bearer ${KONNECT_TOKEN}" \
    "${API}/v2/control-planes?filter%5Bname%5D=${KONNECT_CONTROL_PLANE}" \
    | jq -r '.data[0].id // empty')

  if [[ -n "$cp_id" ]]; then
    curl -sf -X DELETE -H "Authorization: Bearer ${KONNECT_TOKEN}" \
      "${API}/v2/control-planes/${cp_id}"
    echo "Deleted control plane ${cp_id}"
  else
    echo "Control plane '${KONNECT_CONTROL_PLANE}' not found, skipping"
  fi
fi

rm -rf "${CERTS_DIR:-certs}"
echo "Teardown complete."
