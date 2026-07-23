# 07 — OpenTelemetry tracing (AI Gateway 2.0 track)

> **Status (2026-07-23, verified against Fel Tech org / `us.api.konghq.tech`):**
> ✅ **Policy config confirmed correct against the real schema, and
> confirmed applied server-side.** `GET /v1/ai-gateways/{id}/policies/schemas/opentelemetry`
> was pulled live and diffed field-by-field against the brief's Step 2
> draft — `traces_endpoint`, `logs_endpoint`, and `resource_attributes`
> all matched exactly, no corrections needed (unlike module 5's
> `ai-rate-limiting-advanced`, which needed one field dropped). `kongctl
> diff` then `kongctl apply --auto-approve` ran for real against the live
> control plane: `claude-otel-tracing` (`type: opentelemetry`) was
> created with `global: false` and is attached to `claude-chat`'s
> `policies` list alongside `team-model-listing`/`claude-token-rate-limit`
> — confirmed via a follow-up `GET .../policies` and `GET .../models`,
> not just the apply's own success message.
> ✅ **Attachment scope confirmed live: per-model, not forced-global.**
> Same test pattern modules 2/4/5 used — `opentelemetry` does NOT share
> `key-auth`'s global-only restriction.
> ⚠️ **The core DP-level env vars are cited, secondhand evidence — NOT
> independently verified here.** The shakeout's own `AIGW-2.0-ISSUES-RESOLVED.md`
> (Issue 21) found that the `opentelemetry` policy's config alone exports
> logs+metrics but never traces, and that fixing it required two additional
> Kong Gateway **process-level** environment variables (`KONG_TRACING_INSTRUMENTATIONS`,
> `KONG_TRACING_SAMPLING_RATE`), completely separate from the policy's own
> `traces_endpoint`/`sampling_rate` fields. The 1.x track's own
> `docs/07-opentelemetry.md` additionally documents a third required var
> (`KONG_OPENTELEMETRY_TRACING: "all"`). **All three have now been added
> to `docker-compose.aigw2.yml` defensively** per Task 8's review finding,
> with both sampling-rate var names (1.x's `KONG_OPENTELEMETRY_TRACING_SAMPLING_RATE`
> and 2.0's `KONG_TRACING_SAMPLING_RATE`) set since the exact one this build
> reads is unverified. These findings are from *different* environments/repos/DPs
> than this one. This task has no way to start a `kong-dp-2.0` container in
> this sandbox (no Docker, confirmed 9 times now across every module in this
> track) to confirm they have the same effect on this repo's 2.0 build.
> ❌ **Actual span export (spans arriving at Jaeger/a collector) is NOT
> achievable/verifiable in this sandbox** — same hard constraint as every
> prior traffic-dependent module. No live span count was observed; the
> shakeout's own "25 spans arrived immediately" result (cited below) is
> from that different environment, not this module's own run.

## What this adds

One new `ai_gateway_policy`, `claude-otel-tracing` (`type: opentelemetry`,
model-scoped, `global: false`), attached to the `claude-chat` model
alongside module 4's `team-model-listing` and module 5's
`claude-token-rate-limit`. Config:

```yaml
config:
  traces_endpoint: http://otel-collector:4318/v1/traces
  logs_endpoint: http://otel-collector:4318/v1/logs
  resource_attributes:
    service.name: claude-ai-gateway-2.0
  sampling_rate: 1
```

Points at the same `otel-collector`/Jaeger stack the 1.x track's
`docker-compose.otel.yml` already runs — no re-pointing needed. Traces for
this track show up in the same Jaeger UI (`http://localhost:16686`) under
a distinct service name, `claude-ai-gateway-2.0`, so they don't mix with
the 1.x track's `kong` service if both stacks are pointed at the same
collector at once.

`sampling_rate: 1` is one field beyond the brief's original Step 2 draft
— a real, optional, top-level schema field (`0`–`1`, "supersedes the
global `tracing_sampling_rate` setting from kong.conf"). Added as
defense-in-depth: the schema's `sampling_strategy` field defaults to
`parent_drop_probability_fallback`, described in terms consistent with
the 1.x track's own module 7 gotcha (`docs/07-opentelemetry.md`'s gate
#3) — a low-probability core-level sampling verdict can win over a
plugin-level 100% rate. This is a schema-level read, not an independently
reproduced runtime failure on this build.

## The investigation

Real schema pulled directly from the Konnect API (same reason module 5's
did — `kongctl explain ai_gateways.policies.config --extended` doesn't
expand `config`'s nested fields):

```
GET /v1/ai-gateways/{id}/policies/schemas/opentelemetry
```

`traces_endpoint`, `logs_endpoint`, and `resource_attributes`
(`map[string]string`) all confirmed present, all matching the brief's
draft exactly — the first module in this track's 2.0 track where the
brief's config draft needed zero corrections against the real schema.

Attachment scope confirmed the same way modules 2/4/5 did — planned (via
`kongctl diff`) a throwaway `opentelemetry` policy attached only to
`claude-chat`'s `policies:` array, no `global` field set:

```
+ [2:c:ai_gateway_policy:otel-scope-test] ... will be created
  enabled: true
  global: false
  ...
~ [4:u:ai_gateway_model:claude-chat] ... will be updated
  policies: [team-model-listing claude-token-rate-limit] →
  [team-model-listing claude-token-rate-limit otel-scope-test]
```

`global: false` planned with zero validation error — **`opentelemetry`
does not share `key-auth`'s global-only restriction.** That throwaway
plan run was deliberately never `apply`'d (its `team-model-listing` body
was a dummy stand-in, not module 4's real Lua, and the plan also showed
module 2's already-documented, unrelated `claude-key-auth` "will be
deleted" — a pre-existing finding, see `kong-2.0/03-oidc-okta.yaml`'s
header comment, not something this module re-litigates). The real,
non-throwaway file below (which carries forward module 4/5's real policy
bodies unchanged) was the one actually `diff`'d and `apply --auto-approve`'d
against the live control plane, and a follow-up `GET` confirmed
`claude-key-auth` was untouched — `kongctl apply` doesn't execute deletes,
only `kongctl sync` does (module 3's finding).

Full investigation, including the exact schema JSON fields checked and the
scope-test plan output, is in `kong-2.0/07-opentelemetry.yaml`'s header
comment.

## vs. 1.x

| | 1.x (`kong/07-opentelemetry.yaml`) | 2.0 (`kong-2.0/07-opentelemetry.yaml`) |
|---|---|---|
| Plugin/policy scope | Global `opentelemetry` plugin (applies to every route) | Model-scoped `opentelemetry` policy (`global: false`), attached only to `claude-chat` |
| Config shape | `traces_endpoint`, `sampling_rate`, `queue.{max_batch_size,max_coalescing_delay}`, deprecated `batch_span_count`/`batch_flush_delay`, `metrics.{endpoint,enable_*}` | `traces_endpoint`, `logs_endpoint`, `resource_attributes`, `sampling_rate` — no `metrics.*` block used here (this module ships tracing+logs only, not the metrics signal; Konnect's own dashboard, module 6, already covers usage metrics for this track) |
| DP-level gates required | **Three**, all in `docker-compose.otel.yml`: `KONG_OPENTELEMETRY_TRACING: "all"` (tracing off by default, independent of plugin config), `KONG_TRACING_INSTRUMENTATIONS: "all"`, `KONG_OPENTELEMETRY_TRACING_SAMPLING_RATE: "1"` | **Three**, per 1.x citation + shakeout's Issue 21 citation (Task 8 review): `KONG_OPENTELEMETRY_TRACING: "all"` (added defensively per 1.x's requirement; 2.0 shakeout's Issue 21 did not mention this one), `KONG_TRACING_INSTRUMENTATIONS: "all"`, `KONG_TRACING_SAMPLING_RATE: "1.0"` + `KONG_OPENTELEMETRY_TRACING_SAMPLING_RATE: "1"` (both sampling-rate names set defensively since the exact one this build reads is unverified). Added to `docker-compose.aigw2.yml` as secondhand evidence, not independently verified in this sandbox (no Docker). |
| Open gap | — | ✅ **Resolved** — All three vars are now added defensively. The shakeout's Issue 21 citation did not mention `KONG_OPENTELEMETRY_TRACING: "all"`, only the latter two; 1.x's own module 7 doc lists all three and states tracing is "entirely disabled" by default without the first. Both sampling-rate var names are set to hedge against uncertainty about which one the 2.0 build reads. If real Docker testing reveals either var is unnecessary or if a different var name is needed, that will be flagged then. |
| The core finding itself | N/A — 1.x's plugin config alone is sufficient for traces | **The `opentelemetry` POLICY config alone is NOT sufficient for traces** (only logs+metrics export) — core DP-level env vars are additionally required. This is the opposite of 1.x's own experience and is this module's headline "vs. 1.x" gotcha, per the shakeout's Issue 21 (cited, not independently reproduced here). |

## Apply it

```bash
set -a; source .env.2.0; set +a
kongctl diff -f kong-2.0/07-opentelemetry.yaml \
  --base-url "$KONNECT_AIGW2_BASE_URL" --pat "$KONGCTL_DEFAULT_KONNECT_PAT"
kongctl apply -f kong-2.0/07-opentelemetry.yaml \
  --base-url "$KONNECT_AIGW2_BASE_URL" --pat "$KONGCTL_DEFAULT_KONNECT_PAT"
```

Both were run for real in this task against the Fel Tech org — see the
status banner above for the confirmed result.

For a future Docker-enabled run, also restart the DP so the new env vars
in `docker-compose.aigw2.yml` take effect, and layer the 1.x track's
existing otel/Jaeger stack (same collector, no changes needed there — see
"vs. 1.x" for the one open question about a possibly-missing third gate):

```bash
docker compose -f docker-compose.aigw2.yml up -d --force-recreate kong-dp-2.0
docker compose -f docker-compose.otel.yml up -d otel-collector jaeger
```

## Verify

Config-side, live-verified in this task:

```bash
GWID="1116b436-b0ba-4585-aa98-30629b1cfd0a"
curl -s -H "Authorization: Bearer ${KONGCTL_DEFAULT_KONNECT_PAT}" \
  "${KONNECT_AIGW2_BASE_URL}/v1/ai-gateways/${GWID}/policies" \
  | jq '.data[] | select(.name=="claude-otel-tracing") | {global, enabled, config: {traces_endpoint, logs_endpoint, resource_attributes, sampling_rate: .config.sampling_rate}}'
```

confirmed:

```json
{
  "global": false,
  "enabled": true,
  "config": {
    "traces_endpoint": "http://otel-collector:4318/v1/traces",
    "logs_endpoint": "http://otel-collector:4318/v1/logs",
    "resource_attributes": {"service.name": "claude-ai-gateway-2.0"},
    "sampling_rate": 1
  }
}
```

and `claude-chat`'s `policies` array includes `claude-otel-tracing`
alongside `team-model-listing`/`claude-token-rate-limit`.

Traffic-side (NOT run here — no Docker, no serverless proxy URL, same
constraint as every prior module), for a future Docker-enabled run —
`scripts/verify-2.0.sh 07-opentelemetry`:

```bash
for i in $(seq 1 5); do
  curl -s -o /dev/null "${BASE_URL}/anthropic" \
    -H "Authorization: Bearer ${OKTA_ACCESS_TOKEN}" \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"claude-chat","max_tokens":16,"messages":[{"role":"user","content":"say hi"}]}'
done
curl -s http://localhost:16686/api/services | grep -q claude-ai-gateway-2.0
```

Expected, per the shakeout's own resolved-Issue-21 result in its
environment (cited, not this module's own observation): real spans arrive
at the collector once both the policy config and the DP env vars are set
together — that shakeout run saw 25 spans from a batch of requests
(`{"otelcol.signal": "traces", "resource spans": 1, "spans": 25}`). No
live span count was observed in this task.

---

Next: Task 9 wires all seven 2.0-track modules into the top-level README.
