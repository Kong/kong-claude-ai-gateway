# kong-claude-ai-gateway

A test lab for running the Claude Desktop app against 3rd-party inference
routed through Kong: Konnect (control plane) + a local Kong Gateway data
plane acting as the "Claude Gateway". Walks through progressively advanced
use cases — auth, per-user model limits, rate limiting, observability,
tracing, metering — each layered on one long-running gateway.

Full design spec: [`REPO_PLAN.md`](REPO_PLAN.md).

## Architecture

```
                        ┌───────────────────┐
                        │  Konnect (cloud)  │
                        │  control plane +  │
                        │  vault (API key)  │
                        └───────────────────┘
                                 │ hybrid mTLS
                                 ▼
┌───────────┐           ┌────────────────┐           ┌─────────────────────┐
│   Claude  │           │  Kong Gateway  │           │  api.anthropic.com  │
│  Desktop  │── HTTP ──▶│  (data plane,  │─ HTTPS ──▶│      (3rd-party     │
│    app    │           │    Docker)     │           │      inference)     │
└───────────┘           └────────────────┘           └─────────────────────┘
                                 │
                        ┌─────────┴─────────┐
                        ▼         ▼         ▼
                       Prometheus  Grafana    Jaeger / OTel
                       (metrics) (dashboards) (traces)
```

## Quick start

```bash
cp .env.example .env        # fill in KONNECT_TOKEN, ANTHROPIC_API_KEY, etc.
scripts/00-bootstrap-konnect.sh
docker compose up -d        # kong-dp only — enough for modules 1-5
```

Modules 6-7 need the observability/otel overlays too:
`docker compose -f docker-compose.yml -f docker-compose.observability.yml -f docker-compose.otel.yml up -d`

Then point Claude Desktop at the gateway per
[`claude-desktop/README.md`](claude-desktop/README.md).

Full walkthrough starts at [`docs/00-prerequisites.md`](docs/00-prerequisites.md).

## Modules

| # | Module | Doc | Status |
|---|--------|-----|--------|
| 0 | Prerequisites (one-time) | [docs/00-prerequisites.md](docs/00-prerequisites.md) | ✅ implemented |
| 1 | General proxying & setup | [docs/01-general-proxying.md](docs/01-general-proxying.md) | ✅ implemented |
| 2 | Key auth at Kong | [docs/02-key-auth.md](docs/02-key-auth.md) | ✅ implemented |
| 3 | OIDC + Okta | [docs/03-oidc-okta.md](docs/03-oidc-okta.md) ([Okta setup](docs/okta-setup.md)) | ✅ implemented |
| 4 | Per-user model access limits | [docs/04-per-user-model-limits.md](docs/04-per-user-model-limits.md) | ✅ implemented |
| 5 | Consumer-based rate limiting | [docs/05-consumer-rate-limiting.md](docs/05-consumer-rate-limiting.md) | ✅ implemented |
| 6 | Kong observability (Konnect built-in dashboarding) | [docs/06-observability.md](docs/06-observability.md) | ✅ implemented |
| 7 | OpenTelemetry tracing + external (Grafana) observability | [docs/07-opentelemetry.md](docs/07-opentelemetry.md) | ✅ implemented |
| 8 | Metering & billing integration | docs/08-metering-billing.md | planned |

Modules are cumulative — each `kong/NN-*.yaml` is the full desired state
applied via `deck gateway apply`, so `git diff` between module files shows
exactly what changed. Nothing is torn down between modules 1-8; only
prerequisites is a true one-time step. Modules 6 and 7's `prometheus`/
dashboard pieces are the exception — applied directly via the Konnect
Admin API rather than decK (`scripts/push-konnect-dashboard.sh`,
`scripts/enable-prometheus-metrics.sh`); see their docs for why.

## AI Gateway 2.0 (parallel track)

A second, independently runnable track covering the same modules against
Kong's **AI Gateway 2.0** — a separate control-plane type and data-plane
binary, configured via `kongctl` instead of `decK`. Runs alongside the 1.x
stack above (offset ports, separate `.env.2.0`) — see
[`docs-2.0/00-prerequisites-2.0.md`](docs-2.0/00-prerequisites-2.0.md) to
start.

