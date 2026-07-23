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
  *)
    echo "No verify steps defined yet for module '$MODULE'" >&2
    exit 1
    ;;
esac
