---
name: pst:docker
description: Containerize by default. Run project runtimes, datastores, and tools in dedicated per-use-case Docker containers, never a host or system-level daemon. Auto-applied by the pst shim on container and provisioning changes; also invocable directly.
auto:
  basenames: [Dockerfile, .dockerignore, docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml, Brewfile, devcontainer.json]
  paths:
    - "**/Dockerfile"
    - "**/Dockerfile.*"
    - "**/docker-compose*.y*ml"
    - "**/compose*.y*ml"
    - "**/.devcontainer/**"
  detect: [Dockerfile, docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml, "**/.devcontainer/**"]
---

# Docker Doctrine Cheat Sheet

Source: Docker best practices + Docker Compose docs + Testcontainers + Twelve-Factor (dev/prod parity)

Doctrine: run project runtimes, datastores, and tools in dedicated, per-use-case containers. Never a host or system-level daemon, and never a global install, for project work.

Question: Can a teammate run this from a clean machine with only Docker installed?

Favor:
- One dedicated container per datastore or service, isolated per use case; orchestrate locally with Compose.
- Point connection strings (`DATABASE_URL`, `REDIS_URL`) at the container and keep them in the environment.
- Pin base images by tag and digest; prefer slim or distroless bases.
- Multi-stage builds; copy only what runs; run as a non-root user.
- A `.dockerignore` that excludes `node_modules`, `.git`, secrets, and build output.
- Testcontainers for integration tests, with an ephemeral container per run.
- Named volumes for data that must survive; treat the container itself as disposable.

Forbid by default:
- Homebrew or system-level daemons for project services (`brew install` or `brew services` for `postgresql`, `redis`, ...).
- Host `initdb`, `pg_ctl`, `redis-server`, or a shared default-port cluster as the project database.
- Global installs for project tooling (`npm i -g`, language-level globals).
- Mutable `:latest` base tags in committed images.
- Secrets baked into an image layer or a committed compose file.
- Writing durable data to the container's ephemeral layer.

CI:
- `out=$(git diff --name-only --diff-filter=AM origin/HEAD -- '*.md' Makefile '*.mk' '*.sh' justfile Brewfile package.json | xargs -I{} git grep -niP "brew (install|services).*(postgres|redis|mysql|mongo)|\\b(initdb|pg_ctl|redis-server|mysqld)\\b|postgresql@\\d" -- {}); [ -z "$out" ]`
- `out=$(git diff --name-only --diff-filter=AM origin/HEAD -- '*Dockerfile*' 'docker-compose*.y*ml' 'compose*.y*ml' | xargs -I{} git grep -nP ":latest\\b" -- {}); [ -z "$out" ]`

Agent protocol:
1. Provision each service as a dedicated container, one per use case.
2. Keep connection strings in the environment, pointed at the container.
3. Make the image reproducible: pinned base, multi-stage, non-root, `.dockerignore`.
4. Treat containers as disposable; persist only declared volumes.
5. Preserve behavior.
