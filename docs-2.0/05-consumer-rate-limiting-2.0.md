# 05 — Consumer-based rate limiting (AI Gateway 2.0 track)

> **Status (2026-07-23, verified against `kongctl` 1.6.0 / Fel Tech org /
> `us.api.konghq.tech`):**
> ✅ **Control-plane side fully live-verified.** `kongctl apply` created the
> `claude-token-rate-limit` `ai_gateway_policy` (`type:
> ai-rate-limiting-advanced`) and attached it to the existing `claude-chat`
> model alongside module 4's `team-model-listing`. A following `kongctl
> diff` shows zero drift on this module's own resources (at the time this
> module ran, the one remaining planned delete was module 2's still-live
> `claude-key-auth` global `policies:` entry, unrelated — see
> `docs-2.0/03-oidc-okta-2.0.md`). **Note:** module 2 has since (2026-07-23)
> been corrected to model key-auth via `identity_providers` instead of a
> global `policies:` entry — see `kong-2.0/02-key-auth.yaml`'s header. This
> module's own design is unaffected by that correction.
> ✅ **Attachment scope confirmed live: per-model, NOT forced global.**
> Same pattern as `pre-function` (module 4) — see "Attachment scope"
> below for the throwaway-policy test and the raw server response.
> ⚠️ **One field in the brief's Step 1 draft does not exist on the real
> plugin schema and was dropped.** `config.llm_format` — pulled the real
> schema straight from the Konnect API
> (`GET /ai-gateways/{id}/policies/schemas/ai-rate-limiting-advanced`)
> and grepped it for the literal string `"llm_format"`: zero matches.
> Every other field in the brief's draft (`identifier`, `strategy`,
> `policies[].window_type`, `policies[].limits[].limit`/`window_size`)
> matched the real schema exactly, unlike modules 3/4's config shapes,
> which needed more substantial rework. See "The real schema" below.
> ❌ **Actual rate-limit tripping (a 429 after the token budget is
> exhausted) NOT observed here** — same hard constraint as every prior
> module (confirmed 5 times now): no Docker in this sandbox, no
> serverless/Konnect-hosted proxy URL for this control plane.
> `scripts/verify-2.0.sh 05-consumer-rate-limiting` is written for a
> future Docker-enabled run but was not executed. See "Secondhand prior
> art" below for what a *different* environment's real-traffic test found
> on a comparable build — cited as context, not as this module's own
> verification.

## What this adds

One new `ai_gateway_policy`, `claude-token-rate-limit` (`type:
ai-rate-limiting-advanced`, model-scoped — `global` unset, confirmed
`false` server-side), attached to the existing `claude-chat` model's
`policies:` array alongside module 4's `team-model-listing` (unchanged).
`identifier: consumer` scopes the rate-limit counter per authenticated
caller (populated by the `okta-oidc` identity provider from module 3);
`strategy: local` keeps counters in each nginx worker's own memory; a
single fallback policy entry (no `match` condition, so it applies to
every request through this model) enforces a 5000-total-token sliding
window per 60 seconds.

## The real schema

`kongctl explain ai_gateways.policies.config --extended` does not expand
`config`'s nested fields (typed as an opaque `map[string]` in `explain`'s
output — the same behavior module 4 hit on
`ai_gateways.models.config.route`), so the real schema was pulled
directly from the Konnect API instead of guessed at:

```bash
curl -s -H "Authorization: Bearer $KONGCTL_DEFAULT_KONNECT_PAT" \
  "$BASE_URL/v1/ai-gateways/$GWID/policies/schemas/ai-rate-limiting-advanced"
