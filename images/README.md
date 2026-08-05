# images/

Screenshots and diagrams referenced from `README.md`.

- `step1-deploy/` — Konnect console walkthrough for Step 1 (generating a
  Personal Access Token, the created AI Gateway, and configuring/
  connecting a self-managed Docker data plane).
- `step2-vault/` — Konnect console walkthrough for Step 2 (adding
  `claude-gateway-vault` and storing secrets in it via the UI).
- `step3-models/` — Konnect console walkthrough for Step 3 (the Claude
  models listed under the AI Gateway's **Models** tab after applying
  `2-claude-integration.yaml`, plus a real client's connection/model-
  discovery test against the gateway).
- `step4-sso/` — a real client's connection test for Step 4: failing on
  inference with a static key once SSO is enabled, then the interactive
  OIDC sign-in config that gets a real token instead.
- `step5-filtering/` — a real client's connection test for Step 5: model
  discovery returning the filtered, group-specific list instead of the
  full catalog.
- `step5-dashboard/` — Konnect console walkthrough for Step 6 (the
  imported usage dashboard).

Add more subdirectories per step as you work through Step 7 (spend-limit
screens, etc.) and link them with relative paths, e.g.
`![Spend limit](images/step7-budgets/limit-hit.png)`.
