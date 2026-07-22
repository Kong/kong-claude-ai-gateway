# claude-gateway-test-lab — Setup Spec for Claude Code

## Goal
Build a GitHub repo that lets someone test the Claude Desktop app against 3rd-party
inference routed through Kong (Konnect control plane + local Kong Gateway data plane
acting as the "Claude Gateway"). The repo walks a tester through 8 progressively
advanced use cases, each building on the previous one's running configuration.

## Confirmed decisions
- Control plane: Kong Konnect (cloud). Data plane: Kong Gateway running in Docker,
  connected to Konnect via a control-plane connection (cert/token from Konnect).
- Config management: decK, one YAML file per module, applied cumulatively
  (`deck gateway apply`), so `git diff` between module folders shows exactly what changed.
- Modules are incremental: one long-running gateway; each step layers new config
  on top of the last. Do not tear down between steps 1-8; only the prerequisites
  step is a true one-time setup.
- Okta and any billing integration: bring-your-own tenant. Repo documents exact
  console steps and expects the user to supply their own Okta domain/app
  credentials and (for module 8) their own billing/metering target via `.env`.
- Observability stack: Prometheus + Grafana (metrics/dashboards) and Jaeger
  (traces), all run locally via the same Docker Compose file as the data plane.

## Repo layout

```
claude-gateway-test-lab/
├── README.md                     # overview, architecture diagram, quick start, module index
├── .env.example                  # KONNECT_TOKEN, KONNECT_CONTROL_PLANE, OKTA_*, ANTHROPIC_API_KEY, billing vars
├── docker-compose.yml             # kong data plane only
├── docker-compose.observability.yml  # module 7: prometheus + grafana (layer on top)
├── docker-compose.otel.yml        # module 7: jaeger + otel-collector (layer on top)
├── scripts/
│   ├── 00-bootstrap-konnect.sh    # creates/verifies Konnect control plane, outputs cert for data plane
│   ├── push-konnect-dashboard.sh  # module 6: pushes the Konnect Analytics dashboard via Admin API
│   ├── enable-prometheus-metrics.sh  # module 7: pushes the prometheus plugin via Admin API
│   ├── verify.sh <module>         # curl-based smoke test per module, prints pass/fail
│   └── teardown.sh                # tears down docker stack + optionally Konnect CP
├── kong/
│   ├── 01-general-proxying.yaml
│   ├── 02-key-auth.yaml
│   ├── 03-oidc-okta.yaml
│   ├── 04-per-user-model-limits.yaml
│   ├── 05-consumer-rate-limiting.yaml
│   ├── 07-opentelemetry.yaml      # module 6 has no kong/*.yaml — Admin-API-only, see its doc
│   └── 08-metering-billing.yaml
├── observability/
│   ├── prometheus.yml
│   ├── prometheus-plugin.json     # module 7
│   ├── claude-code-usage-dashboard.json  # module 6
│   ├── grafana/dashboards/*.json
│   └── otel-collector-config.yaml
├── claude-desktop/
│   └── README.md                  # exact Desktop app settings to point at gateway (per module, only changes when auth changes)
└── docs/
    ├── 00-prerequisites.md
    ├── 01-general-proxying.md
    ├── 02-key-auth.md
    ├── 03-oidc-okta.md
    ├── 04-per-user-model-limits.md
    ├── 05-consumer-rate-limiting.md
    ├── 06-observability.md
    ├── 07-opentelemetry.md
    └── 08-metering-billing.md
```

## Prerequisites (one-time, docs/00-prerequisites.md)
1. Konnect account + Personal Access Token, and a Control Plane created for this lab.
2. Docker + Docker Compose installed locally.
3. `deck` CLI installed and authenticated against Konnect.
4. Anthropic API key (upstream credential the gateway uses for real inference).
5. Claude Desktop app installed, with instructions for pointing it at a
   custom/3rd-party base URL (this is the one Desktop-app-side config that stays
   constant across modules 1-2 and only changes when auth semantics change, e.g.
   module 3 OIDC and module 4/5 per-consumer credentials).
6. Bring your own Okta tenant (admin access to create an OIDC app) — needed
   starting at module 3.
7. `scripts/00-bootstrap-konnect.sh` + `docker compose up -d` to bring up the
   data plane, Prometheus, Grafana, and Jaeger once.

## Module breakdown (each docs/NN-*.md follows this template)
Each module doc should contain: what capability this adds and why it matters,
the decK config diff versus the previous module, the exact `deck apply`
command, and the exact Claude Desktop app configuration change (if any).
Simple is better — keep it to what's needed to apply and use the module.

1. **General proxying & setup** — Service/Route pointing Kong at the Anthropic
   API (or an OpenAI-compatible 3rd-party inference endpoint) with no auth;
   confirm Claude Desktop can complete a chat through the gateway at all.
2. **Key auth at Kong** — add `key-auth` plugin + a Consumer; Desktop app must
   now send an API key Kong issues, not the raw Anthropic key.
3. **OIDC + Okta** — swap/add `openid-connect` plugin, Okta app registration
   steps, token exchange flow, mapping Okta claims to a Kong Consumer.
4. **Per-user model access limits** — request transformer / ai-proxy plugin
   config restricting which models a given authenticated consumer/claim can call.
5. **Consumer-based rate limiting** — `rate-limiting` (or `rate-limiting-advanced`)
   scoped per Consumer, tied to the identities established in modules 2-3.
6. **Kong Observability** — push a custom dashboard to Konnect's built-in
   Advanced Analytics via the Admin API (no local infra, no decK).
7. **OpenTelemetry + external observability** — enable the `opentelemetry`
   plugin, ship traces to the local OTel Collector → Jaeger, correlate a
   single request across Desktop → Kong → Anthropic; also wires the
   `prometheus` plugin and a purpose-built Grafana "AI Usage" dashboard
   (model/token/cost/developer breakdowns) as the external-tooling
   alternative to module 6.
8. **Metering & billing integration** — AI Gateway token-usage metering (Kong's
   `ai-proxy`/analytics token counts), forwarding usage events to a
   user-supplied billing webhook/target defined in `.env`.

## Deliverable checklist for Claude Code
- [ ] Top-level README with architecture diagram (ASCII is fine) and module table
- [ ] `.env.example` covering every variable referenced anywhere in the repo
- [ ] Docker Compose stack that starts cleanly with `docker compose up -d`
- [ ] One decK YAML per module, cumulative, applied via `deck gateway apply`
      (each module doc has the exact `export`+`deck` block to run)
- [ ] One `verify.sh` per module doing a real HTTP call and checking status/behavior
- [ ] `claude-desktop/README.md` with screenshots-optional, step-by-step settings
- [ ] Every docs/NN file follows the template above
- [ ] `scripts/teardown.sh` cleanly removes local containers and optionally the
      Konnect control plane
