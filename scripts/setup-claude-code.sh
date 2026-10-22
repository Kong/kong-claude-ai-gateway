#!/usr/bin/env bash
# One-command Claude Code setup for the Kong AI Gateway in this repo.
#
# Installs the Okta sign-in helper to ~/.claude/okta-claude-auth.sh and
# merges the settings Claude Code needs into ~/.claude/settings.json (your
# existing settings are kept; a backup is written next to the file).
# Reads OKTA_ISSUER and OKTA_CLIENT_ID from this repo's .env — the same Okta
# app as the Claude Desktop setup. Makes no changes to Kong or Okta.
#
# Usage: scripts/setup-claude-code.sh [gateway-url]
#        (default gateway URL: http://localhost:8000/anthropic)
set -euo pipefail
cd "$(dirname "$0")/.."

for cmd in jq curl openssl python3; do
  command -v "$cmd" >/dev/null || { echo "Missing required tool: $cmd" >&2; exit 1; }
done

# Remember whether the caller's shell already has a key set (checked at the
# end) before .env is sourced, since .env also defines ANTHROPIC_API_KEY.
shell_has_key=""
[[ -n "${ANTHROPIC_API_KEY:-}" || -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && shell_has_key=1

set -a
source .env
set +a
: "${OKTA_ISSUER:?Set OKTA_ISSUER in .env}"
: "${OKTA_CLIENT_ID:?Set OKTA_CLIENT_ID in .env}"

GATEWAY_URL="${1:-http://localhost:8000/anthropic}"

# .env holds the full discovery URL (https://<domain>/oauth2/<server>/.well-known/...);
# the helper needs the Okta domain and authorization server separately.
issuer="${OKTA_ISSUER%/.well-known/openid-configuration}"
okta_domain="${issuer%%/oauth2/*}"
auth_server="${issuer##*/oauth2/}"
[[ "$issuer" == */oauth2/* ]] || { echo "OKTA_ISSUER must look like https://<domain>/oauth2/<server>[/.well-known/openid-configuration]" >&2; exit 1; }

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
mkdir -p "$CLAUDE_DIR"

echo "==> Installing helper to ${CLAUDE_DIR}/okta-claude-auth.sh"
cp scripts/okta-claude-auth.sh "${CLAUDE_DIR}/okta-claude-auth.sh"
chmod 700 "${CLAUDE_DIR}/okta-claude-auth.sh"

echo "==> Updating ${SETTINGS}"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "${SETTINGS}.bak"

tmp=$(mktemp)
jq --arg helper "${CLAUDE_DIR}/okta-claude-auth.sh" \
   --arg url "$GATEWAY_URL" \
   --arg domain "$okta_domain" \
   --arg client "$OKTA_CLIENT_ID" \
   --arg server "$auth_server" '
  .apiKeyHelper = $helper
  | .env = ((.env // {}) + {
      ANTHROPIC_BASE_URL: $url,
      OKTA_DOMAIN: $domain,
      OKTA_CLIENT_ID: $client,
      OKTA_AUTH_SERVER: $server,
      OKTA_AUDIENCE: "api://default",
      OKTA_REDIRECT_PORT: "8765",
      OKTA_SCOPES: "openid claude-access offline_access",
      ANTHROPIC_MODEL: "claude-sonnet-5-5",
      ANTHROPIC_DEFAULT_SONNET_MODEL: "claude-sonnet-5-5",
      ANTHROPIC_DEFAULT_OPUS_MODEL: "claude-opus-5-5",
      ANTHROPIC_DEFAULT_HAIKU_MODEL: "claude-haiku-5-5",
      CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1"
    })' "${SETTINGS}.bak" > "$tmp"
mv "$tmp" "$SETTINGS"

if [[ -n "$shell_has_key" ]]; then
  echo
  echo "NOTE: ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN is set in your shell and would"
  echo "      bypass the helper. Run this in your terminal before starting Claude Code:"
  echo "        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN"
fi

echo
echo "Done. Start Claude Code with:  claude"
echo "The first request opens your browser to sign in with Okta."