```

Relevant fields returned, compared field-by-field against the brief's
Step 1 draft:

| Field | Brief's draft | Real schema | Match? |
|---|---|---|---|
| `identifier` | `consumer` | top-level, required, default `consumer`, one_of `ip\|credential\|consumer\|service\|header\|path\|consumer-group` | ✅ |
| `strategy` | `local` | top-level, required, default `local`, one_of `local\|redis\|cluster` | ✅ |
| `policies[].window_type` | `sliding` | **per-policy** field (not top-level), default `sliding`, one_of `fixed\|sliding\|calendar` | ✅ (brief nested it correctly) |
| `policies[].limits[].limit` / `.window_size` | present | `limits[]` record with `limit` (required, `gt: 0`), `window_size` (optional integer), plus calendar-only fields (`period`, `week_start_day`, `month_day`) not used here | ✅ |
| `tokens_count_strategy` | top-level `total_tokens` | exists **twice**: top-level `config.tokens_count_strategy` (default `total_tokens`, "what tokens to use for cost calculation") AND a per-limit `policies[].limits[].tokens_count_strategy` override (same enum, "what to count for THIS limit") | ✅ (brief's top-level placement is a real, valid field) |
| `config.llm_format` | `anthropic` | **does not exist anywhere in the schema** — grepped the full schema JSON for `"llm_format"`: zero matches | ❌ dropped |

This is, as the brief predicted, the module with the least schema drift
of the five built so far — one field removed, everything else shipped
as originally drafted. Contrast with module 3 (`${{ env "..." }}` doesn't
expand at all) and module 4 (the brief's literal 3-model design hit a
live WONT-FIX collision bug and had to be redesigned from scratch).

## Attachment scope

Tested the same way modules 2-4 did, since nothing in `kongctl explain`'s
output settles whether a policy type is forced `global: true` (module 2's
original `policies:`-attached `key-auth` finding) or attaches cleanly
per-model (module 4's `pre-function` finding) — this had to be checked
live per-plugin-type, not assumed from one prior finding to the next.

Created a throwaway `ai-rate-limiting-advanced` policy directly via the
API first (`claude-rate-limit-test`, minimal
`{identifier: consumer, strategy: local, policies: [{limits: [{limit: 1,
window_size: 60}]}]}`, no `global` field set):

```json
{"id": "8cd2...", "name": "claude-rate-limit-test", "type": "ai-rate-limiting-advanced", "global": false}
```

`global: false` by default — the first signal this plugin type does not
share `key-auth`'s `policies:`-attachment forced-global restriction.
Discovering `ai_gateway_model`
has no `PATCH` verb (`Allow: DELETE, GET, PUT` only — a real 405 hit while
probing this), the actual attachment test switched to the repo's normal
`kongctl`-based workflow: a scratch copy of this module's YAML with a
second throwaway policy (`claude-rate-limit-scope-test`) added to
`claude-chat`'s `policies:` array. `kongctl diff` planned:

```
+ [3:c:ai_gateway_policy:claude-rate-limit-scope-test] ai_gateway_policy "claude-rate-limit-scope-test" will be created
  ...
  global: false
~ [5:u:ai_gateway_model:claude-chat] ai_gateway_model "claude-chat" will be updated
  policies: [team-model-listing] → [team-model-listing claude-token-rate-limit claude-rate-limit-scope-test]
```

`kongctl apply` created/updated with zero error. Confirmed server-side via
the Konnect API afterward:

```json
// GET /v1/ai-gateways/{id}/policies (both instances, relevant fields only)
{"name": "claude-token-rate-limit", "type": "ai-rate-limiting-advanced", "global": false}
{"name": "claude-rate-limit-scope-test", "type": "ai-rate-limiting-advanced", "global": false}

