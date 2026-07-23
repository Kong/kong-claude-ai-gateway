#!/usr/bin/env bash
# Module 6 (AI Gateway 2.0): pushes a Konnect Advanced Analytics dashboard
# via the Konnect cloud API, scoped to the claude-chat model's traffic.
#
# This is NOT a straight port of scripts/push-konnect-dashboard.sh. Live
# investigation (2026-07-23, Fel Tech org) found the 1.x script's approach
# doesn't carry over at all:
#
#   1. AI Gateway 2.0 control planes are a different resource type
#      (`/v1/ai-gateways/{id}`) from classic Gateway CPs
#      (`/v2/control-planes/{id}`). They do NOT appear in
#      `/v2/control-planes`, and `/v2/control-planes/{cp}/core-entities/routes`
#      404s for an AI Gateway 2.0 id — there is no core-entities route list
#      for this CP type at all (confirmed live: `/v1/ai-gateways/{id}/routes`
#      and `/v1/ai-gateways/{id}/core-entities/routes` both 404 too). A
#      `claude-chat` model's route is only visible as *embedded* config
#      (`config.route.paths`) inside `GET /v1/ai-gateways/{id}/models` — it
#      is not a standalone, filterable entity with its own id the way a
#      decK-authored Route is in 1.x.
#   2. The Konnect Advanced Analytics `llm_usage` datasource's
#      `route` filter field still exists (`datasource_config` reports it as
#      a valid "scoped-uuid" field), but with no route id to put in it,
#      it's unusable here. The datasource DOES expose `ai_request_model`
#      (a plain string field — the model alias, e.g. "claude-chat") and
#      `control_plane` (the CP/gateway id) as filterable fields, so this
#      script scopes the dashboard on those two instead of `route`.
#      (The schema lookup was performed via the kong-konnect MCP tool's
#      cross-org call, not first-party against Fel Tech directly; field
#      correctness is validated by the successful dashboard creation/update
#      and GET confirmation in docs-2.0/06-observability-2.0.md.)
#   3. `.com` vs `.tech`: confirmed live that `/v2/dashboards` (and the
#      rest of the Analytics/Dashboards API) is reachable on `.tech` under
#      the SAME PAT used for the AI Gateway 2.0 `/v1/ai-gateways` calls —
#      no separate `.com` token or base URL needed for this track. (A stray
#      call to `us.api.konghq.com` with the `.tech` PAT returned 401
#      Unauthenticated, confirming the two environments hold separate
#      credentials/orgs, not just separate hostnames for the same one.)
#
# See docs-2.0/06-observability-2.0.md for the full "vs. 1.x" writeup.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
source .env.2.0
set +a

: "${KONGCTL_DEFAULT_KONNECT_PAT:?Set KONGCTL_DEFAULT_KONNECT_PAT in .env.2.0}"

BASE_URL="${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}"
API_V1="${BASE_URL}/v1"
PAT="${KONGCTL_DEFAULT_KONNECT_PAT}"
GATEWAY_NAME="claude-ai-gateway"
MODEL_ALIAS="claude-chat"
DASHBOARD_NAME="Claude AI Gateway 2.0 Usage"

auth=(-H "Authorization: Bearer ${PAT}")
json_auth=("${auth[@]}" -H "Content-Type: application/json")

echo "==> Looking up AI Gateway '${GATEWAY_NAME}'..."
gateway_id=$(curl -sf "${auth[@]}" "${API_V1}/ai-gateways" \
  | jq -r --arg name "$GATEWAY_NAME" '.data[] | select(.name == $name) | .id')
: "${gateway_id:?AI Gateway '${GATEWAY_NAME}' not found — run scripts/00-bootstrap-konnect-2.0.sh first}"
echo "    gateway id: ${gateway_id}"

echo "==> Confirming model '${MODEL_ALIAS}' exists on this gateway..."
model_found=$(curl -sf "${auth[@]}" "${API_V1}/ai-gateways/${gateway_id}/models" \
  | jq -r --arg alias "$MODEL_ALIAS" '.data[] | select(.config.model.alias == $alias) | .config.model.alias')
: "${model_found:?Model alias '${MODEL_ALIAS}' not found on gateway '${GATEWAY_NAME}' — apply kong-2.0/01-general-proxying.yaml first}"
echo "    found model alias: ${model_found}"

echo "==> Konnect Analytics dashboard (${DASHBOARD_NAME})"
# preset_filters scope the whole dashboard to this gateway + this model.
# (route-based scoping, as used by the 1.x script, has no equivalent here —
# see header comment.)
dashboard_payload=$(jq \
  --arg cp "$gateway_id" \
  --arg model "$MODEL_ALIAS" \
  --arg name "$DASHBOARD_NAME" \
  '{
    name: $name,
    definition: {
      tiles: .tiles,
      preset_filters: [
        {field: "control_plane", operator: "in", value: [$cp]},
        {field: "ai_request_model", operator: "in", value: [$model]}
      ]
    }
  }' observability/claude-code-usage-dashboard.json)

existing_dashboard_id=$(curl -sf "${auth[@]}" \
  "${BASE_URL}/v2/dashboards" \
  | jq -r --arg name "$DASHBOARD_NAME" '.data[] | select(.name == $name) | .id // empty' | head -1)

if [[ -n "$existing_dashboard_id" ]]; then
  echo "    updating existing dashboard (${existing_dashboard_id})..."
  curl -sf "${json_auth[@]}" -X PUT \
    "${BASE_URL}/v2/dashboards/${existing_dashboard_id}" \
    --data "$dashboard_payload" > /dev/null
else
  echo "    creating dashboard..."
  curl -sf "${json_auth[@]}" -X POST \
    "${BASE_URL}/v2/dashboards" \
    --data "$dashboard_payload" > /dev/null
fi

echo "==> Done. Konnect UI -> Analytics -> Dashboards -> ${DASHBOARD_NAME}"
