# 04 — Per-user model access limits (AI Gateway 2.0 track)

> **Status (2026-07-23, verified against `kongctl` 1.6.0 / Fel Tech org /
> `us.api.konghq.tech`):**
> ✅ **Control-plane side fully live-verified.** `kongctl apply` created the
> `team-model-listing` `ai_gateway_policy` (`type: pre-function`) and
> attached it to the existing `claude-chat` model. A follow-up `kongctl
> diff` shows zero drift on this module's own resources (at the time this
> module ran, the one remaining planned delete was module 2's still-live
> `claude-key-auth` global `policies:` entry, unrelated to this module —
> see `docs-2.0/03-oidc-okta-2.0.md`'s "does not delete" section). **Note:**
> module 2 has since (2026-07-23) been corrected to model key-auth via
> `identity_providers` instead of a global `policies:` entry — see
> `kong-2.0/02-key-auth.yaml`'s header. This module's own design (a
> `pre-function` policy attached per-model) is unaffected by that
> correction.
> ⚠️ **This module's design is NOT the brief's literal 3-model draft.** The
> brief proposed two new models (`claude-models-premium`,
> `claude-models-standard`) sharing `claude-chat`'s exact
> `(formats: [anthropic], capabilities: [generate])` pair. That was
> investigated first, found to walk directly into the real,
> Kong-acknowledged **WONT-FIX** KOKO-3852 route-collision bug, and was
> **not built as drafted**. What shipped instead: **zero new models** — one
> new model-scoped `pre-function` policy on the existing `claude-chat`,
> which intercepts `GET /anthropic/v1/models` and returns a team-filtered
> static list directly, then passes every other path through unmodified.
> See "The two investigations" below for the full evidence trail.
> ❌ **End-to-end team-based filtering with real Okta tokens NOT
> verified** — same hard constraint as every prior module (confirmed 4
> times now): no Docker in this sandbox, and this control plane has no
> serverless/Konnect-hosted proxy URL. `scripts/verify-2.0.sh
> 04-per-user-model-limits` is written for a future Docker-enabled run but
> was not executed.
> ⚠️ **Plugin-priority ordering between this policy and `okta-oidc` auth is
> unverified.** See "Known open risk" below — this is real and worth
> reading before treating this module as auth-safe.

## What this adds

One new `ai_gateway_policy`, `team-model-listing` (`type: pre-function`,
model-scoped — `global` unset, defaults to `false`), attached to the
existing `claude-chat` model's `policies:` array alongside its unchanged
`access.identity_providers: [okta-oidc]` gate from module 3. No new model,
no new route, no new identity provider.

## The two investigations (do these before reading the design)

### Investigation 1 — is the brief's 3-model / KOKO-3852 collision risk real on this build?

`docs-2.0/01-general-proxying-2.0.md`'s status banner already flagged this
risk in the abstract for a *future* module (module 1 declares exactly one
model, so the condition was never triggered there). This module is that
"future module," and the brief's own Step 1 draft hits it directly: three
models (`claude-chat` + 2 new ones) all sharing
`formats: [anthropic]`/`capabilities: [generate]`.

