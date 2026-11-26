---
name: cf:docker
group: rubrics
review: true
description: Containerize by default. Run project services in dedicated Docker containers, never a host daemon. Auto-applied on container and provisioning changes; also invocable directly.
auto:
  min_level: lean
  basenames: [Dockerfile, .dockerignore, docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml, Brewfile, devcontainer.json]
  paths:
    - "**/Dockerfile"
    - "**/Dockerfile.*"
    - "**/docker-compose*.y*ml"
    - "**/compose*.y*ml"
    - "**/.devcontainer/**"
  detect: [Dockerfile, docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml, "**/.devcontainer/**"]
---

# Docker

- Run every project service (datastore, runtime, reverse proxy) in its own dedicated container; never a host or system daemon (`brew services`, host `initdb`, `redis-server`, `caddy run`) and never a global install.
- Pin base images by tag; no `:latest` in a committed image. Keep secrets out of image layers and compose files.

A one-shot launchd or systemd timer that runs a bounded command and exits is not a daemon. `docker_doctrine_guard.rb` denies the daemon commands.
