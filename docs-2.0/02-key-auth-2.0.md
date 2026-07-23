# 02 — Key auth (AI Gateway 2.0 track)

> **Status (2026-07-23, verified against `kongctl` 1.6.0 / Fel Tech org / `us.api.konghq.tech`):**
> ✅ **Control-plane side fully live-verified**: `kongctl apply` created the
> `claude-key-auth` `ai_gateway_policy` (type `key-auth`, `global: true`),
> the `claude-desktop` `ai_gateway_consumer`, and its
> `claude-desktop-api-key` credential — all confirmed present server-side
> via direct `GET` calls to the Konnect API, not just the `kongctl` plan. A
> second `kongctl diff` shows zero drift. Getting there required correcting
> two real, live-discovered schema mismatches from the task brief's literal
> YAML — see "vs. the brief" below; the bigger of the two
> (`key-auth` cannot attach to a model at all) changes the mechanism this
> module uses, not just field names.
> ❌ **Data-plane side NOT verified** — same constraint as module 1: no
> Docker access in this sandbox, and AI Gateway 2.0 has no serverless/
> Konnect-hosted proxy URL for this control plane (`proxy_urls: []`,
> confirmed live). The brief's Step 4 (curl the route with/without a key,
> 3+ times each) could not be run. `scripts/verify-2.0.sh 02-key-auth` is
> written and ready for the first real hybrid-DP run, but has not itself
> been executed.
> ⚠️ **Credential secret value NOT retrievable after creation** — a real,
> confirmed limitation of this beta API, not an oversight: see "The
> credential-value gap" below. `KONGCTL_CONSUMER_API_KEY` in `.env.2.0`
> cannot be wired into `kongctl apply` the way the brief assumed; a
> Docker-enabled operator needs to create the credential's secret value
> out-of-band, via a direct Konnect API call, before `scripts/verify-2.0.sh
> 02-key-auth` can pass.

## What this adds

A global `key-auth` policy (`claude-key-auth`) on the `claude-ai-gateway`
control plane, plus a Consumer (`claude-desktop`) and one credential
(`claude-desktop-api-key`) for it to authenticate against. The
`claude-chat` model from module 1 is unchanged in this file except that it
now sits behind this policy (see "the big finding" below for exactly how).

## vs. 1.x

| | 1.x (`kong/02-key-auth.yaml`) | 2.0 (`kong-2.0/02-key-auth.yaml`) |
|---|---|---|
| Auth mechanism | `key-auth` plugin declared globally in `plugins:` (applies to every Route in the control plane) | `key-auth` `ai_gateway_policy` with `global: true` (applies to every route this AI Gateway control plane compiles) |
| Consumer | `consumers:` entry with `keyauth_credentials: [{key: ...}]` — key value set inline | `ai_gateway_consumer` (`type: api-key`) with a nested `credentials:` entry — **key value is NOT settable inline**, Konnect auto-generates it (see below) |
| Where auth "attaches" | Implicit — a global plugin applies everywhere by default | Explicit `global: true` on the policy. **Not** the model's `policies:` list — see the big finding below |

**The big finding — this is the important structural correction, not a
field-rename:** the task brief's Step 1 (and this module's own first
draft) declared `key-auth` as a policy referenced from the model's
`policies:` list — mirroring how the brief describes OIDC attaching in a
later module. That shape does **not work**. Applying it produces a real,
live `400`:

```
Bad Request: ai_gateway_model.policies: policy "claude-key-auth" of type
"key-auth" is not supported for scope "models"
```

`key-auth` (and presumably other credential-verification policy types —
**not confirmed, see caveat below**) has a server-enforced allowed-scope
list, and `"models"` isn't on it for `key-auth`. The working mechanism is
`global: true` on the policy itself, with **no** `policies:` entry on the
model. A global policy is enforced across the *entire* control plane, not
just one model. In this repo that has the same practical effect as gating
`claude-chat` specifically, because `claude-chat` is currently the only
model on `claude-ai-gateway` — but it means a future module that adds a
second model to this same control plane would, by default, also be gated
by this policy. That's a real design difference from what the model's
`policies:` field name suggests it should do, and from how the brief
described the OIDC module (Task 4) attaching auth the same way. **Whether
`openid-connect` (or other policy types) share this "models"-scope
restriction was not tested in this module** — confirm it directly via
`kongctl explain ai_gateways.policies --extended` and a real apply before
assuming either way for a future OIDC module; don't propagate this
finding as gospel beyond `key-auth` itself.

