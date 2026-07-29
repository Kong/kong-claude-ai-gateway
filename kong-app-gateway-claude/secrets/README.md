# secrets/

Local staging area for real credential values before they're seeded into
the Konnect vault (`claude-gateway-vault`). Everything in this directory
except this file is git-ignored — see `../.gitignore`.

Typical contents (none of these are created by default):

- `claude-gateway.env` — `ANTHROPIC_API_KEY`, `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `OKTA_ISSUER`, `OKTA_CLIENT_ID`,
  `OKTA_CLIENT_SECRET`, `OIDC_CACHE_TOKENS_SALT` — see `.env.example` at
  the repo root of this directory for the full variable list.
- `tls.crt` / `tls.key` — the data-plane client certificate generated in
  Konnect (AI Gateway → this control plane → Data Plane Nodes) for the
  hybrid mTLS connection. See README.md, Step 1.

None of these values ever belong in a committed `*.yaml` file in this
directory — every credential is referenced as `{vault://claude-gateway-vault/<key>}`
and resolved by Kong at runtime, not by kongctl at apply time.
