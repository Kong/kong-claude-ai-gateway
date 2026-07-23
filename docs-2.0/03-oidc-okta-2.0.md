# 03 — OIDC + Okta (AI Gateway 2.0 track)

> **Status (2026-07-23, verified against `kongctl` 1.6.0 / Fel Tech org / `us.api.konghq.tech`):**
> ✅ **Control-plane side fully live-verified, twice.** `kongctl apply`
> created the `okta-oidc` `ai_gateway_identity_provider` (type
> `openid-connect`) and updated `claude-chat`'s `access.identity_providers`
> to reference it. A follow-up `kongctl diff`: `No changes detected. Konnect
> is up to date.` The model's `access` field was independently confirmed
> server-side via a direct `GET /v1/ai-gateways/{id}/models` call — see
> "Confirmed live" below.
> ✅ **This module's central open question — resolved, twice over.** Module
> 2 originally left open whether `openid-connect` shares `key-auth`'s
> "policy scope=models not supported, must be `global: true`" restriction.
> It does **not**, because `openid-connect` isn't attached via `policies:`
> at all — it's a dedicated `identity_providers` resource type with its own
> model-scoped `access.identity_providers` attachment field. See "The
> central finding" below for the full trail.
> ⚠️ **2026-07-23 correction: module 2's own "global-only" framing was
> itself incomplete**, and this doc originally repeated it uncritically.
> `key-auth` CAN also be modeled as an `identity_providers` entry
> (`kongctl explain ai_gateways.identity_providers --extended`:
> `type: string required allowed: key-auth|openid-connect`) — this doc's
> "Net effect" bullet below had already spotted that closed enum but
> stopped short of drawing the conclusion. `kong-2.0/02-key-auth.yaml` has
> since been rebuilt to use it, which changes this module's own "does not
> delete" section below: the swap this module performs is now a literal,
> same-resource-kind replacement (`identity_providers` → `identity_providers`
> on the same `access.identity_providers` field), not a cross-mechanism one.
> See the updated "`kongctl apply` does not delete module 2's resources"
> section for what that changes.
> ✅ **Real Okta access token minted** — via the `client_credentials` grant
> against a confidential (M2M) app in the SE demo Okta tenant, after two
> other grant attempts were tried and rejected with informative,
> real errors. See "Minting a real Okta token" below — this section also
> covers what that means for `scripts/verify-2.0.sh 03-oidc-okta`, which
> needs a *different* grant (interactive `authorization_code`) than the one
> that was actually mintable here, because of `auth_methods` and Okta app
> policy constraints uncovered live.
> ❌ **End-to-end request-through-Kong NOT verified** — same constraint as
> modules 1/2: no Docker access in this sandbox, and this control plane has
> no serverless/Konnect-hosted proxy URL (`proxy_urls: []`, confirmed
> live). The brief's Step 4 (batch of 8+ requests against a real hybrid DP,
> recording the pass rate) **could not be run** — there is no reachable
> `http://localhost:8010/anthropic` in this environment. Do not read
> anything below as claiming that batch ran. `scripts/verify-2.0.sh
> 03-oidc-okta` is written and ready for a future Docker-enabled run, but
> has not itself been executed.
> ❌ **Issue 22 (openid-connect non-determinism against a real external IdP,
> vs. Kong Identity) is NOT resolved by this module** — it requires sending
> real traffic through Kong's data plane, which this environment cannot do.
> Nothing here should be read as evidence either way on that question.

## What this adds

An `okta-oidc` `identity_providers` entry (type `openid-connect`) on the
`claude-ai-gateway` control plane, and `claude-chat`'s `access` field now
points at it (`access.identity_providers: [okta-oidc]`). This is a
**replacement** for module 2's auth, matching 1.x's own module 3 precedent
(`kong/03-oidc-okta.yaml` drops the key-auth plugin entirely in favor of
`openid-connect` — confirmed by reading that file: its `plugins:` list has
no `key-auth` entry, only `openid-connect` +
`ai-proxy-advanced`/`request-transformer-advanced`) — `claude-chat`'s
`access.identity_providers` is now the model's sole auth attachment.