## The credential-value gap

The brief's Step 2 assumed a consumer credential could carry a key value
set from an env var:

```yaml
consumers:
- ref: claude-desktop
  name: claude-desktop
  key_auth_credentials:
  - key: "${{ env "KONGCTL_CONSUMER_API_KEY" }}"
```

Neither the field name nor the mechanism exists. Confirmed via `kongctl
explain ai_gateways.consumers --extended` and `kongctl explain
ai_gateways.consumers.credentials --extended`: the real nested field is
`credentials:` (generic, not auth-type-specific), and each entry's only
fields are `ref`/`ai_gateway_consumer`/`name`/`type`/`display_name`/`ttl`/
`labels`/`managed_by` — **no `key`, `api_key`, or `config` field at all**
(`additionalProperties: false` on the schema blocks anything else).

The raw Konnect API *does* support a custom value — the
`create_ai_gateway_consumer_credential` endpoint accepts an optional
`api_key` string ("If not provided, then the key will be auto generated by
the server and returned in the response") — but `kongctl`'s declarative
surface has no field to pass it through. Applying this module's YAML lets
Konnect auto-generate the key. Worse for testability: **the generated key
is only ever returned in the create response** — confirmed live by `GET`
on both the credential list and the credential-by-id endpoints after
creation, neither of which include the key value in their response body.
`kongctl apply`'s own terminal output doesn't surface it either (checked
the actual apply output from this session — only metadata fields are
printed). So once `kongctl apply` has run, the key is genuinely gone from
this side unless you captured it some other way at creation time.

**For a future Docker-enabled run that needs a known, testable key**,
create the credential directly against the Konnect API instead of (or in
addition to, after deleting the kongctl-managed one) `kongctl apply`:

```bash
set -a; source .env.2.0; set +a
GWID=<ai-gateway id, e.g. from GET /v1/ai-gateways>
CID=<claude-desktop consumer id, from GET /v1/ai-gateways/$GWID/consumers>
curl -s -X POST \
  -H "Authorization: Bearer ${KONGCTL_DEFAULT_KONNECT_PAT}" \
  -H 'content-type: application/json' \
  "${KONNECT_AIGW2_BASE_URL}/v1/ai-gateways/${GWID}/consumers/${CID}/credentials" \
  -d "{\"name\":\"claude-desktop-api-key-manual\",\"display_name\":\"Claude Desktop API Key (manual)\",\"type\":\"api-key\",\"api_key\":\"${KONGCTL_CONSUMER_API_KEY}\"}"
```

This credential is **not** tracked by `kongctl` (it lacks the
`KONGCTL-namespace`/ref labels kongctl uses to recognize resources it
owns) — a subsequent `kongctl apply` won't touch it, but it also won't
show up in `kongctl diff`. Treat it as an out-of-band operational
credential for testing, separate from the declaratively-managed
`claude-desktop-api-key` resource this module's YAML creates.

## `kongctl explain`/live-schema corrections vs. the task brief

Confirmed via `kongctl explain ai_gateways.policies --extended`, `kongctl
explain ai_gateways.consumers --extended`, `kongctl explain
ai_gateways.consumers.credentials --extended`, `kongctl explain
ai_gateways.models --extended`, the Konnect MCP tool's
`create_ai_gateway_policy`/`create_ai_gateway_consumer`/
`create_ai_gateway_consumer_credential` input+output schemas, and a real
`kongctl apply` 400:

1. **`key-auth` cannot be attached via a model's `policies:` list** — see
   "the big finding" above. `global: true` on the policy is the mechanism
   that actually works.
2. **`ai_gateways.consumers[].key_auth_credentials:`** (the brief's field
   name) **doesn't exist.** The real field is `credentials:` — see "the
   credential-value gap" above for the full divergence, including that no
   field in it can hold the actual secret value.
3. **Consumer/credential `type` is `api-key`**, not a made-up
   `key-auth`-shaped value (confirmed via the Konnect API's
   `create_ai_gateway_consumer` output schema: `type: enum ["api-key",
   "oauth"]`). The policy's `type: key-auth` (the Kong 3 plugin-name
   equivalent) and the consumer/credential's `type: api-key` are two
   independent fields that happen to look similar.
