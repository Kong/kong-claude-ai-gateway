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
  *)
    echo "No verify steps defined yet for module '$MODULE'" >&2
    exit 1
    ;;
esac