As of the 2026-07-23 correction to `kong-2.0/02-key-auth.yaml`, module 2's
key-auth gate is ALSO an `identity_providers` entry (`claude-key-auth`,
`type: key-auth`), so this replacement is now a literal same-field swap —
this module's `access.identity_providers: [okta-oidc]` directly replaces
module 2's `access.identity_providers: [claude-key-auth]` on the same
model. That's a materially cleaner story than the original version of this
doc had: previously, module 2's gate was a `policies`-attached `global:
true` policy — a different resource kind entirely from this module's
`identity_providers`-attached OIDC — so there was no single field a
"swap" could act on, and the old `claude-key-auth` global policy stayed
live (gating the whole control plane) regardless of what this module did.
See "`kongctl apply` does not delete module 2's resources" below for what
changes and what still doesn't.

## The central finding: `identity_providers` vs. `policies`

Module 2's biggest surprise was that `key-auth` **cannot** attach to a
model at all via `policies:` — the Konnect API rejects it with a 400
("policy ... not supported for scope 'models'"), and the only way to make
it apply is `global: true` on the policy, gating the whole control plane.
Module 2 explicitly left open whether `openid-connect` shares that
restriction.

**It does not — because `openid-connect` isn't a `policies:`-attached
resource type at all in this schema.** Confirmed via `kongctl explain
ai_gateways.identity_providers --extended` and `kongctl explain
ai_gateways.models --extended`:

- `identity_providers` is its own **top-level/child resource type**
  (`ai_gateway_identity_providers[]`), completely separate from `policies`
  (`ai_gateway_policies[]`). Its `type` field is a closed enum:
  `key-auth|openid-connect` — meaning `key-auth` can *also* be modeled as
  an identity provider (a second, different way to declare key-auth,
  distinct from module 2's `policies:`-based one), but this module only
  uses the `openid-connect` variant.
- Models have a **dedicated field**, `access.identity_providers:
  array[string]`, sitting alongside `access.acls` in the model's `access`
  object — genuinely separate from the model's `policies: array[string]`
  field that module 2 found rejects `key-auth`.
- The brief's assumed **attachment** shape (`access.identity_providers` on
  the model, referencing an `identity_providers[].ref`) is **confirmed
  correct as literally written**. The brief's assumed **`openid-connect`
  config** shape (Step 1), however, was NOT fully correct: `login_action`
  and `redirect_uri` — both in the brief and in the 1.x/decK track's own
  `kong/03-oidc-okta.yaml` (`login_action: redirect`, a `redirect_uri:`
  list) — do not exist on this resource. Confirmed via `kongctl explain
  ai_gateways.identity_providers --extended`: the full field list for
  `config` is `hide_credentials`, `key_in_body`, `key_in_header`,
  `key_in_query`, `key_names`, `auth_methods`, `cache_tokens_salt`,
  `client_id`, `client_secret`, `consumer_claims`, `consumer_optional`,
  `issuer`, `scopes`, `ssl_verify` — no `login_action`, no `redirect_uri`.
  Both fields are dropped from `kong-2.0/03-oidc-okta.yaml`, documented
  there and in "Redirect URI for interactive login" below, instead of
  silently omitted.
- **Net effect:** `identity_providers`-based auth attaches **per-model**,
  via `access.identity_providers` — for BOTH `type: openid-connect` (this
  module) and `type: key-auth` (module 2, since corrected to use this same
  mechanism — see the 2026-07-23 note in the status banner above). They are
  consistent, not different. The thing that's actually global-only is
  `key-auth` declared under `policies:` instead — a distinct, and now
  unused, attachment path. `okta-oidc` here is referenced only from
  `claude-chat`; a hypothetical second model on this same control plane
  would **not** automatically inherit this gating, and neither would it
  automatically inherit module 2's `claude-key-auth` identity provider
  (both are model-scoped now).
- **Not independently re-tested:** whether `openid-connect` would also be
  rejected if declared under `policies:` (the brief's own warning that
  doing so "silently zeroes the config"). This module never attempted that
  path — it used the dedicated, working `identity_providers` mechanism
  from the start, so the brief's specific "silently zeroes" claim about
  `policies:` remains unconfirmed by this module. Don't cite this doc as
  having verified that failure mode; it only verified the working path.

## Two more real, live findings (not in the brief)

**1. `${{ env "..." }}` does not work with `kongctl`.** The brief's literal
Step 1 YAML used this decK-style tag (`kong/03-oidc-okta.yaml`, the
1.x/decK track, genuinely does support it — decK is a different tool with
its own template engine). Confirmed live with an isolated one-field test
(set `claude-ai-gateway`'s `description` to `${{ env "TEST_TAG_VALUE" }}`,
exported `TEST_TAG_VALUE`, ran `kongctl diff`):

```
~ [1:u:ai_gateway:claude-ai-gateway] ai_gateway "claude-ai-gateway" will be updated
  description: "AI Gateway 2.0 control plane for kong-claude-ai-gateway" → "${{ env \"TEST_TAG_VALUE\" }}"
