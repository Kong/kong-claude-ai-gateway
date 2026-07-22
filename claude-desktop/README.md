# Claude Desktop app settings

The Desktop app's custom base URL is the one setting that stays constant
across every module — only what goes in the API key field changes as auth
semantics change. This file gets a new section per module.

## Module 1 — general proxying (no auth)

1. Open Claude Desktop → **Settings → Developer** (or **Connectors**,
   depending on your Desktop app version) → enable a custom API base URL.
2. Set the base URL to:
   ```
   http://localhost:8000/anthropic
   ```
3. Unless an authentication plugin is enabled at the gateway , no  API key field is required — Kong injects the real Anthropic
   credential from its vault. If the Desktop app insists on a non-empty
   key field, put any placeholder string in; Kong ignores it and replaces
   the header itself.

## Module 2 — key auth at Kong

1. Same base URL as module 1:
   ```
   http://localhost:8000/anthropic
   ```
2. Set the API key field to your `KONG_CONSUMER_API_KEY` value from `.env`
   — this is a Kong-issued credential, not the real Anthropic key. Kong
   validates it against the `claude-desktop` Consumer, then swaps in the
   real vaulted key before proxying upstream.
3. A missing or wrong key now gets rejected with a `401` from Kong before
   the request ever reaches Anthropic.

## Module 3 — OIDC + Okta

Known limitation: Desktop's API key field always sends its value as
`x-api-key`. Module 3 authenticates with Okta via `openid-connect`'s
`bearer` method, which requires a standard `Authorization: Bearer <token>`
header — Desktop has no way to send that, and it can't drive Okta's
interactive browser login either. There's no working Desktop configuration
for this module.

Use `curl` (bearer token) or a browser (interactive login) to verify it
instead — see [`docs/03-oidc-okta.md`](../docs/03-oidc-okta.md#claude-desktop-configuration).
