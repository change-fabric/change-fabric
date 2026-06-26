---
name: pst:postgres-sql
description: PostgreSQL schema and SQL changes. Auto-applied by the pst shim on every SQL migration change; also invocable directly.
auto:
  extensions: [sql]
  detect: ["db/**/*.sql", "migrations/**/*.sql", "prisma/migrations/**/migration.sql"]
---

# PostgreSQL and SQL Cheat Sheet

Source: PostgreSQL docs + OWASP SQL Injection Prevention Cheat Sheet

Question: Does the schema enforce invariants and let writes stay online?

Favor:
- Enforce invariants with `PRIMARY KEY`, `UNIQUE`, `FK`, `CHECK`, and `NOT NULL`.
- Add indexes for new foreign keys and hot predicates.
- Parameterize values with placeholders.
- Use explicit transactions for multi-statement writes.
- Use `INSERT ... ON CONFLICT` for idempotent upserts.
- Backfill in batches before tightening constraints.
- Use `CREATE INDEX CONCURRENTLY` or `DROP INDEX CONCURRENTLY` on large live tables.
- Run dev and test Postgres in a dedicated Docker container (a Compose service or `docker run`), one per use case; point `DATABASE_URL` at it and use Testcontainers for tests (pst:docker doctrine).

Forbid by default:
- A Homebrew or system-level Postgres daemon for project work (`brew install` or `brew services` for `postgresql`, host `initdb` or `pg_ctl`, a shared default-port cluster).
- String-built SQL with interpolated values.
- `SELECT *` in application queries.
- `SERIAL`; prefer `GENERATED ... AS IDENTITY`.
- `DELETE` or `UPDATE` without `WHERE` outside migrations.
- Long transactions around network I/O.
- Lock-heavy table rewrites without phased rollout.

CI:
- `sqlfluff lint --dialect postgres`
- `out=$(git diff --name-only --diff-filter=AM origin/HEAD -- '*.sql' | xargs -I{} git grep -niP "SELECT \\*|\\b(BIG|SMALL)?SERIAL\\b|\\bDROP TABLE\\b|\\bTRUNCATE\\b" -- {}); [ -z "$out" ]`

Agent protocol:
1. Encode invariants in DDL, not app code.
2. Make online changes in phases.
3. Parameterize every value and bound every write.
4. Preserve behavior.
