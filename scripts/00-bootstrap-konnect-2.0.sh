#!/usr/bin/env bash
# One-time setup: create/verify the AI Gateway 2.0 control plane via kongctl,
# then provision its vault end-to-end via direct Konnect API calls (config
# store + secrets + vault entity) — no manual UI step required. Idempotent:
# safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env.2.0
set +a

: "${KONGCTL_DEFAULT_KONNECT_PAT:?Set KONGCTL_DEFAULT_KONNECT_PAT in .env.2.0}"

# AI Gateway 2.0 currently lives on a separate Konnect environment from the
# 1.x track (.tech, not .com). Override with KONNECT_AIGW2_BASE_URL if your
# org differs.
BASE_URL="${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}"
API="${BASE_URL}/v1"
PAT="${KONGCTL_DEFAULT_KONNECT_PAT}"
GATEWAY_NAME="claude-ai-gateway"
STORE_NAME="claude-ai-gateway-secrets"
VAULT_NAME="ai-vault"

auth=(-H "Authorization: Bearer ${PAT}")
json_auth=("${auth[@]}" -H "Content-Type: application/json")

echo "==> Applying kong-2.0/00-platform.yaml via kongctl..."
kongctl apply -f kong-2.0/00-platform.yaml \
  --base-url "${BASE_URL}" --pat "${PAT}" --auto-approve

echo
echo "==> Looking up AI Gateway '${GATEWAY_NAME}' (for vault provisioning)..."
gateways_json=$(curl -sf "${auth[@]}" "${API}/ai-gateways")
gateway_id=$(echo "$gateways_json" | jq -r --arg name "$GATEWAY_NAME" \
  '.data[] | select(.name == $name) | .id')
: "${gateway_id:?Could not find AI Gateway '${GATEWAY_NAME}' via API — check the kongctl apply output above}"
echo "    gateway id: ${gateway_id}"

cp_endpoint=$(echo "$gateways_json" | jq -r --arg name "$GATEWAY_NAME" \
  '.data[] | select(.name == $name) | .endpoints.configuration' | sed 's#^https://##')
telemetry_endpoint=$(echo "$gateways_json" | jq -r --arg name "$GATEWAY_NAME" \
  '.data[] | select(.name == $name) | .endpoints.telemetry' | sed 's#^https://##')
echo "    configuration endpoint: ${cp_endpoint}"
echo "    telemetry endpoint:     ${telemetry_endpoint}"

echo
echo "==> Ensuring config store '${STORE_NAME}' exists..."
store_id=$(curl -sf "${auth[@]}" "${API}/ai-gateways/${gateway_id}/config-stores" \
  | jq -r --arg name "$STORE_NAME" '.data[] | select(.name == $name) | .id')

if [[ -z "$store_id" ]]; then
  echo "    creating..."
  store_id=$(curl -sf "${json_auth[@]}" -X POST \
    -d "{\"name\":\"${STORE_NAME}\"}" \
    "${API}/ai-gateways/${gateway_id}/config-stores" | jq -r '.id')
fi
echo "    config store id: ${store_id}"

echo
echo "==> Seeding secrets into config store..."
# Upserts: create if missing, PUT (rotate in place) if already present. The
# Konnect API supports both (create-ai-gateway-config-store-secret /
# update-ai-gateway-config-store-secret) so a re-run with real values always
# converges the store to what's in .env.2.0 — no manual UI deletion needed
# to move from a placeholder to a real value.
seed_secret() {
  local key="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "    skipping '${key}' (not set in .env.2.0)"
    return
  fi
  local existing
  existing=$(curl -sf "${auth[@]}" \
    "${API}/ai-gateways/${gateway_id}/config-stores/${store_id}/secrets" \
    | jq -r --arg key "$key" '.data[] | select(.key == $key) | .key')
  if [[ -n "$existing" ]]; then
    local put_body
    put_body=$(jq -n --arg v "$value" '{"value": $v}')
    curl -sf "${json_auth[@]}" -X PUT -d "$put_body" \
      "${API}/ai-gateways/${gateway_id}/config-stores/${store_id}/secrets/${key}" >/dev/null
    echo "    updated '${key}'"
    return
  fi
  local post_body
  post_body=$(jq -n --arg k "$key" --arg v "$value" '{"key": $k, "value": $v}')
  curl -sf "${json_auth[@]}" -X POST -d "$post_body" \
    "${API}/ai-gateways/${gateway_id}/config-stores/${store_id}/secrets" >/dev/null
  echo "    created '${key}'"
}

seed_secret "anthropic-api-key" "${ANTHROPIC_API_KEY:-}"
seed_secret "aws-access-key-id" "${AWS_ACCESS_KEY_ID:-}"
seed_secret "aws-secret-access-key" "${AWS_SECRET_ACCESS_KEY:-}"
seed_secret "aws-region" "${AWS_REGION:-}"

echo
echo "==> Ensuring vault '${VAULT_NAME}' exists..."
vault_id=$(curl -sf "${auth[@]}" "${API}/ai-gateways/${gateway_id}/vaults" \
  | jq -r --arg name "$VAULT_NAME" '.data[] | select(.name == $name) | .id')

if [[ -z "$vault_id" ]]; then
  echo "    creating..."
  vault_body=$(jq -n --arg name "$VAULT_NAME" --arg store_id "$store_id" \
    '{"name": $name, "type": "konnect", "config": {"config_store_id": $store_id}}')
  vault_id=$(curl -sf "${json_auth[@]}" -X POST -d "$vault_body" \
    "${API}/ai-gateways/${gateway_id}/vaults" | jq -r '.id')
fi
echo "    vault id: ${vault_id}"
echo "    every kong-2.0/*.yaml can now reference {vault://${VAULT_NAME}/<key>}"

echo
echo "==> Remaining MANUAL step (Konnect UI, one time):"
echo "    AI Gateway -> ${GATEWAY_NAME} -> Data Plane Nodes ->"
echo "    New Data Plane Node -> generate/download a client certificate"
echo "    -> save as tls.crt / tls.key under \${CERTS_DIR_2_0:-./certs-2.0}"
echo "    (chmod 644 the key — the DP container needs read access; a"
echo "    stricter chmod 600 crashes kong-gateway at init_by_lua with"
echo "    'tls.key: Permission denied')"
echo
echo "==> Update .env.2.0 with:"
echo "    KONNECT_AIGW2_CP_ENDPOINT=${cp_endpoint}"
echo "    KONNECT_AIGW2_TELEMETRY_ENDPOINT=${telemetry_endpoint}"
echo
echo "Then run: docker compose -f docker-compose.aigw2.yml up -d"