```

kongctl sends the literal tag string to the Konnect API, unexpanded. This
first surfaced as a real `400` when `issuer` still used this syntax:
`Bad Request: config.issuer: missing host in url` (because the unexpanded
tag text isn't a URL). This module can't sidestep the same way (there's no
path to create an `ai_gateway_identity_provider` outside kongctl's
ownership without fighting kongctl on every future apply), so instead:
`issuer`/`client_id`/
`client_secret`/`cache_tokens_salt` are all `{vault://ai-vault/<key>}`
references — the same mechanism modules 1/2 already use for the
Anthropic/AWS secrets. Confirmed `{vault://...}` is **not** touched by
kongctl either (it also passes through literally in the plan output), but
unlike the `env` tag, that's the *intended* behavior — it's resolved
server-side by Kong at runtime, not by kongctl at apply time. This means
the four Okta values have to be seeded into the `ai-vault` config store as
secrets before `kongctl apply` produces a *working* identity provider.
`scripts/00-bootstrap-konnect-2.0.sh` now seeds these automatically,
the same way it already seeds `anthropic-api-key`/`aws-*` — just set
`KONGCTL_OKTA_ISSUER`/`KONGCTL_OKTA_CLIENT_ID`/`KONGCTL_OKTA_CLIENT_SECRET`/
`KONGCTL_OIDC_CACHE_TOKENS_SALT` in `.env.2.0` before running the script and
it upserts `okta-issuer`/`okta-client-id`/`okta-client-secret`/
`oidc-cache-tokens-salt` into the config store (idempotent — safe to re-run,
never overwrites with an empty value).

(Note the underlying API's field name is `key`, not `name` — a real `400`
first pointed this out live: `property "name" is unsupported, key
[required]: property "key" is missing`, which is why the bootstrap script's
`seed_secret` helper posts `{"key": ..., "value": ...}`.)

**2. `config.cache_tokens_salt` is required for `type: openid-connect`.**
`kongctl explain ai_gateways.identity_providers --extended` lists this
field without flagging it required, but a real `kongctl apply` failed with
`the current SDK rejected the payload; verify the resource fields with
kongctl explain` when it was omitted. Cross-checked via the Konnect MCP
tool's `create_ai_gateway_identity_provider` output schema, whose
`openid-connect` variant explicitly lists `"required": ["cache_tokens_salt"]`
on `config`. `kong-2.0/03-oidc-okta.yaml` sets it via
`{vault://ai-vault/oidc-cache-tokens-salt}`, in the spirit of 1.x's
`OIDC_CACHE_TOKENS_SALT` var.

## `kongctl apply` does not delete module 2's resources — a brief correction

The brief describes `kongctl apply` as having "sync semantics" that would
delete module 2's now-unused `claude-key-auth`/`claude-desktop`/
`claude-desktop-api-key`. **This is not how kongctl works, confirmed live**
via `kongctl apply konnect --help` / `kongctl sync konnect --help`:
`apply` is explicitly documented as "Execute a plan to create new
resources and update existing ones. **Never deletes resources.**" Deletion
is a *separate* command, `kongctl sync`, and only for resources that a
given sync run's file set actually covers. Running `kongctl apply -f
kong-2.0/03-oidc-okta.yaml` (as this doc's own "Apply it" section does)
**leaves module 2's `claude-key-auth`/`claude-desktop`/
`claude-desktop-api-key` resources fully intact server-side** — they are
not removed. Retiring them fully would still require a `kongctl sync` run
covering the whole `kong-2.0/` directory in one pass — not run here, since
it would also touch every other module's resources and wasn't this task's
scope.

**What the 2026-07-23 correction to module 2 changes here, and why it
matters more than the leftover record:** with module 2 rebuilt to use
`identity_providers` (same resource kind as this module's `okta-oidc`)
instead of a `policies`+`global: true` policy, this module's own
`access.identity_providers: [okta-oidc]` re-declaration performs a real,
literal swap ON THE MODEL — `claude-chat`'s `access.identity_providers`
goes from `[claude-key-auth]` to `[okta-oidc]` via a single field update,
the same field, one value replacing another. The old `claude-key-auth`
**identity provider record** can still linger server-side after this
module's apply (same "apply never deletes" behavior as always), but
because it's no longer referenced by ANY model's
`access.identity_providers`, it doesn't gate anything — an orphaned
`identity_providers` entry is inert.

This is a fundamentally different situation from the original design this
doc described, where `claude-key-auth` was a `policies`-attached
`global: true` **policy** — a policy scoped to the entire control plane
regardless of which model(s) it has, meaning it stayed *actively enforced*
after this module's apply, not just present-but-unused. That was the real
double-gating bug: **both** `claude-key-auth` (global, gating everything)
**and** `okta-oidc` (model-scoped, gating `claude-chat`) were
simultaneously enforced, and a request would have needed to satisfy both.
With both mechanisms now modeled as `identity_providers` and swapped on
the same `access.identity_providers` field, that whole class of problem
goes away: the leftover is a harmless unused record, not a second live
gate. A `kongctl sync` (or manual `delete_ai_gateway_identity_provider`
call) is still the right way to fully clean up the orphaned record for
tidiness, but it's no longer required for correctness the way retiring the
old global policy was.

## Minting a real Okta token

The task gave five Okta values (`OKTA_AUTH_SERVER`, `SE_DEMO_CLIENT_ID`,
`SE_DEMO_SECRET`, `SE_DEMO_SUBJECT_CLIENT_ID`, `SE_DEMO_SUBJECT_SECRET`,
`OKTA_TEST_USER`, `OKTA_TEST_USER_PWD`) without saying which grant type to
use. Investigated live against `${OKTA_AUTH_SERVER}/v1/token`, reading
Okta's own error responses at each step:

1. **`client_credentials` with `SE_DEMO_CLIENT_ID`** → `400
   unauthorized_client`: `"Configured grant types: [urn:ietf:params:oauth:
   grant-type:token-exchange, password, authorization_code]"`. This client
   doesn't support `client_credentials` at all — and its own error told us
   exactly what it does support.
