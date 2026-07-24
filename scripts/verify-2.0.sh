#!/usr/bin/env bash
# Usage: scripts/verify-2.0.sh <module>   e.g. scripts/verify-2.0.sh 01-general-proxying
set -euo pipefail

MODULE="${1:?Usage: $0 <module-name, e.g. 01-general-proxying>}"
BASE_URL="${GATEWAY_URL:-http://localhost:8010}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

case "$MODULE" in
  01-general-proxying)
    # NOTE: the request body's "model" field must be "claude-chat" — the
    # ai_gateway_model's own name, which is what config.model.alias defaults
    # to when left unset (confirmed live via `kongctl diff`/the Konnect API
    # — see docs-2.0/01-general-proxying-2.0.md). It is NOT a target's name
    # ("claude-sonnet-4-6"/the Bedrock model id) — sending a target name
    # here is the model_alias mismatch footgun that silently falls through
    # to the placeholder ai-gateway.upstream.local upstream.
    body=$(mktemp)
    status=$(curl -s -o "$body" -w '%{http_code}' \
      "${BASE_URL}/anthropic" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
    [[ "$status" == "200" ]] || fail "expected 200 from ${BASE_URL}/anthropic, got ${status} ($(cat "$body"))"
    grep -q '"role":"assistant"' "$body" || fail "response body missing assistant role: $(cat "$body")"
    pass "module 01 (2.0): chat completion through Kong succeeded"
    rm -f "$body"
    ;;
  02-key-auth)
    # NOTE: kongctl cannot set a credential's key value declaratively (see
    # kong-2.0/02-key-auth.yaml's header comment) — KONGCTL_CONSUMER_API_KEY
    # must correspond to a credential created directly via the Konnect API
    # with that value as `api_key` (docs-2.0/02-key-auth-2.0.md has the
    # exact curl command), not just set in .env.2.0.
    #
    # NOTE: the request body's "model" field must be "claude-chat" (the
    # ai_gateway_model's own name — config.model.alias defaults to it when
    # unset), same as module 01. The brief's original Step 4/5 examples used
    # "claude-sonnet-4-6" (a target name), which is the model_alias
    # mismatch footgun documented in module 01 — corrected here.
    : "${KONGCTL_CONSUMER_API_KEY:?Set KONGCTL_CONSUMER_API_KEY in .env.2.0}"
    body=$(mktemp)

    status=$(curl -s -o "$body" -w '%{http_code}' \
      "${BASE_URL}/anthropic" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
    [[ "$status" == "401" ]] || fail "expected 401 with no key, got ${status} ($(cat "$body"))"
    pass "module 02 (2.0): request without a key was rejected by Kong"

    status=$(curl -s -o "$body" -w '%{http_code}' \
      "${BASE_URL}/anthropic" \
      -H "x-api-key: ${KONGCTL_CONSUMER_API_KEY}" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
    [[ "$status" == "200" ]] || fail "expected 200 with a valid key, got ${status} ($(cat "$body"))"
    grep -q '"role":"assistant"' "$body" || fail "response body missing assistant role: $(cat "$body")"
    pass "module 02 (2.0): chat completion through Kong succeeded with a valid key"
    rm -f "$body"
    ;;
  03-oidc-okta)
    # NOTE: OKTA_ACCESS_TOKEN must be a real Okta access token. Per
    # docs-2.0/03-oidc-okta-2.0.md's live grant-type investigation, the
    # SE demo tenant's public/native client (SE_DEMO_CLIENT_ID, matching
    # docs/okta-setup.md's "Native Application"/PKCE app) supports
    # authorization_code/password/token-exchange but NOT
    # client_credentials, and its ROPC (password grant) attempt was
    # rejected live by an Okta org sign-on policy ("Resource owner
    # password credentials authentication denied by sign on policy") even
    # with correct credentials — so minting a token for THIS specific verify
    # case (a bearer token Kong's openid-connect plugin will accept) most
    # likely requires the interactive authorization_code flow against that
    # same app, not a scripted grant. The separate SE_DEMO_SUBJECT_CLIENT_ID
    # (confidential, client_credentials-capable) mints a real token but is
    # NOT usable here as-is: `scope=openid`/an ID-token-bearing flow is
    # rejected for client_credentials by Okta itself ("Cannot request
    # 'openid' scopes using client credentials"), and this repo's
    # `okta-oidc` identity provider isn't configured with
    # `client_credentials` in `auth_methods` (see kong-2.0/03-oidc-okta.yaml
    # — only authorization_code/session/bearer). Mint OKTA_ACCESS_TOKEN via
    # a real interactive login against the SE_DEMO_CLIENT_ID app (or your
    # own Okta app per docs/okta-setup.md) before running this.
    #
    # NOTE: the request body's "model" field must be "claude-chat" (the
    # ai_gateway_model's own name — config.model.alias defaults to it when
    # unset), same as modules 01/02.
    : "${OKTA_ACCESS_TOKEN:?Set OKTA_ACCESS_TOKEN (mint one against your Okta tenant first)}"
    body=$(mktemp)

    status=$(curl -s -o "$body" -w '%{http_code}' \
      "${BASE_URL}/anthropic" \
      -H "Authorization: Bearer ${OKTA_ACCESS_TOKEN}" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
    [[ "$status" == "200" ]] || fail "expected 200 with a valid Okta token, got ${status} ($(cat "$body"))"
    grep -q '"role":"assistant"' "$body" || fail "response body missing assistant role: $(cat "$body")"
    pass "module 03 (2.0): chat completion through Kong succeeded with a valid Okta token"
    rm -f "$body"
    ;;
  04-per-user-model-limits)
    # NOTE: this module's actual design (see
    # docs-2.0/04-per-user-model-limits-2.0.md) does NOT use the two
    # `route.headers`-gated models the brief originally drafted (that
    # design was found to hit the real, WONT-FIX KOKO-3852 route-collision
    # bug and was not built). Instead a single model-scoped `pre-function`
    # policy on the existing `claude-chat` model intercepts
    # `GET /anthropic/v1/models` directly and branches on the `team` JWT
    # claim in Lua. The request shape below is unchanged from the brief —
    # it's still a plain GET against `/anthropic/v1/models` with a bearer
    # token — only the server-side implementation differs.
    #
    # NOTE: OKTA_ACCESS_TOKEN_PREMIUM/OKTA_ACCESS_TOKEN_STANDARD must be
    # real Okta access tokens whose `team` claim is literally
    # "kong-premium"/"kong-standard" respectively. Whether the SE demo
    # Okta tenant's test app/user actually has a `team` custom claim
    # configured was not chased down in this task (see
    # docs-2.0/04-per-user-model-limits-2.0.md's closing section) — mint
    # these against your own Okta app/authorization server if needed.
    : "${OKTA_ACCESS_TOKEN_PREMIUM:?Set OKTA_ACCESS_TOKEN_PREMIUM (kong-premium team token)}"
    : "${OKTA_ACCESS_TOKEN_STANDARD:?Set OKTA_ACCESS_TOKEN_STANDARD (kong-standard team token)}"

    premium_count=$(curl -s "${BASE_URL}/anthropic/v1/models" \
      -H "Authorization: Bearer ${OKTA_ACCESS_TOKEN_PREMIUM}" | jq '.data | length')
    [[ "$premium_count" == "2" ]] || fail "expected 2 models for premium team, got ${premium_count}"
    pass "module 04 (2.0): premium team sees 2 models"

    standard_count=$(curl -s "${BASE_URL}/anthropic/v1/models" \
      -H "Authorization: Bearer ${OKTA_ACCESS_TOKEN_STANDARD}" | jq '.data | length')
    [[ "$standard_count" == "1" ]] || fail "expected 1 model for standard team, got ${standard_count}"
    pass "module 04 (2.0): standard team sees 1 model"
    ;;
  05-consumer-rate-limiting)
    # NOTE: this module's config shape diverges from the brief's Step 1
    # draft in exactly one field — see kong-2.0/05-consumer-rate-limiting.yaml's
    # header comment for the live schema pull
    # (GET /ai-gateways/{id}/policies/schemas/ai-rate-limiting-advanced):
    # `config.llm_format` is NOT a real field on this plugin at all
    # (confirmed absent from the schema, grepped for zero matches) and was
    # dropped; `identifier`/`strategy`/`policies[].window_type`/
    # `policies[].limits[].limit`/`window_size` all matched the brief's
    # draft as-is. The request shape below is unchanged from the brief.
    #
    # NOTE: OKTA_ACCESS_TOKEN must be a real Okta access token — same var
    # module 03's case uses (see that case's comment for how to mint one).
    # Every request here uses the SAME token, so all 20 requests count
    # against the SAME `identifier: consumer` counter — that's the point.
    :  "${OKTA_ACCESS_TOKEN:?Set OKTA_ACCESS_TOKEN}"
    saw_429=false
    for i in $(seq 1 20); do
      status=$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/anthropic" \
        -H "Authorization: Bearer ${OKTA_ACCESS_TOKEN}" \
        -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
        -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
      [[ "$status" == "429" ]] && saw_429=true && break
    done
    [[ "$saw_429" == "true" ]] || fail "expected at least one 429 within 20 requests, never saw one"
    pass "module 05 (2.0): rate limit tripped within 20 requests"
    ;;
  07-opentelemetry)
    # NOTE: this case was written for a future Docker-enabled run — not
    # exercised in this task (no Docker, no way to start kong-dp-2.0 or
    # the otel-collector/Jaeger stack in this sandbox). Per
    # docs-2.0/07-opentelemetry-2.0.md, config-side ("claude-otel-tracing"
    # policy created, global:false, attached to claude-chat) IS confirmed
    # live against the real control plane — only the traffic/span-export
    # side below is unverified.
    #
    # Prereqs beyond OKTA_ACCESS_TOKEN (same var module 03/05's cases
    # use): docker-compose.aigw2.yml's kong-dp-2.0 must be (re)started
    # with KONG_TRACING_INSTRUMENTATIONS/KONG_TRACING_SAMPLING_RATE in
    # effect (added to that file by this module — see its comment for the
    # cited, secondhand shakeout finding this depends on), and
    # docker-compose.otel.yml's otel-collector/jaeger services must be up
    # (same collector the 1.x track uses — no re-pointing needed).
    : "${OKTA_ACCESS_TOKEN:?Set OKTA_ACCESS_TOKEN}"
    JAEGER_URL="${JAEGER_URL:-http://localhost:16686}"

    for i in $(seq 1 5); do
      status=$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/anthropic" \
        -H "Authorization: Bearer ${OKTA_ACCESS_TOKEN}" \
        -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
        -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
      [[ "$status" == "200" ]] || fail "expected 200 on request ${i}/5, got ${status}"
    done
    pass "module 07 (2.0): sent 5 requests through claude-chat"

    services=$(curl -s "${JAEGER_URL}/api/services")
    echo "$services" | grep -q 'claude-ai-gateway-2.0' \
      || fail "expected service \"claude-ai-gateway-2.0\" in Jaeger's service list, got: ${services}"
    pass "module 07 (2.0): Jaeger lists the claude-ai-gateway-2.0 service"

    # Pull recent traces for that service and count spans. The shakeout's
    # own resolved-Issue-21 result (cited, not reproduced here) saw 25
    # spans arrive from a batch of requests once both the policy config
    # and the DP tracing env vars were set together.
    trace_count=$(curl -s "${JAEGER_URL}/api/traces?service=claude-ai-gateway-2.0&limit=20" \
      | jq '.data | length')
    [[ "$trace_count" -ge 1 ]] || fail "expected at least 1 trace for claude-ai-gateway-2.0 in Jaeger, got 0 — check kong-dp-2.0's KONG_TRACING_INSTRUMENTATIONS/KONG_TRACING_SAMPLING_RATE env vars actually took effect (docker exec kong-dp-2.0 env | grep TRACING)"
    pass "module 07 (2.0): ${trace_count} trace(s) found for claude-ai-gateway-2.0 in Jaeger"
    ;;
  *)
    echo "No verify steps defined yet for module '$MODULE'" >&2
    exit 1
    ;;
esac
