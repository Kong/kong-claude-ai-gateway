# 01 — General proxying (AI Gateway 2.0 track)

> **Status (2026-07-23, verified against `kongctl` 1.6.0 / Fel Tech org / `us.api.konghq.tech`):**
> ✅ **Control-plane side fully live-verified**: `kongctl apply` created the
> `anthropic-direct` and `bedrock-claude` `ai_gateway_model_provider`s and the
> `claude-chat` `ai_gateway_model` with zero errors after fixing three real
> schema mismatches (see "vs. the brief" below); a second `kongctl diff`
> shows zero drift; both weight-flip variants (Bedrock-primary,
> Anthropic-primary) were applied and confirmed via the Konnect API.
> ❌ **Data-plane side NOT verified** — no traffic was ever sent through
> `/anthropic`. This sandbox has no Docker access (`docker compose` needs a
> socket this shell's user can't reach, same limitation Task 1 hit), and AI
> Gateway 2.0 has no serverless/Konnect-hosted proxy endpoint today
> (confirmed live: `GET /v1/ai-gateways/{id}` returns `proxy_urls: []` —
> that field only *describes* where a hybrid data plane will listen, it
> isn't a Konnect-hosted proxy URL; there is also no non-privileged way to
> inspect DP-compiled config — `GET /v1/ai-gateways/{id}/debug-cp-output`
> exists but returned a real `401` against this PAT, since it's documented
> as "requires a privileged internal service-client token"). **So the
> central open question this module was supposed to resolve —
> `formats: [anthropic]` compiling a working route with a paired
> `ai-model-selector`, vs. hitting KOKO-3854 — could not be directly
> re-tested here.** Best available secondary evidence: the
> `aigw2.0-test` shakeout repo's own tracking
> (`AIGW-2.0-JIRA-TRACKING.md`, `AIGW-2.0-CRITERIA-PROGRESS.md`), last
> updated **2026-07-21** (2 days before this module was built), still lists
> KOKO-3854 ("non-`openai` model `formats` never produce a matchable
> route") as open/unassigned and does **not** list it in
> `AIGW-2.0-ISSUES-RESOLVED.md`. Do not treat that as confirmation for
> *this* build/date — it's the closest evidence available without a DP, not
> a live re-test. **Re-run `scripts/verify-2.0.sh 01-general-proxying`
> against a real hybrid data plane (§5 of `docs-2.0/00-prerequisites-2.0.md`)
> before trusting this module end-to-end.**
>
> **KOKO-3852 — not triggered yet, but will be if later modules add a second
> model:** the same `AIGW-2.0-JIRA-TRACKING.md` tracking file (issue 15,
> bundled with issue 27 — same model→Route compile root cause) documents a
> separate, real bug: two `ai_gateway_model`s that share the same
> `(formats, capabilities)` pair compile onto the **same** Route entity,
> with stacked `ai-proxy-advanced` plugin instances from both models on it.
> Root cause confirmed by Kong Eng 2026-07-09 (`poc-chat-model` +
> `poc-semantic-model`, both `openai`/`generate`, compiled to the same route
> `8ae36805`). Kong has marked this **WONT-FIX (2026-07-10)** — no product
> fix is coming; the sanctioned path is config-avoidance only ("don't
> co-locate two models sharing (format,capability) on one route"). This
> module declares exactly **one** model (`claude-chat`, `formats:
> [anthropic]`, `capabilities: [generate]`), so KOKO-3852's collision
> condition — a second model sharing that same `(formats, capabilities)`
> shape — is not triggered here. It becomes directly relevant starting with
> later modules (2 onward), which may add or reference additional
> models/policies on this same `claude-ai-gateway` control plane: **any
> future module that adds a second model with `formats: [anthropic]` +
> `capabilities: [generate]` on this control plane will silently collide
> onto `claude-chat`'s compiled route**, per Kong's own WONT-FIX stance.
> Future modules must either avoid creating a second model with that exact
> `(formats, capabilities)` shape, or explicitly document a workaround if
> avoidance isn't possible for what they're trying to prove.

## What this adds

An `ai_gateway_model` named `claude-chat`, reachable at `/anthropic` on the
2.0 data plane, with two providers behind it:

- **`anthropic-direct`** — Anthropic's own API, authenticated with the
  vaulted `anthropic-api-key`. Primary target (`weight: 100`).
- **`bedrock-claude`** — the same Claude model family served through AWS
  Bedrock, authenticated with the vaulted AWS access key pair. Alternate
  target (`weight: 1` — see "Why not `weight: 0`" below).

Every later module (2-5) attaches its policies/identity providers to this
same `claude-chat` model ref, so getting this one right first matters the
same way it did for the 1.x track's module 1.

## vs. 1.x

| | 1.x (`kong/01-general-proxying.yaml`) | 2.0 (`kong-2.0/01-general-proxying.yaml`) |
|---|---|---|
| Shape | Service + Route + `ai-proxy-advanced` plugin (per provider, if multi-provider) | One `ai_gateway_model` with a `targets` array — all providers under one resource |
| Provider credential | `ai-proxy-advanced`'s `targets[].auth` | A separate `ai_gateway_model_provider` resource, referenced by name from each target |
| How the client picks a model | Kong route match (`/anthropic`) is the whole story — one route, one provider chain | Route match gets you to the *model*; the request body's `"model"` field then has to match — see the alias gotcha below |
| Multi-provider / failover | A second `targets[]` entry inside the same plugin, `route_type: llm/v1/chat` | A second `targets[]` entry on the model, each tagged with its own `provider` ref and `config.type` |

**The alias gotcha (a real mismatch caught while building this module,
not a copy-paste error):** the task brief's own literal YAML set
`config.model.alias: "@claude/chat"` while its own verify step's curl body
sent `"model": "claude-sonnet-4-6"` (a *target* name, i.e. the Bedrock/
Anthropic provider-side model id) — those don't match each other, and
neither matches the model's own name. Per the `kongctl diff` plan's
computed defaults (confirmed live, see below) and per the
`se-poc-config-default` AI Gateway 2.0 shakeout reference config's own
header comment, **an unset `config.model.alias` defaults to the model's
own `name`** — for this file, `"claude-chat"`. That is what a client must
send as the request body's `"model"` field. Sending a target's name
instead is exactly the `model_alias` mismatch class that silently falls
through to the placeholder `ai-gateway.upstream.local` upstream and DNS-
fails — not a 4xx you'd immediately suspect as a config problem. This file
leaves `config.model.alias` unset deliberately, and `scripts/verify-2.0.sh`
and every curl example below send `"model": "claude-chat"`.

**Payload logging (`config.logging.payloads: true`) — intentional parity
with 1.x, not silent:** this model turns on full request/response body
logging, same as the 1.x track's own `kong/01-general-proxying.yaml`
(`ai-proxy-advanced`'s `logging: {log_payloads: true, log_statistics:
true}`). For the same reason 1.x does it — this is a demo/reference build
where proving the round trip actually worked and having full debugging
visibility outweighs the concern — not a production posture. It does mean
Kong logs full Claude Desktop prompts and model responses; don't carry
this default forward into a production deployment without re-evaluating
the data-sensitivity tradeoff.

## `kongctl explain`/live-schema corrections vs. the task brief

The brief's literal Step 1 YAML was written against an assumed shape that
doesn't match the real Konnect API. All of the following were confirmed
live via `kongctl explain ai_gateways.models --extended --output json` and
`kongctl explain ai_gateways.model_providers --output json`, then proven
by a real `400` or a real successful `kongctl apply`:

1. **`target_models` isn't a field — it's `targets`.**
2. **Bedrock provider auth fields are `access_key_id` / `secret_access_key`**,
   not `aws_access_key_id` / `aws_secret_access_key`, and there is **no
   `aws_region` field on the provider's auth at all**.
3. **AWS region lives on the target's config** (`targets[].config.region`),
   not the provider — and per the OpenAPI spec that field is **not** marked
   `x-referenceable` (unlike `access_key_id`/`secret_access_key`, which
   are), so it has to be a literal string, not a `{vault://...}` reference.
   It's not secret, so this is fine — `region: us-east-1` inline.
4. **The Anthropic target config field is `version`, not
   `anthropic_version`.**
5. **There is no `bedrock_model_id` field.** A target's provider-side
   model identifier is its own `name` — confirmed against every real
   Bedrock Claude target in the `aigw2.0-test` shakeout's reference config,
   which uses e.g. `name: us.anthropic.claude-sonnet-4-5-20250929-v1:0`
   directly.
6. **`targets[].weight` has a hard minimum of `1`, not `0`.** Applying the
   brief's literal `weight: 0` on the Bedrock target produced a real `400`:
   `targets.1.weight [minimum]: number must be at least 1`. The closest
   achievable equivalent to "registered but out of the live split by
   default" is `weight: 1` against the primary's `weight: 100` (~1% of
   unweighted traffic, not 0%).
7. **There is no `_external`/`selector` field on the `ai_gateways`
   resource** (checked via `kongctl explain ai_gateways` — not in the
   schema). To attach this module's `model_providers`/`models` to the
   `claude-ai-gateway` control plane Task 1 already created, this file
   re-declares the same `ai_gateway` (same `ref`, `name`, `display_name`,
   `description`, `labels` as `kong-2.0/00-platform.yaml`) with the new
   children nested underneath. `kongctl` matches the live resource by its
   stored namespace+ref labels regardless of which file declares it —
   confirmed live: applying this file alone (not combined with
   `00-platform.yaml`) updated the existing control plane in place and did
   not create a duplicate.

## Apply it

```bash
set -a; source .env.2.0; set +a
kongctl diff -f kong-2.0/01-general-proxying.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}"
kongctl apply -f kong-2.0/01-general-proxying.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}" --auto-approve
```

**Real output from this session** (after the schema fixes above):

```
RESOURCE CHANGES
Namespace: kong-claude-ai-gateway-2-0 (3 changes: 3 create)
  ai_gateway_model_provider (2 resources): + anthropic-direct, + bedrock-claude
  ai_gateway_model (1 resources): + claude-chat
...
Executed 3 changes.
```

A second `kongctl diff` immediately after: `No changes detected. Konnect is
up to date.` — clean idempotency, no `kongctl#1486`-style diff-noise
observed on this resource (that noise was reported for a different
scenario in the shakeout; this module's re-diff was genuinely empty).

**Confirmed live via the Konnect API** (`GET
/v1/ai-gateways/{id}/models`), not just the `kongctl` plan — the actual
stored resource:

```json
{
  "name": "claude-chat",
  "formats": [{"type": "anthropic"}],
  "config": {
    "route": {"paths": ["/anthropic"]},
    "model": {"alias": "claude-chat", "name_header": true}
  },
  "targets": [
    {"name": "claude-sonnet-4-6", "provider": "anthropic-direct", "weight": 100,
     "config": {"type": "anthropic", "version": "2023-06-01"}},
    {"name": "us.anthropic.claude-sonnet-4-5-20250929-v1:0", "provider": "bedrock-claude",
     "weight": 1, "config": {"type": "bedrock", "region": "us-east-1"}}
  ]
}
```

Note `config.model.alias: "claude-chat"` — that's `kongctl`/Konnect's own
computed default (we left `model.alias` unset in the source YAML), which is
the live proof behind the "alias gotcha" section above.

## Confirming the compiled DP chain (KOKO-3854 check) — NOT achievable here

The brief's Step 3 asks for `GET :8011/config` from a running data plane,
checking that both `ai-model-selector` and `ai-proxy-advanced` are present
on the `/anthropic` route. **This requires a live hybrid data plane, which
this sandbox cannot run** (no Docker socket access). The one Konnect-side
alternative that could show the same thing without a DP —
`GET /v1/ai-gateways/{id}/debug-cp-output` — returned a real `401 A valid
token is required`; its own OpenAPI description says it needs "a privileged
internal service-client token," which a normal org PAT is not. So this
module cannot itself confirm or deny the KOKO-3854 signature; see the
status banner at the top for what's known second-hand as of 2026-07-21.

**When you do have a DP**, run:

```bash
curl -s http://localhost:8011/config | jq -r '.config' > /tmp/aigw2-config.json
jq '.plugins[] | select(.name == "ai-proxy-advanced" or .name == "ai-model-selector") | {name, route}' /tmp/aigw2-config.json
```

If `ai-model-selector` is missing next to `ai-proxy-advanced` on the
`/anthropic` route, that's the KOKO-3854 signature — the model alias can't
be extracted from the request, so traffic falls through to the placeholder
`ai-gateway.upstream.local` upstream and 503s, regardless of the `model`
field's value.

## Live chat request — NOT achievable here

Same limitation. Once a DP is up (`docker compose -f
docker-compose.aigw2.yml up -d`, confirmed `Connected` in the Konnect UI
per `docs-2.0/00-prerequisites-2.0.md` §5):

```bash
curl -s -o /tmp/aigw2-resp.json -w '%{http_code}\n' \
  http://localhost:8010/anthropic \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}'
cat /tmp/aigw2-resp.json
```

Note the request body's `"model"` field is `"claude-chat"` (the model's own
name/default alias), **not** `"claude-sonnet-4-6"` — see the alias gotcha
above. Expect `200` and a body with `"role":"assistant"` if KOKO-3854 is
fixed on the build under test; expect a `503` with an upstream DNS failure
against `ai-gateway.upstream.local` if it isn't. Run it 3 times before
concluding either way (propagation timing can produce a false negative on
the first request right after an apply).

`scripts/verify-2.0.sh 01-general-proxying` automates exactly this check.
Run in this session, it failed fast with a real connection error (`exit
7`, curl "connection refused" against `localhost:8010`) — the expected,
uninteresting result of there being no DP listening at all, not a finding
about the model config.

## Bedrock alternate target — config-level only, traffic NOT verified

Weight-flip mechanics were verified end-to-end at the config layer:

1. Edited the YAML to `claude-sonnet-4-6: weight 1`,
   `us.anthropic.claude-sonnet-4-5-20250929-v1:0: weight 100`.
   `kongctl apply` → `1 changes: 1 update`, succeeded.
   `GET /v1/ai-gateways/{id}/models` confirmed the live weights flipped
   exactly as declared.
2. Flipped back to Anthropic-primary (`weight: 100` / `weight: 1`, the
   file's committed state). `kongctl apply` → `1 changes: 1 update`,
   succeeded; a following `kongctl diff` showed zero drift.

**What was not done**: sending a real chat request against either
weighting to confirm which target actually served it. That requires the
same DP this whole module lacks. Re-run both weightings and the curl above
once a hybrid DP is available.

## Claude Desktop configuration

Not attempted — no reachable proxy endpoint exists yet in this
environment (see status banner). Once a DP is up, point Claude Desktop's
custom base URL at `http://localhost:8010/anthropic`, same as the 1.x
track's [`claude-desktop/README.md`](../claude-desktop/README.md); Kong
injects the real Anthropic credential from the vault, so any placeholder
value works in the Desktop app's own API key field.
