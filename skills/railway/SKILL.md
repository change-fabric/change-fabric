---
name: cf:railway
description: Railway deploy and service configuration. Auto-applied by the cf shim on every Railway deploy change; also invocable directly.
auto:
  basenames: [railway.toml, railway.json, .railwayignore, Dockerfile]
  detect: [railway.toml, railway.json, .railwayignore, Dockerfile]
---

# Railway Deploy Cheat Sheet

Source: Railway CLI docs + Railway variables docs + Railway healthchecks docs + Railway config-as-code docs

Question: Can this service boot from config, prove health, and redeploy safely?

Favor:
- Keep service config in `railway.toml` or `railway.json`.
- Store secrets in Railway variables; reference them, never inline them.
- Distinguish build-time vars from runtime vars.
- Expose `/health` and configure a healthcheck.
- Run schema migrations in pre-deploy or one-shot release steps.
- Handle `SIGTERM` and drain connections before exit.
- Use `railway up --ci` in automation.

Forbid by default:
- Secrets in repo, Dockerfile, or config-as-code.
- Mutable image tags like `:latest`.
- Missing healthcheck on HTTP services.
- Running migrations on every app boot.
- Writing durable data to the ephemeral filesystem.

CI:
- `railway up --ci`
- `railway variables --kv`
- `railway logs --build --lines 200`
- `curl -fsS "https://${RAILWAY_PUBLIC_DOMAIN}/health"`

Agent protocol:
1. Separate config, secrets, build, and runtime concerns.
2. Make startup and shutdown explicit.
3. Prove deploy health before calling it done.
4. Preserve behavior.
