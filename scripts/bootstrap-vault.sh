#!/usr/bin/env bash
# One-command vault setup for the AI Gateway 2.0 control plane this repo
# builds (see 1-gateway.yaml). Ensures a Konnect config store exists,
# seeds it from your local .env, and ensures a vault entity points at it —
# idempotent, safe to re-run any time a secret changes.
#
# Run this AFTER `kongctl apply -f 1-gateway.yaml` (the control plane must
# already exist) and BEFORE `kongctl apply -f 2-claude-integration.yaml`
# (every model_provider references {vault://claude-gateway-vault/<key>}).
#
# kongctl has no declarative resource for config stores or their secrets
# (confirmed: no `ai_gateway.config_stores` in `kongctl explain`'s output),
# so this script talks to the Konnect API directly via `kongctl api` for
# those two pieces. The vault entity itself IS a real declarative resource
# (`ai_gateway.vaults`), but this script creates it the same way for a
# single, consistent one-command setup rather than splitting the flow
# across `kongctl api` and `kongctl apply`.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env
set +a

: "${KONNECT_TOKEN:?Set KONNECT_TOKEN in .env}"
: "${KONNECT_CONTROL_PLANE:?Set KONNECT_CONTROL_PLANE in .env}"

export KONGCTL_DEFAULT_KONNECT_PAT="$KONNECT_TOKEN"
export KONGCTL_DEFAULT_KONNECT_REGION="${KONNECT_REGION:-us}"

VAULT_NAME="claude-gateway-vault"
STORE_NAME="claude-gateway-vault"   # only used if no vault exists yet — see below

echo "==> Looking up AI Gateway '${KONNECT_CONTROL_PLANE}'..."
gateway_id=$(kongctl get ai-gateway -o json 2>/dev/null \
  | jq -r --arg name "$KONNECT_CONTROL_PLANE" '.[] | select(.display_name == $name) | .id')
: "${gateway_id:?Could not find an AI Gateway named '${KONNECT_CONTROL_PLANE}' — run 'kongctl apply -f 1-gateway.yaml' first}"
echo "    gateway id: ${gateway_id}"

echo
echo "==> Looking up vault '${VAULT_NAME}'..."
# Deliberately checks for the VAULT first, not a config store by name: a
# store's name is arbitrary and has no fixed relationship to the vault
# that points at it (this script originally guessed a store name that
# didn't match the store an existing vault was already using, and created
# a second, orphaned store as a result — fixed by always deriving
# store_id from the vault when one already exists, never from a guessed
# name).
vault_id=$(kongctl api get "/v1/ai-gateways/${gateway_id}/vaults" 2>/dev/null \
  | jq -r --arg name "$VAULT_NAME" '.data[] | select(.name == $name) | .id')

if [[ -n "$vault_id" ]]; then
  store_id=$(kongctl api get "/v1/ai-gateways/${gateway_id}/vaults" 2>/dev/null \
    | jq -r --arg name "$VAULT_NAME" '.data[] | select(.name == $name) | .config.config_store_id')
  echo "    vault already exists (${vault_id}), using its config store ${store_id}"
else
  echo "    not found — will create a new config store + vault below"
  echo
  echo "==> Ensuring config store '${STORE_NAME}' exists..."
  store_id=$(kongctl api get "/v1/ai-gateways/${gateway_id}/config-stores" 2>/dev/null \
    | jq -r --arg name "$STORE_NAME" '.data[] | select(.name == $name) | .id')
  if [[ -z "$store_id" ]]; then
    echo "    creating..."
    store_id=$(kongctl api post "/v1/ai-gateways/${gateway_id}/config-stores" name="$STORE_NAME" 2>/dev/null | jq -r '.id')
  fi
  echo "    config store id: ${store_id}"
fi

echo
echo "==> Seeding secrets into config store..."
# Upserts: create if missing, PUT (rotate in place) if already present, so
# a re-run with a rotated value always converges the store to what's in
# .env — no manual UI deletion needed to move from an old value to a new
# one.
seed_secret() {
  local key="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "    skipping '${key}' (not set in .env)"
    return
  fi
  local existing
  existing=$(kongctl api get "/v1/ai-gateways/${gateway_id}/config-stores/${store_id}/secrets" 2>/dev/null \
    | jq -r --arg key "$key" '.data[] | select(.key == $key) | .key')
  if [[ -n "$existing" ]]; then
    kongctl api put "/v1/ai-gateways/${gateway_id}/config-stores/${store_id}/secrets/${key}" value="$value" >/dev/null
    echo "    updated '${key}'"
  else
    kongctl api post "/v1/ai-gateways/${gateway_id}/config-stores/${store_id}/secrets" key="$key" value="$value" >/dev/null
    echo "    created '${key}'"
  fi
}

seed_secret "anthropic-api-key" "${ANTHROPIC_API_KEY:-}"
seed_secret "anthropic-api-key-header" "${ANTHROPIC_API_KEY_HEADER:-x-api-key}"
seed_secret "aws-access-key-id" "${AWS_ACCESS_KEY_ID:-}"
seed_secret "aws-secret-access-key" "${AWS_SECRET_ACCESS_KEY:-}"
seed_secret "okta-issuer" "${OKTA_ISSUER:-}"
seed_secret "okta-client-id" "${OKTA_CLIENT_ID:-}"
seed_secret "okta-client-secret" "${OKTA_CLIENT_SECRET:-}"
seed_secret "oidc-cache-tokens-salt" "${OIDC_CACHE_TOKENS_SALT:-}"

if [[ -z "$vault_id" ]]; then
  echo
  echo "==> Creating vault '${VAULT_NAME}'..."
  vault_id=$(kongctl api post "/v1/ai-gateways/${gateway_id}/vaults" \
    name="$VAULT_NAME" type=konnect "config:={\"config_store_id\":\"${store_id}\"}" 2>/dev/null | jq -r '.id')
  echo "    vault id: ${vault_id}"
fi

echo
echo "Done. Every *.yaml file in this repo can now resolve"
echo "{vault://${VAULT_NAME}/<key>} references against this config store."
