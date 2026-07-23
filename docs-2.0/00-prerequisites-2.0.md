# 00 — Prerequisites (AI Gateway 2.0 track, one-time setup)

> **Status:** ✅ Konnect-side bootstrap (control plane, config store, vault) verified live 2026-07-23 against the Fel Tech org (`kongctl` 1.6.0). ⚠️ Docker Compose data-plane bring-up (§5) not yet exercised in this environment (no Docker socket access) — `docker-compose.aigw2.yml` validated for syntax only.

This is the AI Gateway 2.0 counterpart to [`docs/00-prerequisites.md`](../docs/00-prerequisites.md)
— a genuinely separate track, not a variant of the 1.x setup. AI Gateway 2.0
is a distinct control-plane type and a forked data-plane binary; the two
tracks can run side by side (ports are offset — see
[`docker-compose.aigw2.yml`](../docker-compose.aigw2.yml)).

## vs. 1.x

| | 1.x | 2.0 |
|---|---|---|
| Config tool | `decK` | `kongctl` |
| Control plane type | generic Gateway CP | `ai_gateway` resource |
| Vault | global, referenced from any `kong/*.yaml` | `ai_gateway_vault`, scoped to the AI Gateway CP |
| Config schema | `_format_version: "3.0"` decK YAML, `ai-proxy-advanced` plugin | `ai_gateway_model`/`ai_gateway_policy`/etc, kongctl declarative resources |
| Konnect environment | `us.api.konghq.com` | `us.api.konghq.tech` (as of this writing — AI Gateway 2.0 has not GA'd onto `.com` yet) |

## 1. `kongctl` CLI

Install: `curl -fsSL https://get.konghq.com/kongctl | sh` (>= 1.6.0). Confirm:
`kongctl version`.

## 2. Konnect Personal Access Token

Same Konnect org as the 1.x track, or a different one — AI Gateway 2.0 is a
separate control-plane type within the same org, but it currently lives on
a different Konnect API environment (`us.api.konghq.tech`, not `.com`).
Generate a PAT the same way as [`docs/00-prerequisites.md`](../docs/00-prerequisites.md)
step 1. Copy `.env.2.0.example` to `.env.2.0` and fill in
`KONGCTL_DEFAULT_KONNECT_PAT`.

## 3. Bootstrap the AI Gateway 2.0 control plane + vault

```bash
scripts/00-bootstrap-konnect-2.0.sh
```

This is fully automated and idempotent — no manual Konnect UI steps for the
control plane or vault:

1. `kongctl apply -f kong-2.0/00-platform.yaml` creates (or verifies) the
   `claude-ai-gateway` control plane.
2. The script then looks up that control plane's ID via the Konnect API and
   creates a config store (`claude-ai-gateway-secrets`) if it doesn't
   already exist.
3. It seeds that config store with whatever of `ANTHROPIC_API_KEY`,
   `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` you've set in
   `.env.2.0` (skipping any that are blank, and skipping any secret key
   that already exists — re-running the script never overwrites a stored
   secret; delete it in the Konnect UI first to rotate it).
4. It creates the `ai_gateway_vault` named `ai-vault` pointing at that
   config store. Every `kong-2.0/*.yaml` in this repo references secrets as
   `{vault://ai-vault/<key>}` — the real values never appear in a
   committed file.

There is no equivalent of the 1.x track's "create a config store by hand in
the UI" step — the Konnect API supports creating both the config store and
the vault entity directly, so the script does it for you.

## 4. Generate a data plane client certificate (still manual)

The script prints this as the one remaining manual step, because it's a
few clicks and there's no API shortcut worth scripting for a one-time
cert: **AI Gateway → `claude-ai-gateway` → Data Plane Nodes → New Data
Plane Node** → generate/download a client certificate → save as
`tls.crt` / `tls.key` under `${CERTS_DIR_2_0:-./certs-2.0}`.

`chmod 644` the key — not `600`. A stricter `600` crashes `kong-gateway` at
`init_by_lua` with `tls.key: Permission denied` in this image, because the
container process doesn't own the file the same way the host user does.

Then copy the control plane's endpoints (same screen) into `.env.2.0` as
`KONNECT_AIGW2_CP_ENDPOINT` / `KONNECT_AIGW2_TELEMETRY_ENDPOINT` — the
bootstrap script also prints these directly so you can skip hunting for
them in the UI.

## 5. Bring up the 2.0 data plane

> **Note:** This step has not yet been live-verified in this repository's CI/sandbox environment. After running the commands below, confirm in the Konnect UI (`claude-ai-gateway` → Data Plane Nodes) that a node appears in `Connected` state.

```bash
docker compose -f docker-compose.aigw2.yml up -d
docker compose -f docker-compose.aigw2.yml ps
```

Runs on offset ports (proxy `:8010`/`:8453`, Admin API `:8011`, status
`:8110`) so it can run alongside the 1.x stack without conflict. Confirm
`kong-dp-2.0` is `healthy`, then check the Konnect UI (`claude-ai-gateway`
→ Data Plane Nodes) for a `Connected` node.

---

Once done, move on to
[`docs-2.0/01-general-proxying-2.0.md`](01-general-proxying-2.0.md).
