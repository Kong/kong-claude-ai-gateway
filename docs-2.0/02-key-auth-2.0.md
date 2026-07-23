# 02 — Key auth (AI Gateway 2.0 track)

> **Status (2026-07-23, corrected and re-verified against `kongctl` 1.6.0 /
> Fel Tech org / `us.api.konghq.tech`):**
> ⚠️ **This module was rebuilt from an earlier, incomplete design.** The
> original version of this file modeled key-auth as a `policies:` entry
> with `global: true`, because a real, live `kongctl apply` 400 showed
> `key-auth` cannot attach to a model via `policies:`. That 400 is still
> real (re-confirmed this pass) — but the conclusion drawn from it (key-auth
> can therefore ONLY ever be global, unlike OIDC) was wrong. `kongctl
> explain ai_gateways.identity_providers --extended` shows `type: string
> required allowed: key-auth|openid-connect` — key-auth can ALSO be modeled
> as an `identity_providers` entry, attached per-model via
> `access.identity_providers`, exactly like OIDC. See "The correction"
> below for the full trail.
> ✅ **Control-plane side live-verified via `kongctl diff` against the real
> Konnect API** (schema validation, not a mutating apply — see "Why `diff`,
> not `apply`, this pass" below): a `claude-key-auth`
> `ai_gateway_identity_provider` (`type: key-auth`) attaches cleanly to
> `claude-chat` via `access.identity_providers`, with zero validation
> error. The consumer/credential mechanism (`claude-desktop` +
> `claude-desktop-api-key`) is unchanged from the original design — see
> "The credential-value gap" below, still accurate as written.
> ❌ **Data-plane side NOT verified** — same constraint as module 1: no
> Docker access in this sandbox, and AI Gateway 2.0 has no serverless/
> Konnect-hosted proxy URL for this control plane (`proxy_urls: []`,
> confirmed live in the original pass). `scripts/verify-2.0.sh 02-key-auth`
> is written and ready for the first real hybrid-DP run, but has not itself
> been executed.
> ⚠️ **Credential secret value NOT retrievable after creation** — a real,
> confirmed limitation of this beta API, not an oversight: see "The
> credential-value gap" below. Unchanged by this correction — the
> credential mechanism is the same regardless of how the gate attaches.

## What this adds

A `key-auth` `identity_providers` entry (`claude-key-auth`) attached to the
`claude-chat` model via `access.identity_providers`, plus a Consumer
(`claude-desktop`) and one credential (`claude-desktop-api-key`) for it to
authenticate against.

## The correction (2026-07-23)

This module was originally built, then reviewed by a Kong SE with
hands-on AI Gateway 2.0 experience, who caught that its "key-auth is
global-only" conclusion was based on investigating only one attachment
path (`policies:`) and stopping there, without checking whether a second
path existed — which it does.

**What was real and is still real:** `key-auth` genuinely cannot attach to
a model via the model's `policies:` list. A live `kongctl apply` (re-run
this pass) still 400s the same way:

```
Bad Request: ai_gateway_model.policies: policy "claude-key-auth" of type
"key-auth" is not supported for scope "models"
```

**What was incomplete:** stopping at that 400 and concluding key-auth can
*only* be `global: true` — without checking whether `key-auth` could be
declared as an `identity_providers` entry instead of a `policies` entry.
It can. Confirmed via `kongctl explain ai_gateways.identity_providers
--extended`:

```
- type: string required allowed: key-auth|openid-connect
```

`identity_providers` is a resource kind of its own
(`ai_gateway_identity_providers[]`), separate from `policies`
(`ai_gateway_policies[]`) — module 3's original investigation had already
found this for `openid-connect` and even noted in passing that "`key-auth`
can ALSO be modeled as an identity provider," but that observation was
never acted on here. Models have a dedicated `access.identity_providers:
array[string]` field for attaching entries of *either* type
(`kongctl explain ai_gateways.models --extended`), independent of the
model's separate `policies: array[string]` field that rejects `key-auth`.