2. **`password` grant with `SE_DEMO_CLIENT_ID`** (a public/native client —
   `SE_DEMO_SECRET` is genuinely an empty string in the secrets file, not
   a placeholder omission; matches `docs/okta-setup.md`'s description of
   Native Application/PKCE apps not getting a real secret) → first attempt
   gave `400 invalid_grant: "The credentials provided were invalid"`, but
   that was a **false negative from a curl encoding bug**: `-d` doesn't
   URL-encode field values, and `OKTA_TEST_USER` contains a `+`
   (`fel+user1@konghq.com`) — sent raw, `application/x-www-form-urlencoded`
   parsing turns `+` into a space server-side, corrupting the username.
   Switching to `--data-urlencode` fixed the encoding and produced a
   **different, more informative** `400`: `invalid_grant: "Resource owner
   password credentials authentication denied by sign on policy."` — the
   grant type and credentials are now confirmed accepted as far as Okta's
   token endpoint is concerned; a separate Okta **org-level sign-on
   policy** is blocking ROPC outright (independent of anything this
   module's config controls).
3. **`password` grant with `SE_DEMO_SUBJECT_CLIENT_ID`** (confidential,
   client-secret auth) → `400 unauthorized_client`: `"Configured grant
   types: [urn:ietf:params:oauth:grant-type:token-exchange,
   client_credentials]"`. This client doesn't support `password` at all —
   it's the token-exchange/M2M counterpart to `SE_DEMO_CLIENT_ID`'s
   user-facing grants, consistent with the "SUBJECT" naming (an Okta
   Token Exchange pattern: get a subject token via one client, exchange it
   via another).
4. **`client_credentials` with `SE_DEMO_SUBJECT_CLIENT_ID` + `scope=openid`**
   → `400 invalid_scope`: `"Cannot request 'openid' scopes using client
   credentials"` — expected; OIDC scopes require a real user, `openid`
   isn't valid for M2M grants.
5. **`client_credentials` with `SE_DEMO_SUBJECT_CLIENT_ID`, no scope** →
   **`200`**, a real access token (`RS256`, `expires_in: 3600`,
   `aud: fel-test-ai-gateway`, `scp: ["se_scope"]`, `cid` matching
   `SE_DEMO_SUBJECT_CLIENT_ID`). **This is the token that was successfully
   minted for this module's live verification.**

**What this means for `scripts/verify-2.0.sh 03-oidc-okta`:** the token
minted above is real and valid, but it's an M2M `client_credentials` token
with `scope: se_scope` and no `openid`/ID-token claims. This module's
`okta-oidc` identity provider's `auth_methods` is `[authorization_code,
session, bearer]` — it does not list `client_credentials`. Whether Kong's
`openid-connect` plugin would accept this specific token as a valid
`bearer` credential (auth_methods includes `bearer`, which validates
inbound access tokens by introspection/signature regardless of how they
were minted) is exactly the kind of question that needs real traffic
through Kong to answer — not achievable here (see status banner). A future
Docker-enabled run should try this token first (it's the one this doc
already has evidence for), and fall back to a real interactive
`authorization_code` login against `SE_DEMO_CLIENT_ID` (which does support
that grant, per finding #1 above) if `bearer` rejects the M2M token.

## Redirect URI for interactive login

The `identity_providers` resource has no `redirect_uri` field to declare
this in Kong config (confirmed via `kongctl explain
ai_gateways.identity_providers --extended` — see "The central finding"
above for the full field list). That doesn't mean Okta doesn't need one:
for `authorization_code` login (the grant a real interactive user would
use, as opposed to the M2M `client_credentials` token minted above), the
Okta app itself still has to have a registered redirect URI, and Okta will
reject the callback if it doesn't match.

For this 2.0 track, register:

```
http://localhost:8010/anthropic
```

This is this track's proxy port (`8010`, per `docker-compose.aigw2.yml` —
offset from the 1.x track's `8000` so both tracks can run side by side)
plus `claude-chat`'s route path (`/anthropic`, `config.route.paths` in
`kong-2.0/03-oidc-okta.yaml`). It mirrors the 1.x track's own
`kong/03-oidc-okta.yaml`, which registers `http://localhost:8000/anthropic`
(plus `/anthropic/v1/messages` and `/anthropic/v1/models` variants for its
two separate Kong Gateway services/routes) — this 2.0 track has a single
model/route, so only the one URI is needed. If you already registered the
1.x track's three `:8000` URIs in the shared Okta app (same tenant/app as
`docs/okta-setup.md`, per `kong-2.0/03-oidc-okta.yaml`'s header comment —
no new Okta app is needed for this track), add this `:8010` one alongside
them rather than replacing them.

