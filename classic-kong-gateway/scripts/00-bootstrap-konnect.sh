#!/usr/bin/env bash
# One-time setup: create/verify the Konnect control plane and point you at
# the remaining manual steps (data plane cert, vault setup).
#
# NOTE: the exact Konnect API response shape can differ by account/API
# version. If a step below errors, cross-check against the Konnect UI
# (Gateway Manager -> your control plane -> Data Plane Nodes -> New Data
# Plane Node) which always shows the exact values for your account.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

: "${KONNECT_TOKEN:?Set KONNECT_TOKEN in .env}"
: "${KONNECT_REGION:?Set KONNECT_REGION in .env}"
: "${KONNECT_CONTROL_PLANE:?Set KONNECT_CONTROL_PLANE in .env}"

API="https://${KONNECT_REGION}.api.konghq.com"
auth=(-H "Authorization: Bearer ${KONNECT_TOKEN}" -H "Content-Type: application/json")

echo "==> Looking up control plane '${KONNECT_CONTROL_PLANE}'..."
cp_json=$(curl -sf "${auth[@]}" \
  "${API}/v2/control-planes?filter%5Bname%5D=${KONNECT_CONTROL_PLANE}")
cp_id=$(echo "$cp_json" | jq -r '.data[0].id // empty')

if [[ -z "$cp_id" ]]; then
  echo "==> Not found, creating control plane '${KONNECT_CONTROL_PLANE}'..."
  cp_json=$(curl -sf "${auth[@]}" -X POST "${API}/v2/control-planes" \
    -d "{\"name\":\"${KONNECT_CONTROL_PLANE}\",\"cluster_type\":\"CLUSTER_TYPE_HYBRID\"}")
  cp_id=$(echo "$cp_json" | jq -r '.id')
else
  cp_json=$(curl -sf "${auth[@]}" "${API}/v2/control-planes/${cp_id}")
fi
echo "    control plane id: ${cp_id}"

cp_endpoint=$(echo "$cp_json" | jq -r '.config.control_plane_endpoint')
telemetry_endpoint=$(echo "$cp_json" | jq -r '.config.telemetry_endpoint')
echo "    control_plane_endpoint: ${cp_endpoint}"
echo "    telemetry_endpoint:     ${telemetry_endpoint}"

echo
echo "==> Update .env with:"
echo "    KONNECT_CP_ENDPOINT=${cp_endpoint}"
echo "    KONNECT_TELEMETRY_ENDPOINT=${telemetry_endpoint}"
echo
echo "==> Remaining MANUAL steps (Konnect UI, one time):"
echo "    1. Gateway Manager -> ${KONNECT_CONTROL_PLANE} -> Data Plane Nodes ->"
echo "       New Data Plane Node -> generate/download a client certificate"
echo "       -> save the cert/key as tls.crt / tls.key under \${CERTS_DIR:-./certs}"
echo "       (chmod 600 the key)"
echo "    2. Gateway Manager -> ${KONNECT_CONTROL_PLANE} -> Vaults -> New Vault"
echo "       - type: Konnect (or your preferred backend)"
echo "       - prefix: anthropic-secrets"
echo "    3. Add a secret 'anthropic-api-key' with value = your ANTHROPIC_API_KEY"
echo "    4. Copy the resulting config store ID into .env as KONG_VAULT_CONFIG_STORE_ID"
echo
echo "Then run: docker compose up -d && scripts/deck-sync.sh 01-general-proxying"