**The corrected framing:** key-auth and OpenID Connect are consistent, not
different, once modeled the right way. Both are `identity_providers`
resources; both attach to a model via `access.identity_providers`; both
scope per-model. The only thing that is genuinely global-only is
`key-auth` declared under `policies:` — a real, distinct attachment path
that this module simply doesn't use.

## `identity_providers`, `type: key-auth` — the config shape

Confirmed via `kongctl explain ai_gateways.identity_providers --extended`.
The full `config` field list is shared across both `type` values (fields
not relevant to the chosen type are simply unused):

```
- config: object required
  - hide_credentials: boolean optional
  - key_in_body: boolean optional
  - key_in_header: boolean optional
  - key_in_query: boolean optional
  - key_names: array[string] optional
  - auth_methods: array[string] optional          (openid-connect)
  - cache_tokens_salt: string optional             (openid-connect)
  - client_id: array[string] optional              (openid-connect)
  - client_secret: array[string] optional          (openid-connect)
  - consumer_claims: array[array[string]] optional (openid-connect)
  - consumer_optional: boolean optional            (openid-connect)
  - issuer: string optional                        (openid-connect)
  - scopes: array[string] optional                 (openid-connect)
  - ssl_verify: boolean optional                   (openid-connect)
```

For `type: key-auth`, only `key_names` and `hide_credentials` are set —
the same two fields the earlier `policies:`-based version used. The
credential-verification config itself didn't change; only where it's
declared (`identity_providers` instead of `policies`) and how it attaches
(`access.identity_providers` on the model instead of `global: true` on the
policy) changed.

**Credential storage — confirmed unchanged, not a new mechanism.**
Neither the `identity_providers` schema nor the `consumers`/`credentials`
schema has any field linking a credential to a specific identity provider
(no `identity_provider`/`identity_provider_ref` anywhere, confirmed via
`kongctl explain ai_gateways.identity_providers --extended`, `kongctl
explain ai_gateways.consumers --extended`, and `kongctl explain
ai_gateways.consumers.credentials --extended`). Credentials still live on
the `ai_gateway_consumers[].credentials[]` resource, same as the original
`policies`-based design — switching the *attachment* mechanism did not
introduce or remove a credential-storage mechanism.

## Why `diff`, not `apply`, this pass

The live control plane this repo has been testing against
(`kong-claude-ai-gateway-2-0` in the Fel Tech org) already has modules 4/5/7's
real policies (`team-model-listing`, `claude-token-rate-limit`,
`claude-otel-tracing`) attached to `claude-chat`, applied by earlier tasks
in this branch. A `kongctl diff` against a test file that redeclares
`claude-chat` WITHOUT those policies' `policies:` list showed them going
to `null` — i.e., re-applying an earlier module's file over a
later-mutated live model would wipe policies added by later modules,
because `kongctl apply` fully replaces a redeclared resource's own list
fields (`model.policies`, `model.access.identity_providers`) with
whatever the file says, even though it does NOT delete *separate*
top-level resources (like an unreferenced `identity_providers` or
`policies` entry) that the file omits entirely. This is a real,
newly-observed nuance in kongctl's replace-vs-omit behavior, worth
flagging for whoever next tests against this shared control plane.

Given that, this pass validated the corrected `key-auth` schema and
attachment path via `kongctl diff` only — which round-trips through the
real Konnect API and surfaces the same 400s/validation errors an `apply`
would — rather than running a mutating `apply` that could have stripped
modules 4/5/7's live policies from the shared control plane. This is a
fresh `kongctl diff -f kong-2.0/02-key-auth.yaml` run (2026-07-23) against
this file exactly as committed — ref `claude-key-auth`, display name
"Claude Key Auth":