**Secondary evidence (not re-derived, cited as authoritative):**
`~/claude/projects/aigw2.0-test/AIGW-2.0-JIRA-TRACKING.md`, issue 15
(bundled with issue 27, same root cause) — [KOKO-3852](https://konghq.atlassian.net/browse/KOKO-3852).
Root cause confirmed by Kong Eng 2026-07-09: `poc-chat-model` +
`poc-semantic-model` (both `openai`/`generate`) compiled onto the **same**
Route entity (`8ae36805`) with two stacked `ai-proxy-advanced` plugin
instances. Marked **WONT-FIX 2026-07-10** — sanctioned path is
config-avoidance only, no product fix coming.

**What this module tested live, since the DP-compiled Route itself can't
be inspected here (no Docker, same gap module 1 already documented):**
applied a throwaway model, `claude-collision-test`
(`formats: [anthropic]`, `capabilities: [generate]`, route
`/anthropic/v1/models`) alongside the real `claude-chat`
(`formats: [anthropic]`, `capabilities: [generate]`, route `/anthropic`)
via `kongctl apply`, then fetched both back:

```bash
kongctl get ai-gateway models --gateway-id "$GWID" -o json \
  | jq '.[] | {name, formats, capabilities, route: .config.route}'
```

Result: the Konnect API accepted the second model with **zero validation
error or warning**. Both existed side-by-side in the declarative config,
sharing `(formats, capabilities)`, distinguished only by
`config.route.paths`. This is the useful, previously-untested half of the
finding: **there is no CP-side guard rail against creating the collision
condition** — `kongctl diff`/`apply` will happily let you build the exact
config Kong Eng found silently merges onto one route on a real DP. The
route-compile collision itself (the phantom second `ai-proxy-advanced`
instance) was **not** independently re-observed here — doing so needs a
live DP + `GET :8011/config`, the same gap every prior module hit. This
module treats Kong Eng's confirmed root-cause + WONT-FIX status as
sufficient not to ship the collision-triggering design, rather than
re-deriving the DP-side symptom itself.

The throwaway model was deleted immediately after:
`DELETE /v1/ai-gateways/{id}/models/{id}` → `204`. It is not part of this
module's shipped config.

**Conclusion:** the brief's literal 3-model draft is unsafe to ship on this
build. This module's actual design uses zero new models sharing
`claude-chat`'s `(formats, capabilities)` — it avoids the collision class
entirely rather than needing a workaround for it.

### Investigation 2 — the brief's Option 1 (route-header conditioning) and the `pre-function` policy-scope question

**`route.headers` — confirmed real and working, but not what ended up
being used.** `kongctl explain ai_gateways.models.config.route --extended`
doesn't expand `route`'s nested fields (typed as an opaque `map[string]`
in `explain`'s output), so this had to be tested live rather than read off
a schema. The same throwaway `claude-collision-test` model above was
re-applied with `config.route.headers: {team: [kong-premium]}` set.
`kongctl apply` created it with zero error, and `kongctl get ai-gateway
models ... -o json` echoed `route.headers.team: ["kong-premium"]` back
from the server. **This is real** — a model's route genuinely can be
conditioned on a header. But using it the way the brief's Option 1
literally suggested (one model per team, both on `/anthropic/v1/models`,
distinguished by a `team` header) still needs **two** models sharing
`(formats, capabilities)` with each other — it doesn't avoid Investigation
1's collision, it just relocates it. This module goes one step further:
zero new models, so `route.headers` isn't used at all here (documented as
a confirmed capability for a future module that might need it for a
different reason, not because this one needed it).

**`pre-function` policy type and per-model attachment — confirmed real and
working, this IS what got used.** `kongctl explain ai_gateways.policies
--extended` shows `type: string` with no closed enum (unlike
`identity_providers.type`, which module 3 found is a closed
`key-auth|openid-connect` enum) — the Konnect MCP tool's
`create_ai_gateway_policy` schema explains why: `type` is "equivalent to
the Kong 3 plugin name" generically. `pre-function` is a real bundled Kong
plugin name, so nothing in the schema rules it out on its face — but that
alone doesn't confirm it attaches per-model rather than forcing
`global: true` the way module 2 found `key-auth` does. Tested live:
applied a throwaway `pre-function` policy (`team-claim-header-test`,
`config.rewrite: [...]`, no `global` field set) attached via
`claude-chat`'s `policies:` array only (not `global: true`
control-plane-wide):

```
+ [1:c:ai_gateway_policy:team-claim-header-test] ...
  global: false
~ [2:u:ai_gateway_model:claude-chat] ...
  policies: null → [team-claim-header-test]
```

