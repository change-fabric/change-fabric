---
name: cf:drizzle
description: Drizzle ORM schema, migrations, and queries. Auto-applied by the cf shim on every Drizzle change; also invocable directly.
auto:
  paths:
    - "drizzle.config.*"
    - "drizzle/**"
    - "**/schema.{ts,js,mjs,cjs}"
    - "**/db.{ts,js,mjs,cjs}"
    - "**/db/*.{ts,js,mjs,cjs}"
  require:
    - "**/drizzle.config.*"
  exclude:
    - "**/schema.prisma"
    - "prisma/migrations/**"
  detect: [drizzle.config.*, "drizzle/**", "src/**/schema.*", "src/**/db.*"]
---

# Drizzle ORM Cheat Sheet

Source: Drizzle ORM docs + Drizzle Kit docs + SQL docs

Question: Will this schema and query set stay SQL-shaped, migration-safe, and load-safe?

Favor:
- Model invariants with `primaryKey`, `unique`, `notNull`, `check`, and `references`.
- Name tables, columns, indexes, and constraints explicitly.
- Keep migrations generated, reviewed, and committed.
- Keep migrations additive first; backfill before `notNull`.
- Use narrow `select` projections.
- Use `db.transaction()` for multi-write invariants.
- Prefer Drizzle query builders and `sql`` parameter binding.

Forbid by default:
- `drizzle-kit push` for shared environments.
- Editing an applied migration file.
- Raw SQL string concatenation.
- `db.delete(table)` without `where`.
- `db.update(table)` without `where`.
- Per-row queries in loops when a join or batch query would do.

CI:
- `drizzle-kit generate`
- `drizzle-kit check`
- `npx --no-install eslint . --max-warnings=0`

Agent protocol:
1. Model invariants in Drizzle schema.
2. Make migrations additive and safe to roll forward/back.
3. Tighten query shape before optimizing.
4. Preserve behavior.
