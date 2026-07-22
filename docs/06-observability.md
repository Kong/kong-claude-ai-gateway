# 06 — Kong observability (Konnect built-in dashboarding)

## What this adds

A **Konnect Advanced Analytics custom dashboard** ("Claude Code Usage") —
a native Konnect feature, not Grafana, not decK, no local infra. 16 tiles
against Konnect's own `llm_usage` datasource: cost, tokens, request counts,
per-model and per-consumer ("dev") breakdowns, latency, and a security
report (4xx by route). Viewable directly in the Konnect UI under
**Analytics → Dashboards** — nothing to run locally to see it.

Why it matters: this is the "zero-infrastructure" observability option —
Konnect already collects this telemetry from every control-plane-connected
data plane, so there's no Prometheus, no Grafana, no otel-collector to run.
If you only need dashboards for stakeholders who won't be SSHing into your
laptop, this is the one to point them at.

(Module 7's Grafana-based dashboard is the separate, external-tooling
option — see [docs/07-opentelemetry.md](07-opentelemetry.md) and
`observability/grafana/dashboards/ai-usage.json`. The two are independent:
this module doesn't need the `prometheus` plugin or any local containers,
and module 7 doesn't touch Konnect's own dashboarding.)

## How this module is applied

A plain JSON file,
[`observability/claude-code-usage-dashboard.json`](../observability/claude-code-usage-dashboard.json),
pushed straight to the Konnect Admin API's dashboards resource
(`POST`/`PUT` `/v2/dashboards`) by
[`scripts/push-konnect-dashboard.sh`](../scripts/push-konnect-dashboard.sh):

```bash
./scripts/push-konnect-dashboard.sh
```

The script is idempotent — it looks up a dashboard named "Claude Code
Usage" and `PUT`s it if found (this API doesn't support `PATCH`, only full
replace), or creates one if not. It also rewrites the checked-in file's
`preset_filters` route reference to your actual `claude-chat-route` ID at
push time, so the repo doesn't hardcode an environment-specific UUID.

**Note on the dashboard's origin:** the "Claude Code Usage" tile layout
came from a dashboard already built manually in the Konnect UI before this
module existed — exported and dropped into `observability/`. If you
customize it further in the UI, re-running this script overwrites those
changes (full replace, no partial update, no diffing). Check the dashboard
in Konnect after running this if you're not sure your UI edits survived.

## Verify

Open the Konnect UI → **Analytics → Dashboards → Claude Code Usage**.
Tiles populate once a request actually completes through `ai-proxy-advanced`
to Anthropic — a plain `302` redirect from `openid-connect` (unauthenticated
request) won't produce any `llm_usage` data. You need a real authenticated
chat completion (module 3's Okta login, then a chat through `/anthropic`).

---

Next: module 7, OpenTelemetry tracing + external (Grafana) observability.
