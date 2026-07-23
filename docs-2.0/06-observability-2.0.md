# 06 — Konnect observability (AI Gateway 2.0 track)

> **Status (2026-07-23, verified against Fel Tech org / `us.api.konghq.tech`):**
> ✅ **Dashboard actually created and confirmed live via the Konnect API.**
> `scripts/push-konnect-dashboard-2.0.sh` ran end-to-end twice (create, then
> update) against the real org — no Docker needed, this module is a pure
> cloud-API call, same as the 1.x track's script. `GET /v2/dashboards`
> confirms `Claude AI Gateway 2.0 Usage` exists
> (`id: 4b64e03a-671a-4064-ae08-9da0afd6226f`), with 16 tiles and
> `preset_filters` scoped to this gateway + the `claude-chat` model (exact
> payload below).
> ⚠️ **The route-based scoping the 1.x script uses has no equivalent for AI
> Gateway 2.0 — confirmed by direct API probing, not assumed.** AI Gateway
> 2.0 control planes are a different resource type
> (`/v1/ai-gateways/{id}`) from classic Gateway CPs
> (`/v2/control-planes/{id}`); they don't appear in `/v2/control-planes` at
> all, and both `/v2/control-planes/{aigw-id}/core-entities/routes` and
> `/v1/ai-gateways/{id}/routes` / `/v1/ai-gateways/{id}/core-entities/routes`
> return 404. A `claude-chat` model's route only exists as **embedded
> config** (`config.route.paths`, e.g. `["/anthropic"]`) inside
> `GET /v1/ai-gateways/{id}/models` — not as a standalone, filterable
> entity with its own id the way a decK-authored Route is in 1.x. This
> script scopes the dashboard on `ai_request_model` (the model alias
> string) and `control_plane` (the gateway id) instead — see "vs. 1.x"
> below for how that was found.
> ✅ **`.com` vs `.tech` resolved live, and the brief's assumption was
> wrong.** `/v2/dashboards` and the rest of the Analytics/Dashboards API
> are reachable on `us.api.konghq.tech` with the same PAT used for
> `/v1/ai-gateways` calls — no `.com` token or base URL needed. Confirmed
> the two environments really are separate credentials, not just separate
> hostnames for the same org: a stray call to `us.api.konghq.com` with the
> `.tech` PAT returned `401 Unauthenticated`.

## What this adds

A **Konnect Advanced Analytics custom dashboard**
("Claude AI Gateway 2.0 Usage") built on the same `llm_usage` datasource as
the 1.x track's dashboard — no Grafana, no `kongctl`, no local infra. Same
16 tiles as [`observability/claude-code-usage-dashboard.json`](../observability/claude-code-usage-dashboard.json)
(cost, tokens, request counts, per-model/per-consumer breakdowns, latency,
security report) — this module reuses that file unmodified and only
rewrites `preset_filters` at push time. View it in the Konnect UI under
**Analytics → Dashboards**.

## vs. 1.x

| | 1.x (`scripts/push-konnect-dashboard.sh`) | 2.0 (`scripts/push-konnect-dashboard-2.0.sh`) |
|---|---|---|
| CP lookup | `GET /v2/control-planes?filter[name]=...` | `GET /v1/ai-gateways`, filter by name client-side (no server-side name filter on this endpoint) |
| Route/model scoping | `GET /v2/control-planes/{cp}/core-entities/routes`, select by decK-authored `.name == "claude-chat-route"` | No route entity exists to query. Model existence confirmed via `GET /v1/ai-gateways/{id}/models`, select by `.config.model.alias == "claude-chat"` |
| Dashboard `preset_filters` | One filter: `{field: "route", value: ["<cp_id>:<route_id>"]}` | Two filters: `{field: "control_plane", value: ["<gateway_id>"]}` **and** `{field: "ai_request_model", value: ["claude-chat"]}` |
| Dashboards API host | `us.api.konghq.com` | `us.api.konghq.tech` — confirmed live, not assumed (see status banner) |
| Dashboard name | `Claude Code Usage` | `Claude AI Gateway 2.0 Usage` |

The `llm_usage` datasource's filter-field contract (queried live via the
Konnect API's dashboard/analytics schema) does still list `route` as a
valid, scoped-uuid filterable field — it just has no reachable id behind
it for an AI Gateway 2.0 CP. `control_plane` (unscoped-uuid) and
`ai_request_model` (string, the model alias) are both valid filterable
fields on the same datasource and were confirmed to accept the real
gateway id / `claude-chat` alias without a validation error when queried
live (empty result sets, as expected — no traffic has flowed through this
CP in this sandbox; see the 05/consumer-rate-limiting doc for why: no
Docker, no serverless proxy URL for this environment).

Filtering on `ai_request_model` alone would already scope the dashboard to
`claude-chat` traffic across the whole org; adding `control_plane` narrows
it further to just this gateway, in case another AI Gateway 2.0 CP in the
same org also has a model aliased `claude-chat`.

## How this module is applied

```bash
./scripts/push-konnect-dashboard-2.0.sh
```

The script:

1. Looks up the `claude-ai-gateway` gateway id via `GET /v1/ai-gateways`.
2. Confirms the `claude-chat` model alias exists on that gateway via
   `GET /v1/ai-gateways/{id}/models` (fails fast with a clear message if
   module 1/2 haven't been applied yet).
3. Rewrites `observability/claude-code-usage-dashboard.json`'s
   `preset_filters` in memory (the checked-in file is never modified) to
   `[{field: "control_plane", ...}, {field: "ai_request_model", ...}]`
   scoped to this gateway + model.
4. Creates the dashboard via `POST /v2/dashboards`, or updates it in place
   via `PUT /v2/dashboards/{id}` if a dashboard named
   `Claude AI Gateway 2.0 Usage` already exists (full-replace API, same as
   1.x — no partial update).

Idempotent: re-running twice in a row (live-verified) produces "creating
dashboard..." then "updating existing dashboard (...)" with the same
resulting `preset_filters`.

## Verify

Live-verified via the Konnect API rather than a UI screenshot in this
sandbox:

```bash
curl -s -H "Authorization: Bearer ${KONGCTL_DEFAULT_KONNECT_PAT}" \
  "https://us.api.konghq.tech/v2/dashboards" \
  | jq '.data[] | select(.name=="Claude AI Gateway 2.0 Usage")
        | {id, preset_filters: .definition.preset_filters}'
```

returned:

```json
{
  "id": "4b64e03a-671a-4064-ae08-9da0afd6226f",
  "preset_filters": [
    {"field": "control_plane", "value": ["1116b436-b0ba-4585-aa98-30629b1cfd0a"], "operator": "in"},
    {"field": "ai_request_model", "value": ["claude-chat"], "operator": "in"}
  ]
}
```

In a real Konnect UI session: **Analytics → Dashboards → Claude AI Gateway
2.0 Usage**. Tiles populate once a request completes through the
`claude-chat` model to Anthropic — not exercised here (no Docker, no data
plane traffic in this sandbox, so all tiles will read zero/empty until a
Docker-enabled environment runs real traffic through `/anthropic`).

---

Module 6 is Admin/cloud-API-only in both tracks — no `kong-2.0/*.yaml`
added here, matching the 1.x track's own module 6.
