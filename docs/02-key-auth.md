# 02 — Key auth at Kong

## What this adds

Everything from module 1, plus a `key-auth` plugin enforced globally and one
Consumer (`claude-desktop`) with a key credential. Claude Desktop must now
send a Kong-issued key to reach the gateway at all — the raw Anthropic key
still never leaves Kong's vault.

Why it matters: this is the first step where "who is calling Kong" and "what
Kong calls upstream" become two different credentials. Modules 3-5 build on
this same Consumer identity (OIDC, per-user limits, rate limiting).

## What's in `kong/02-key-auth.yaml`

Same two services/routes/plugins as module 1 (`claude-chat`, `claude-models`),
plus:

- a global `key-auth` plugin with `config.key_names: [x-api-key]` — Claude
  Desktop's API key field is sent as the `x-api-key` header, same header
  Anthropic itself uses, so no client-side change is needed beyond filling
  in that field
- a `claude-desktop` Consumer with one `keyauth_credentials` entry, whose
  key value comes from `KONG_CONSUMER_API_KEY` in `.env` (this is a Kong
  credential you generate yourself, not an Anthropic key)

`key-auth` runs before `ai-proxy-advanced`, so the flow per request is:
Kong checks the incoming `x-api-key` against the Consumer's key → if valid,
`ai-proxy-advanced` overwrites `x-api-key` with the real vaulted Anthropic
key before proxying upstream.

## Apply it

```bash
set -a; source .env; set +a
export DECK_KONNECT_TOKEN="$KONNECT_TOKEN"
export DECK_KONNECT_CONTROL_PLANE_NAME="$KONNECT_CONTROL_PLANE"
export DECK_VAULT_CONFIG_STORE_ID="$KONG_VAULT_CONFIG_STORE_ID"
export DECK_CONSUMER_API_KEY="$KONG_CONSUMER_API_KEY"

deck gateway apply kong/02-key-auth.yaml
```

If `KONNECT_REGION` isn't `us`, also set
`export DECK_KONNECT_ADDR="https://${KONNECT_REGION}.api.konghq.com"` before
running `deck`.

## Claude Desktop configuration

See [`claude-desktop/README.md`](../claude-desktop/README.md) — same base
URL as module 1, but now put your `KONG_CONSUMER_API_KEY` value in the
Desktop app's API key field. Without it, requests get a `401` from Kong.