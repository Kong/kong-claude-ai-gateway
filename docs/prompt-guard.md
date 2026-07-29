# Prompt guard (regex) + key auth — extra test case

Not part of the numbered module chain (1-8) — this branches off **module
2's** key-auth setup instead of continuing from module 3+'s OIDC, to keep
the test simple: static API key, no Okta login, one plugin added.

## What this adds

`kong/prompt-guard-keyauth.yaml` = module 2 (`kong/02-key-auth.yaml`)
exactly, plus a regex-only `ai-prompt-guard` plugin on `claude-chat`,
ahead of `ai-proxy-advanced`:

```yaml
- name: ai-prompt-guard
  config:
    genai_category: text/generation
    llm_format: anthropic
    deny_patterns:
    - '\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'   # 16-digit card-like number
    - '\b\d{3}-\d{2}-\d{4}\b'                      # US SSN-like number
```

`ai-prompt-guard` also supports `allow_patterns` (only requests matching
at least one pattern get through — an allowlist instead of a denylist) —
not used here, but a one-line change if you want stricter behavior. Both
are plain regex against the `user`-role message content; there's no ML
classifier involved (that's a separate, paid capability of the plugin).

Why it matters: this is a gateway-side content check that runs *before* a
prompt ever reaches Anthropic — cheaper and faster than relying on the
model itself to refuse, and it works the same regardless of which model is
targeted.

## ⚠️ This overwrites your current live setup if you're past module 2

`claude-chat` / `claude-chat-route` are the same names used by every other
module. Applying this file **replaces** whatever's currently live on that
service — if you've already applied module 3+ (OIDC, rate limiting,
tracing), this swaps all of that out for plain key-auth + prompt-guard.
Nothing is lost (it's all still in `kong/07-opentelemetry.yaml`), but
you'll need to re-apply that file afterward to get back to where you were.

## Apply it

```bash
set -a; source .env; set +a
export DECK_KONNECT_TOKEN="$KONNECT_TOKEN"
export DECK_KONNECT_CONTROL_PLANE_NAME="$KONNECT_CONTROL_PLANE"
export DECK_VAULT_CONFIG_STORE_ID="$KONG_VAULT_CONFIG_STORE_ID"
export DECK_CONSUMER_API_KEY="$KONG_CONSUMER_API_KEY"

deck gateway apply kong/prompt-guard-keyauth.yaml
```

If `KONNECT_REGION` isn't `us`, also set
`export DECK_KONNECT_ADDR="https://${KONNECT_REGION}.api.konghq.com"` before
running `deck`.

**To revert back to the full module 7 state** once you're done testing:

```bash
# re-export the module 7 vars (Okta/OIDC/team), then:
deck gateway apply kong/07-opentelemetry.yaml
```

## Claude Desktop configuration

Same as [module 2](02-key-auth.md#claude-desktop-configuration) — Gateway
base URL `http://localhost:8000/anthropic`, **Gateway API key** =
`KONG_CONSUMER_API_KEY`, auth scheme `x-api-key`, credential kind
`Static API key`. No OIDC fields involved.

## Verify

In Claude Chat, send an ordinary message — it should complete normally.
Then send one containing something that matches a deny pattern, e.g.:

```
My card number is 4111 1111 1111 1111, can you help me remember it?
```

That request should get blocked at the gateway (before Anthropic ever
sees it) rather than completing — `ai-prompt-guard` returns an error
response instead of proxying through to `ai-proxy-advanced`.
