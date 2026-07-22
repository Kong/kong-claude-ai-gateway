# kong-claude-ai-gateway

A test lab for running the Claude Desktop app against 3rd-party inference
routed through Kong: Konnect (control plane) + a local Kong Gateway data
plane acting as the "Claude Gateway". Walks through progressively advanced
use cases — auth, per-user model limits, rate limiting, observability,
tracing, metering — each layered on one long-running gateway.

Full design spec: [`REPO_PLAN.md`](REPO_PLAN.md).

## Architecture

```
                    ┌─────────────────────┐
                    │   Konnect (cloud)    │
                    │  control plane +     │
                    │  vault (API key)     │
                    └──────────┬───────────┘
                               │ hybrid mTLS
                               ▼
┌────────────┐        ┌───────────────┐        ┌──────────────────┐
│   Claude    │  HTTP   │   Kong Gateway │  HTTPS  │  api.anthropic.com│
│  Desktop    ├────────▶│  (data plane,  ├────────▶│  (3rd-party       │
│    app      │         │   Docker)      │         │   inference)      │
└────────────┘        └───────┬───────┘        └──────────────────┘
                               │
                     ┌─────────┼─────────┐
                     ▼         ▼         ▼
               Prometheus  Grafana   Jaeger / OTel
               (metrics)  (dashboards) (traces)
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

## Repo layout

```
├── docker-compose.yml               # kong data plane only
├── docker-compose.observability.yml # module 7: prometheus + grafana (layer on top)
├── docker-compose.otel.yml          # module 7: jaeger + otel-collector (layer on top)
├── .env.example
├── scripts/               # bootstrap, verify, teardown,
│                          # push-konnect-dashboard (module 6), enable-prometheus-metrics (module 7)
├── kong/                  # one decK YAML per module, cumulative (except module 6, see its doc)
├── observability/         # prometheus.yml, grafana provisioning + dashboards, otel-collector config,
│                          # claude-code-usage-dashboard.json (module 6), prometheus-plugin.json (module 7)
├── claude-desktop/        # Desktop app settings, per module
└── docs/                  # one walkthrough per module
```

## Secrets

The real Anthropic API key lives only in a Konnect vault, seeded once from
your local `.env` (git-ignored) via `scripts/00-bootstrap-konnect.sh`.
`kong/*.yaml` files reference it as `{vault://anthropic-secrets/anthropic-api-key}`
— never inline. Don't commit `.env` or anything under `certs/`.