Every module below was built and verified in an environment with no Docker
socket access, and AI Gateway 2.0 currently has no serverless/Konnect-hosted
proxy URL for this control plane (`proxy_urls: []`, confirmed repeatedly) —
so every row splits into two halves: the Konnect-side config is genuinely
live-verified (created via `kongctl apply`, confirmed via direct `GET`
calls, zero `kongctl diff` drift), but no actual HTTP traffic was ever sent
through a data plane. Treat the "traffic untested" half as a real gap, not
a formality — see each doc's status banner for the full trail.

| # | Module | Doc | Status |
|---|--------|-----|--------|
| 0 | Prerequisites (one-time) | [docs-2.0/00-prerequisites-2.0.md](docs-2.0/00-prerequisites-2.0.md) | ✅ Konnect bootstrap (CP, config store, vault) verified live · ⚠️ Docker Compose data-plane bring-up not exercised |
| 1 | General proxying & setup | [docs-2.0/01-general-proxying-2.0.md](docs-2.0/01-general-proxying-2.0.md) | ✅ config verified (model + providers, zero drift) · ❌ traffic untested — central open question (KOKO-3854) not re-tested |
| 2 | Key auth at Kong | [docs-2.0/02-key-auth-2.0.md](docs-2.0/02-key-auth-2.0.md) | ✅ config verified — note: `global: true` (gates the whole control plane, unlike 1.x's scoped key-auth) · ⚠️ traffic untested · ⚠️ credential secret value not retrievable after creation (beta API limitation) |
| 3 | OIDC + Okta | [docs-2.0/03-oidc-okta-2.0.md](docs-2.0/03-oidc-okta-2.0.md) | ✅ config verified twice, real Okta token minted · ❌ traffic untested |
| 4 | Per-user model access limits | [docs-2.0/04-per-user-model-limits-2.0.md](docs-2.0/04-per-user-model-limits-2.0.md) | ✅ config verified — note: single-model `pre-function` branching, not the naive multi-model design, because that design hits a real Kong bug (KOKO-3852, WONT-FIX) · ❌ traffic untested |
| 5 | Consumer-based rate limiting | [docs-2.0/05-consumer-rate-limiting-2.0.md](docs-2.0/05-consumer-rate-limiting-2.0.md) | ✅ config verified against real plugin schema, per-model scope confirmed · ❌ traffic untested — no 429 observed |
| 6 | Kong observability | [docs-2.0/06-observability-2.0.md](docs-2.0/06-observability-2.0.md) | ✅ dashboard created and confirmed live via the Konnect API — filtered by `ai_request_model`, not `route` (no route-equivalent exists for AI Gateway 2.0) |
| 7 | OpenTelemetry tracing | [docs-2.0/07-opentelemetry-2.0.md](docs-2.0/07-opentelemetry-2.0.md) | ✅ policy config verified against real schema, per-model scope confirmed · ❌ span export unverified — no data plane to confirm the process-level env vars this needs |
| 8 | Metering & billing integration | — | planned (both tracks) |

Every status above reflects a real, live-verified result against a Konnect
org as of this table's last edit — not an assumption. See each module's doc
for the exact date/build tested.

## Repo layout

```
├── docker-compose.yml               # kong data plane only
├── docker-compose.observability.yml # module 7: prometheus + grafana (layer on top)
├── docker-compose.otel.yml          # module 7: jaeger + otel-collector (layer on top)
├── docker-compose.aigw2.yml  # AI Gateway 2.0 hybrid data plane overlay
├── .env.example
├── .env.2.0.example       # AI Gateway 2.0 track: kongctl PAT, config store, consumer key vars
├── scripts/               # bootstrap, verify, teardown,
│                          # push-konnect-dashboard (module 6), enable-prometheus-metrics (module 7)
├── kong/                  # one decK YAML per module, cumulative (except module 6, see its doc)
├── kong-2.0/               # AI Gateway 2.0 track: one kongctl YAML per module, cumulative
├── observability/         # prometheus.yml, grafana provisioning + dashboards, otel-collector config,
│                          # claude-code-usage-dashboard.json (module 6), prometheus-plugin.json (module 7)
├── claude-desktop/        # Desktop app settings, per module
├── docs/                  # one walkthrough per module
└── docs-2.0/                # AI Gateway 2.0 track: one walkthrough per module
```

## Secrets

The real Anthropic API key lives only in a Konnect vault, seeded once from
your local `.env` (git-ignored) via `scripts/00-bootstrap-konnect.sh`.
`kong/*.yaml` files reference it as `{vault://anthropic-api-key/anthropic-api-key}`
— never inline. Don't commit `.env` or anything under `certs/`.
