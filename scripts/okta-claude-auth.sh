#!/usr/bin/env bash
# okta-claude-auth.sh — apiKeyHelper for Claude Code. Signs the user in to
# Okta (Authorization Code + PKCE) and prints an access token for Claude Code
# to send to the Kong AI Gateway as its bearer credential.
#
# Adapted from https://developer.konghq.com/cookbooks/claude-code-sso/
#
# Installed to ~/.claude/okta-claude-auth.sh by scripts/setup-claude-code.sh,
# which also writes the OKTA_* settings this script reads (Claude Code runs
# helpers in a clean environment, so they must live in settings.json "env").
#
# Behaviour: returns the cached token if still valid, otherwise refreshes it
# silently with the refresh token, otherwise opens the browser to sign in.
# Requires: bash, curl, openssl, python3 (all preinstalled on macOS/Linux).
set -euo pipefail

OKTA_DOMAIN="${OKTA_DOMAIN:?OKTA_DOMAIN is not set (e.g. https://your-org.okta.com)}"
CLIENT_ID="${OKTA_CLIENT_ID:?OKTA_CLIENT_ID is not set}"
AUTH_SERVER="${OKTA_AUTH_SERVER:-default}"
AUDIENCE="${OKTA_AUDIENCE:-api://default}"
# Same loopback port Claude Desktop uses in this walkthrough, so the Okta app
# already has http://localhost:8765/callback registered.
REDIRECT_PORT="${OKTA_REDIRECT_PORT:-8765}"
REDIRECT_URI="http://localhost:${REDIRECT_PORT}/callback"
SCOPES="${OKTA_SCOPES:-openid claude-access offline_access}"

CACHE_DIR="${HOME}/.claude/okta-cache"
TOKEN_CACHE="${CACHE_DIR}/tokens.json"
LOCK_FILE="${CACHE_DIR}/auth.lock"

log()  { echo "[okta-auth] $*" >&2; }
die()  { echo "[okta-auth] ERROR: $*" >&2; exit 1; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
random_str() { openssl rand -hex "${1:-32}"; }
json_get() { echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*: *"\([^"]*\)".*/\1/' || true; }
json_get_num() { echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]*" | grep -o '[0-9]*$' || true; }

mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"

cache_read() { if [[ -f "$TOKEN_CACHE" ]]; then cat "$TOKEN_CACHE"; else echo "{}"; fi; }
cache_write() { echo "$1" > "$TOKEN_CACHE" && chmod 600 "$TOKEN_CACHE"; }

access_token_valid() {
  local cache exp now tok
  cache=$(cache_read)
  tok=$(json_get "$cache" "access_token")
  exp=$(json_get_num "$cache" "expires_at")
  now=$(date +%s)
  [[ -z "$tok" || -z "$exp" ]] && return 1
  (( now < exp - 60 )) && { echo "$tok"; return 0; }
  return 1
}

do_refresh() {
  local cache refresh_tok response new_access new_refresh expires_in expires_at now
  cache=$(cache_read)
  refresh_tok=$(json_get "$cache" "refresh_token")
  [[ -z "$refresh_tok" ]] && return 1
  log "Attempting silent refresh..."
  response=$(curl -sf -X POST "${OKTA_DOMAIN}/oauth2/${AUTH_SERVER}/v1/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token&refresh_token=${refresh_tok}&client_id=${CLIENT_ID}&scope=${SCOPES// /%20}") || return 1
  new_access=$(json_get "$response" "access_token")
  new_refresh=$(json_get "$response" "refresh_token")
  expires_in=$(json_get_num "$response" "expires_in")
  [[ -z "$new_access" ]] && return 1
  now=$(date +%s); expires_at=$(( now + ${expires_in:-3600} ))
  cache_write "{\"access_token\":\"${new_access}\",\"refresh_token\":\"${new_refresh:-$refresh_tok}\",\"expires_at\":${expires_at}}"
  log "Token refreshed successfully."
  echo "$new_access"
}

start_callback_server() {
  local expected_state="$1"
  python3 - "$REDIRECT_PORT" "$expected_state" <<'PYEOF'
import sys, socket, urllib.parse
port, expected_state = int(sys.argv[1]), sys.argv[2]
HTML_OK = b"<html><body><h2>Authenticated! Close this tab.</h2><script>window.close();</script></body></html>"
HTML_ERR = b"<html><body><h2>Authentication failed.</h2></body></html>"
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", port)); sock.listen(1); sock.settimeout(120)
try:
    conn, _ = sock.accept(); data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk: break
        data += chunk
    path = data.decode(errors="replace").split(" ")[1] if b" " in data else "/"
    params = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
    code, state = params.get("code",[None])[0], params.get("state",[None])[0]
    error = params.get("error",[None])[0]
    ok = code and state == expected_state and not error
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n" + (HTML_OK if ok else HTML_ERR))
    conn.close()
    if not ok: sys.exit(1)
    print(code, end="")
except socket.timeout:
    sys.stderr.write("[okta-auth] Timed out waiting for callback.\n"); sys.exit(1)
finally: sock.close()
PYEOF
}

do_auth_code_flow() {
  local verifier challenge state auth_url code response access_tok refresh_tok expires_in expires_at now
  verifier=$(random_str 32)
  challenge=$(echo -n "$verifier" | openssl dgst -binary -sha256 | b64url)
  state=$(random_str 16)
  auth_url="${OKTA_DOMAIN}/oauth2/${AUTH_SERVER}/v1/authorize?response_type=code&client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI}&scope=${SCOPES// /+}&audience=${AUDIENCE}&state=${state}&code_challenge=${challenge}&code_challenge_method=S256"
  log "Opening browser for Okta login..."
  log "If the browser doesn't open, visit: ${auth_url}"
  if command -v open >/dev/null 2>&1; then
    open "$auth_url" &
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$auth_url" >/dev/null 2>&1 &
  fi
  log "Waiting for callback on http://localhost:${REDIRECT_PORT}/callback ..."
  code=$(start_callback_server "$state")
  [[ -z "$code" ]] && die "No authorization code received."
  log "Authorization code received. Exchanging for tokens..."
  response=$(curl -sf -X POST "${OKTA_DOMAIN}/oauth2/${AUTH_SERVER}/v1/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=${code}&redirect_uri=${REDIRECT_URI}&client_id=${CLIENT_ID}&code_verifier=${verifier}") || die "Token exchange failed."
  access_tok=$(json_get "$response" "access_token")
  refresh_tok=$(json_get "$response" "refresh_token")
  expires_in=$(json_get_num "$response" "expires_in")
  [[ -z "$access_tok" ]] && die "No access_token in response."
  now=$(date +%s); expires_at=$(( now + ${expires_in:-3600} ))
  cache_write "{\"access_token\":\"${access_tok}\",\"refresh_token\":\"${refresh_tok}\",\"expires_at\":${expires_at}}"
  log "Authentication successful. Token cached."
  echo "$access_tok"
}

acquire_lock() {
  local waited=0
  while ! mkdir "$LOCK_FILE" 2>/dev/null; do
    sleep 0.5; (( waited++ ))
    (( waited > 30 )) && { log "Lock timeout, removing stale lock"; rm -rf "$LOCK_FILE"; }
  done
  trap 'rm -rf "$LOCK_FILE"' EXIT INT TERM
}

main() {
  acquire_lock
  tok=$(access_token_valid) && { echo "$tok"; exit 0; }
  tok=$(do_refresh 2>/dev/null) && { echo "$tok"; exit 0; }
  tok=$(do_auth_code_flow)
  echo "$tok"
}

main "$@"