```
Plan: 1 to add, 1 to change, 1 to destroy

=== Namespace: kong-claude-ai-gateway-2-0 ===
+ [1:c:ai_gateway_identity_provider:claude-key-auth] ai_gateway_identity_provider "claude-key-auth" will be created
  display_name: "Claude Key Auth"
  config:
    hide_credentials: true
    key_names:
      [0]: "x-api-key"
  name: "claude-key-auth"
  type: "key-auth"

- [2:d:ai_gateway_identity_provider:okta-oidc] ai_gateway_identity_provider "okta-oidc" will be deleted
  depends on: [1:c:ai_gateway_identity_provider:claude-key-auth]

~ [3:u:ai_gateway_model:claude-chat] ai_gateway_model "claude-chat" will be updated
  access: map[identity_providers:[okta-oidc]] → map[identity_providers:[claude-key-auth]]
  policies: [claude-otel-tracing team-model-listing claude-token-rate-limit] → null
  depends on: [2:d:ai_gateway_identity_provider:okta-oidc]
```

Zero validation error on the `identity_providers` creation or the model
update — confirming the corrected schema and attachment path both work
against the real API. (The `access:` and `policies:` diff lines show the
swap from the live control plane's *current, already-advanced* state —
module 3's `okta-oidc` attached and modules 4/5/7's policies live on
`claude-chat` from earlier tasks in this branch — not a design claim
about this module's own starting point, which in a fresh build starts
with no `access.identity_providers` and no `policies` at all. This is the
exact, concrete "apply in isolation strips later modules' state" risk
called out in "Apply it" below: this `diff` plan alone would delete the
`okta-oidc` identity provider outright and null out all three live
policies if applied against this control plane as-is.)

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
`kongctl apply`'s own terminal output doesn't surface it either. So once
`kongctl apply` has run, the key is genuinely gone from this side unless
you captured it some other way at creation time.

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

Confirmed via `kongctl explain ai_gateways.identity_providers --extended`,
`kongctl explain ai_gateways.policies --extended`, `kongctl explain
ai_gateways.consumers --extended`, `kongctl explain
ai_gateways.consumers.credentials --extended`, `kongctl explain
ai_gateways.models --extended`, and real `kongctl diff`/`apply` calls
(both the original `policies:` 400 and this correction's clean
`identity_providers` plan):

1. **`key-auth` cannot be attached via a model's `policies:` list** — real,
   confirmed, unchanged by this correction. `identity_providers` +
   `access.identity_providers` is the corrected, working, per-model
   mechanism — see "The correction" above.
2. **`ai_gateways.consumers[].key_auth_credentials:`** (the brief's field
   name) **doesn't exist.** The real field is `credentials:` — see "the
   credential-value gap" above for the full divergence, including that no
   field in it can hold the actual secret value.
3. **Consumer/credential `type` is `api-key`**, not a made-up
   `key-auth`-shaped value (confirmed via the Konnect API's
   `create_ai_gateway_consumer` output schema: `type: enum ["api-key",
   "oauth"]`). The identity provider's `type: key-auth` (the Kong 3
   plugin-name equivalent) and the consumer/credential's `type: api-key`
   are two independent fields that happen to look similar.
4. **No `_external`/`selector` field on `ai_gateways`** (same finding as
   module 1) — this file re-declares the same `ai_gateway` so `kongctl`
   matches the live control plane by namespace+ref.
5. **`hide_credentials`** is left `true` (the safer default, matching
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

Note for anyone applying this against the same shared Fel Tech control
plane this repo has been testing against: if the live model already has
module 3+'s policies/identity-providers attached (e.g. from an earlier
task's real applies), applying THIS file alone will reset
`access.identity_providers` to `[claude-key-auth]` only, dropping
`okta-oidc` from the live model (though not deleting the `okta-oidc`
identity provider record itself — see "Why `diff`, not `apply`" above).
That's expected if you're intentionally walking the modules in order from
a clean state; if you're re-testing against an already-advanced live
control plane, apply `kong-2.0/07-opentelemetry.yaml` (the latest
cumulative file) instead, or expect this diff.

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