`kongctl apply` created/updated with zero error. `kongctl get ai-gateway
policies --gateway-id "$GWID" -o json` confirmed `"global": false`
server-side; `kongctl get ai-gateway models ...` confirmed `claude-chat`'s
`policies` array contains the ref. **`pre-function` does NOT share
`key-auth`'s `policies:`-attachment global-only restriction — confirmed
live, it attaches per-model exactly the way the brief assumed.** (Key-auth
itself no longer uses that `policies:` path either as of the 2026-07-23
correction to `kong-2.0/02-key-auth.yaml` — see that file's header.) The throwaway policy was
retired by re-applying `claude-chat` with the real policy list (which
replaced the test ref during this module's real apply) and deleting the
now-unreferenced test policy directly via the API afterward
(`DELETE /v1/ai-gateways/{id}/policies/{id}` → `204`).

## The actual design

`claude-chat`'s existing route (`paths: ["/anthropic"]`, a prefix match)
already covers `GET /anthropic/v1/models` — no new route or model is
needed to reach that path. `team-model-listing`'s Lua:

1. Only acts when the request path is exactly `/anthropic/v1/models` —
   every other path under `/anthropic` (real chat traffic) passes through
   untouched (`return` with no body, standard pre-function no-op).
2. Extracts the `team` claim from the bearer JWT via
   `jwt_parser:new(token)` — the same approach the brief's Step 1 used;
   this part of the brief's design was sound and reused as-is.
3. Returns a static, team-scoped JSON models list via
   `kong.response.exit()`: `kong-premium` → 2 models, `kong-standard` → 1
   model, anything else → `403`.

This produces the same observable behavior the brief's 3-model design was
going for, with zero new `ai_gateway_model`s, zero `(formats,
capabilities)` collision exposure, and no need for the brief's own noted
"placeholder target" workaround — that concern is moot here, since there
is no new model that would need an unused `target_models`/`targets` entry
in the first place.

## vs. 1.x

The 1.x/decK track's `kong/04-per-user-model-limits.yaml` (per the task
brief's description) pairs a global `pre-function` JWT-claim-extraction
plugin with **two routes on one service**, each carrying a
team-scoped `request-termination` plugin, distinguished by a route-level
`headers: {team: [...]}` condition. The `pre-function`/JWT-extraction
half of that pattern is genuinely identical Lua here — that part of the
brief's framing ("pure Lua, unaffected by the schema change") holds up,
confirmed live in Investigation 2 above. What's structurally different is
everything downstream of the extraction: 1.x has the luxury of two
lightweight *routes* on a shared service, a concept this schema doesn't
expose the same way (an `ai_gateway_model`'s `route` is a much heavier
resource, and two of them sharing `(formats, capabilities)` collide per
KOKO-3852 above) — so this module folds the two `request-termination`
plugins' *behavior* directly into the one `pre-function` script's
branching logic instead of standing up two routes/models/policies to hold
them separately. Net effect is the same team-based filtering; the resource
topology needed to get there is not.

## Known open risk — plugin-priority ordering with `okta-oidc`

**Not independently verified here** (same hard constraint — no Docker, no
serverless proxy URL, confirmed 4 times): whether `okta-oidc`'s
`openid-connect` auth is guaranteed to run *before*
`team-model-listing`'s `kong.response.exit()` on the same request. If a
`pre-function` policy in the `rewrite` phase (the phase this module's Lua
uses, matching the brief's own Step 1 choice) runs earlier than Kong's
`access`-phase auth enforcement, an unauthenticated caller could
theoretically reach the team-filtering branch (and get a `403` for lacking
a recognized `team` claim) without ever being rejected by `okta-oidc`
first for lacking valid auth at all — a different failure mode than
intended, though not a data leak (the policy never falls through to the
real chat targets, and never returns anything but the two static lists or
an error). `access.identity_providers` is a separate resource class from
`policies` (module 3's central finding) — not a phase-ordered plugin the
same way `pre-function` is — so their relative execution order genuinely
cannot be determined from the declarative schema alone. This needs a live
DP request trace to resolve; document it as an open risk, not a
confirmed-safe design, rather than assume the brief's original framing
("pure Lua, unaffected by the schema change") extends to ordering
guarantees it never claimed in the first place.

## `${{ env "..." }}` still doesn't work — same finding as module 3

The brief's Step 2 asked for `KONGCTL_TEAM_CLAIM_NAME`/
`KONGCTL_TEAM_HEADER_NAME` vars, implying they'd be templated into the
policy config the way the 1.x/decK track would with `${{ env "..." }}`.
Per module 3's already-confirmed finding, that tag syntax is not expanded
by `kongctl` at all — it passes through as a literal string. Since the
`team` claim name isn't sensitive, this module hardcodes it directly in
the Lua (`CLAIM_NAME = "team"`) rather than routing it through a
`{vault://...}` reference (the mechanism module 3 used for genuinely
secret Okta values) or leaving a broken template in place.
`KONGCTL_TEAM_HEADER_NAME` is unused by this design entirely — it was part
of the brief's original header-rewrite step, which this module's
consolidated single-policy approach doesn't need (there's no downstream
plugin reading a rewritten header; the same policy that extracts the claim
also produces the final response). Both vars are kept in
`.env.2.0.example` as documentation of the brief's original intent, not as
values `kongctl apply` actually consumes.

## Apply it

```bash
set -a; source .env.2.0; set +a
kongctl diff -f kong-2.0/04-per-user-model-limits.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}"
kongctl apply -f kong-2.0/04-per-user-model-limits.yaml \
  --base-url "${KONNECT_AIGW2_BASE_URL:-https://us.api.konghq.tech}" \
  --pat "${KONGCTL_DEFAULT_KONNECT_PAT}" --auto-approve
```

**Real output from this session:**

```
RESOURCE CHANGES
Namespace: kong-claude-ai-gateway-2-0 (2 changes: 1 create, 1 update)
  ai_gateway_policy (1 resources): + team-model-listing
  ai_gateway_model (1 resources): ~ claude-chat (depends on ai_gateway_policy:team-model-listing)

Executing changes:
[1/2] Creating ai_gateway_policy: team-model-listing... ✓
[2/2] Updating ai_gateway_model: claude-chat... ✓
Complete. Executed 2 changes.
```

A following `kongctl diff` shows `0 to add, 0 to change` for this module's
own resources (`1 to destroy` is module 2's still-live `claude-key-auth`,
unrelated — see `docs-2.0/03-oidc-okta-2.0.md`).

## Confirmed live via the Konnect API

```json
// GET /v1/ai-gateways/{id}/models  (claude-chat, relevant fields only)
{
  "name": "claude-chat",
  "policies": ["team-model-listing"],
  "access": { "identity_providers": ["okta-oidc"] }
}

// GET /v1/ai-gateways/{id}/policies  (team-model-listing)
{
  "name": "team-model-listing",
  "type": "pre-function",
  "global": false
}
```

## Live-verify team-based filtering — NOT achievable here

Per the status banner: no Docker, no serverless proxy URL for this control
plane. `scripts/verify-2.0.sh 04-per-user-model-limits` is written (two
requests, `kong-premium`/`kong-standard` bearer tokens, expect `2`/`1`
models respectively) but not run — there is no reachable
`http://localhost:8010/anthropic/v1/models` in this environment. Whether
the team-filtering behaves as designed, and whether the "Known open risk"
above is a real problem in practice, are both open until a future
Docker-enabled run against a live hybrid DP. Minting real
`kong-premium`/`kong-standard`-claimed Okta tokens was out of scope here
per this task's own instructions (secondary to the collision/policy-scope
investigation, and blocked on whether the SE demo Okta tenant's test app
has a `team` custom claim configured at all — not chased further).