// GET /v1/ai-gateways/{id}/models/{id}
{"name": "claude-chat", "policies": ["team-model-listing", "claude-token-rate-limit", "claude-rate-limit-scope-test"]}
```

**`ai-rate-limiting-advanced` does NOT share `key-auth`'s
`policies:`-attachment global-only restriction — confirmed live, it
attaches per-model exactly the way `pre-function` (module 4) does and the
way the brief assumed.** (Key-auth itself no longer uses that `policies:`
path either as of the 2026-07-23 correction to `kong-2.0/02-key-auth.yaml`
— see that file's header.) The
throwaway scope-test policy was retired by re-applying `claude-chat` with
this module's real policy list (which replaces the test ref during a real
`kongctl apply`) and deleting the now-unreferenced test policy directly
via the API afterward (`DELETE /v1/ai-gateways/{id}/policies/{id}` →
`204` for both throwaway policies created during this investigation).

## Secondhand prior art (different environment, not this module's own verification)

The brief cites a sibling repo's own real-traffic shakeout as prior art
that `ai-rate-limiting-advanced` genuinely trips 429s on AI Gateway 2.0.
That repo (`~/claude/projects/aigw2.0-test/`, a different Konnect
org/control plane, entries dated through 2026-07-08) independently
arrived at the same real config shape while porting its own 1.x
`ai-rate-limiting-advanced` policies — `identifier`/`strategy` top-level,
`policies[].limits[].tokens_count_strategy` nested, zero `llm_format`
across four separate instances in `poc-default-ai-gateway-2.0.yaml`. Its
own findings doc states plainly: "1.x's flat `llm_providers:
[{name, window_size, limit}]` doesn't carry over — 2.0's schema is a
match-condition + limits-array shape" — consistent with, but not the
source of, this module's own live schema pull above. This is useful
secondhand context that the plugin *type* is known to trip real 429s on
a comparable AI Gateway 2.0 build (that repo's issue-tracking table lists
it among the working POC criteria, not among the open bug list) — it is
**not** evidence about this specific control plane, and is not treated
as a substitute for this module's own (not-yet-possible) live 429 test.

## vs. 1.x

Per the brief's own framing, confirmed correct here: `ai-rate-limiting-advanced`
is a named `ai_gateway_policy` referenced from `claude-chat`'s `policies:`
list, rather than an inlined-on-the-service/route plugin the way the
1.x/decK track attaches it. The **plugin's own config shape is otherwise
unchanged from 1.x** — `identifier`, `strategy`, and a `policies[]` array
of `{match?, limits[], window_type}` are the same fields a 1.x
`ai-rate-limiting-advanced` config would use. The one difference found
(`llm_format` not existing here) isn't a 1.x-vs-2.0 schema break either —
`llm_format` isn't a real field on this plugin in either track's schema;
the brief's draft appears to have carried it over by analogy from
`ai-proxy-advanced`'s own `config.llm_format`, a different plugin
entirely. Net effect: of the five modules built so far, this is the one
where "just port the config" came closest to actually working as
literally drafted.

## Apply it

```bash
set -a; source .env.2.0; set +a
kongctl diff -f kong-2.0/05-consumer-rate-limiting.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}"
kongctl apply -f kong-2.0/05-consumer-rate-limiting.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}" --auto-approve
```

**Real output from this session (converging from the scope-test state
back to the real module 5 config):**

```
RESOURCE CHANGES
Namespace: kong-claude-ai-gateway-2-0 (1 changes: 1 update)
  ai_gateway_model (1 resources): ~ claude-chat

Executing changes:
[1/1] Updating ai_gateway_model: claude-chat... ✓
Complete. Executed 1 changes.
```

A following `kongctl diff` shows `0 to add, 0 to change` for this
module's own resources (`1 to destroy` is module 2's still-live
`claude-key-auth`, unrelated — see `docs-2.0/03-oidc-okta-2.0.md`).

## Confirmed live via the Konnect API

```json
// GET /v1/ai-gateways/{id}/policies  (claude-token-rate-limit, relevant fields only)
{
  "name": "claude-token-rate-limit",
  "type": "ai-rate-limiting-advanced",
  "global": false,
  "config": {
    "identifier": "consumer",
    "strategy": "local",
    "tokens_count_strategy": "total_tokens",
    "policies": [
      { "window_type": "sliding", "limits": [{ "limit": 5000, "window_size": 60, "tokens_count_strategy": "total_tokens" }] }
    ]
  }
}

// GET /v1/ai-gateways/{id}/models  (claude-chat, relevant fields only)
{
  "name": "claude-chat",
  "policies": ["team-model-listing", "claude-token-rate-limit"]
}
```

## Live-verify the limit trips — NOT achievable here

Per the status banner: no Docker, no serverless proxy URL for this
control plane. `scripts/verify-2.0.sh 05-consumer-rate-limiting` is
written (20 requests with the same `OKTA_ACCESS_TOKEN`, expect at least
one `429` once the 5000-token/60s budget is exhausted) but not run —
there is no reachable `http://localhost:8010/anthropic` in this
environment. Per the shakeout's own AI GW 3.5 finding (cited secondhand
above, a different environment/build): `strategy: local` means counters
live independently per nginx worker, so with 8 workers it can take more
than one request landing on the same worker to trip — not a bug if the
429 doesn't appear on the very next request after the budget nominally
runs out. Whether that behavior holds on this specific control plane's
build is open until a future Docker-enabled run against a live hybrid DP.
