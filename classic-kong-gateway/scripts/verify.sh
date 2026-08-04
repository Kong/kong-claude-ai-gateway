#!/usr/bin/env bash
# Usage: scripts/verify.sh <module>   e.g. scripts/verify.sh 01-general-proxying
set -euo pipefail

MODULE="${1:?Usage: $0 <module-name, e.g. 01-general-proxying>}"
BASE_URL="${GATEWAY_URL:-http://localhost:8000}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

case "$MODULE" in
  01-general-proxying)
    body=$(mktemp)
    status=$(curl -s -o "$body" -w '%{http_code}' \
      "${BASE_URL}/anthropic" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
    [[ "$status" == "200" ]] || fail "expected 200 from ${BASE_URL}/anthropic, got ${status} ($(cat "$body"))"
    grep -q '"role":"assistant"' "$body" || fail "response body missing assistant role: $(cat "$body")"
    pass "module 01: chat completion through Kong succeeded"
    rm -f "$body"
    ;;
  02-key-auth)
    : "${KONG_CONSUMER_API_KEY:?Set KONG_CONSUMER_API_KEY in .env}"
    body=$(mktemp)

    status=$(curl -s -o "$body" -w '%{http_code}' \
      "${BASE_URL}/anthropic" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
    [[ "$status" == "401" ]] || fail "expected 401 with no key, got ${status} ($(cat "$body"))"
    pass "module 02: request without a key was rejected by Kong"

    status=$(curl -s -o "$body" -w '%{http_code}' \
      "${BASE_URL}/anthropic" \
      -H "x-api-key: ${KONG_CONSUMER_API_KEY}" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}')
    [[ "$status" == "200" ]] || fail "expected 200 with a valid key, got ${status} ($(cat "$body"))"
    grep -q '"role":"assistant"' "$body" || fail "response body missing assistant role: $(cat "$body")"
    pass "module 02: chat completion through Kong succeeded with a valid key"
    rm -f "$body"
    ;;
  *)
    echo "No verify steps defined yet for module '$MODULE'" >&2
    exit 1
    ;;
esac