## Apply it

```bash
set -a; source .env.2.0; set +a
# Seed the vault secrets first — see "Two more real, live findings" above.
kongctl diff -f kong-2.0/03-oidc-okta.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}"
kongctl apply -f kong-2.0/03-oidc-okta.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}" --auto-approve
```

**Real output from this session:**

```
RESOURCE CHANGES
Namespace: kong-claude-ai-gateway-2-0 (2 changes: 1 create, 1 update)
  ai_gateway_identity_provider (1 resources): + okta-oidc
  ai_gateway_model (1 resources): ~ claude-chat (depends on ai_gateway_identity_provider:okta-oidc)

Executing changes:
[1/2] Creating ai_gateway_identity_provider: okta-oidc... ✓
[2/2] Updating ai_gateway_model: claude-chat... ✓
Complete. Executed 2 changes.
```

A following `kongctl diff`: `No changes detected. Konnect is up to date.`

## Confirmed live via the Konnect API

```json
// GET /v1/ai-gateways/{id}/models  (claude-chat, access field only)
{
  "name": "claude-chat",
  "enabled": true,
  "access": {
    "identity_providers": ["okta-oidc"]
  }
}
```

`kongctl diff` reporting "no changes" after apply is itself a form of
live server-side confirmation for the identity provider resource — it's
computed from a real GET against the Konnect API through kongctl's own
SDK. A direct raw `curl` against several guessed REST paths for the
identity-providers collection itself (`/identity-providers`,
`/identity_providers`, `/identity-provider`, `/identityProviders`) all
404'd — the exact REST path this beta resource is exposed under (if
different from the pattern `/policies`/`/models`/`/consumers` use) was not
found in the time available. This doesn't weaken the confirmation above
(the model's own `access` field, and kongctl's own zero-drift diff, are
both real evidence) — it's a documented gap in *how* it was confirmed, not
whether.

## Live-verify reject/accept/batched paths — NOT achievable here

Per the status banner: no Docker, no serverless proxy URL for this
control plane. `scripts/verify-2.0.sh 03-oidc-okta` is written (single
request with a valid Okta bearer token → expect `200` with
`"role":"assistant"`) but not run — there is no reachable
`http://localhost:8010/anthropic` in this environment. The brief's Step 4
batched-8-runs test against Issue 22 (openid-connect non-determinism) was
**not attempted** — it requires exactly the same reachable endpoint this
module doesn't have. Whatever Issue 22 resolves to, it isn't resolved
here; a future Docker-enabled run needs to do that work, ideally starting
from the M2M token already minted in this doc (see "What this means for
`scripts/verify-2.0.sh`" above) plus a real interactive-login token as a
second data point.
