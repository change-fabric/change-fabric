---
name: cf:redis
description: Redis cache and session usage. Auto-applied by the cf shim on every Redis-related change; also invocable directly.
auto:
  extensions: [js, mjs]
  require:
    - dep: [redis, ioredis]
  detect: [package.json, "**/*redis*.js", "**/*cache*.js", "**/*session*.js"]
---

# Redis Cheat Sheet

Source: Redis command docs + Redis keyspace docs + Redis security docs

Question: Will cache or session failure degrade safely instead of corrupting behavior?

Favor:
- Use Redis for cache, session, rate limit, lock, or queue metadata only.
- Prefix keys as `app:env:domain:id`.
- Set TTL on every cache and session key.
- Use `SET key value EX ... NX` for single-write cache fills and locks.
- Treat misses and outages as recoverable.
- Bound payload size; prefer ids over full documents.
- Use `SCAN` for iteration and bulk maintenance.
- Run dev and test Redis in a dedicated Docker container, one per use case; point `REDIS_URL` at it (cf:docker doctrine).

Forbid by default:
- A Homebrew or system Redis daemon for project work (`brew services start redis`, host `redis-server`).
- `KEYS` in application code.
- `FLUSHALL`, `FLUSHDB`, or `MONITOR` outside ops scripts.
- Cache keys without TTL.
- Using Redis as the source of record.
- Hard-coded Redis URLs or passwords.
- `SETEX` or `SETNX`; use `SET` options instead.

CI:
- `npx --no-install eslint . --max-warnings 0`
- `base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") && l=$(mktemp) && trap 'rm -f "$l"' EXIT && git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- '*.js' '*.mjs' '*.cjs' '*.ts' ':!*.test.*' ':!*.spec.*' ':!**/__tests__/**' >"$l" && f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" && { [ ${#f[@]} -eq 0 ] || { s=0; GIT_LITERAL_PATHSPECS=1 git grep -nP "\\bKEYS\\b|(?i)\\b(flushall|flushdb|monitor|setex|setnx)\\b" -- "${f[@]}" || s=$?; [ $s -eq 1 ]; }; }` (see skills/README.md, CI diff-grep checks)

Agent protocol:
1. Decide whether the key is cache, session, or coordination.
2. Add names, TTLs, and failure fallbacks.
3. Remove blocking and deprecated commands.
4. Preserve behavior.