4. **No `_external`/`selector` field on `ai_gateways`** (same finding as
   module 1) — this file re-declares the same `ai_gateway` so `kongctl`
   matches the live control plane by namespace+ref.
5. **`hide_credentials`** was left `true` (the safer default, matching
   1.x's implicit `key-auth` default) rather than the brief's literal
   `false` — the brief's own note said to keep it `true` "unless live
   testing shows a reason not to," and no live testing was possible here
   (no DP) to show otherwise.

## Apply it

```bash
set -a; source .env.2.0; set +a
kongctl diff -f kong-2.0/02-key-auth.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}"
kongctl apply -f kong-2.0/02-key-auth.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}" --auto-approve
```

**Real output from this session** (first attempt, before the `global:
true` fix — kept here because the failure IS the finding):

```
[4/4] [namespace: kong-claude-ai-gateway-2-0] Updating ai_gateway_model: claude-chat... ✗ Error:
failed to update AI Gateway model ai_gateway_model "claude-chat" in namespace "kong-claude-ai-gateway-2-0":
{"status":400,"title":"Bad Request", ...
"detail":"Bad Request: ai_gateway_model.policies: policy \"claude-key-auth\" of type \"key-auth\" is not
supported for scope \"models\""}
```

**After the fix** (policy `global: true`, no `policies:` on the model):

```
RESOURCE CHANGES
Namespace: kong-claude-ai-gateway-2-0 (1 changes: 1 update)
  ai_gateway_policy (1 resources): ~ claude-key-auth
[1/1] Updating ai_gateway_policy: claude-key-auth... ✓
Executed 1 changes.
```

(The first partial apply had already created `claude-key-auth`,
`claude-desktop`, and `claude-desktop-api-key` before the model-update step
failed — this second apply only needed to flip `global` on the
already-created policy.)

A following `kongctl diff`: `No changes detected. Konnect is up to date.`

**Confirmed live via the Konnect API**, not just the `kongctl` plan:

```json
// GET /v1/ai-gateways/{id}/policies
{"name": "claude-key-auth", "type": "key-auth", "global": true, "enabled": true,
 "config": {"key_names": ["x-api-key"], "hide_credentials": true, "key_in_header": true,
            "key_in_query": true, "key_in_body": false, ...}}

// GET /v1/ai-gateways/{id}/consumers
{"name": "claude-desktop", "type": "api-key", "policies": []}
```

Note `consumers[].policies` is `[]` (empty) — the consumer isn't linked to
the policy explicitly either; `global: true` on the policy is what does
the actual gating, consumer-independent. `GET
.../consumers/{id}/credentials` and `GET
.../consumers/{id}/credentials/{id}` were both checked and confirm the
credential exists (`name`, `type`, `display_name`, timestamps) — with no
`api_key` field in either response, per "the credential-value gap" above.

## Live-verify reject/accept paths — NOT achievable here

Same constraint as module 1: no Docker, no serverless proxy URL for this
control plane. `scripts/verify-2.0.sh 02-key-auth` is written (no-key →
expect `401`, valid-key → expect `200` with `"role":"assistant"` in the
body, both against `"model":"claude-chat"` per module 1's alias
correction) but has not been run — there is no reachable
`http://localhost:8010/anthropic` in this environment. Do not treat this
module as having verified the reject/accept behavior; that verification
still has to happen against a real hybrid DP, and per "the credential-value
gap" above, needs a manually-created credential with a known `api_key`
value first.

## Claude Desktop configuration

Not attempted — same reason as module 1 (no reachable proxy endpoint in
this environment). Once a DP is up, the Consumer's real API key (created
per "the credential-value gap" above, since kongctl can't set one) goes in
Claude Desktop's API key field.
