---
name: pst:prisma
description: Prisma ORM schema, migrations, and queries. Auto-applied by the pst shim on every Prisma change; also invocable directly.
auto:
  extensions: [prisma]
  detect: [prisma/schema.prisma, "prisma.config.*", "prisma/migrations/**"]
---

# Prisma ORM Cheat Sheet

Source: Prisma Schema docs + Prisma Migrate docs + Prisma Client docs

Question: Will this schema and query set survive migration and load safely?

Favor:
- Model invariants with `@id`, `@unique`, `@@unique`, and relations.
- Specify `onDelete` and `onUpdate` intentionally.
- Keep migrations additive first; backfill before `NOT NULL`.
- Use narrow `select` and `include`.
- Batch related writes with nested writes or transactions.
- Paginate list reads with `cursor`, `take`, or both.
- Prefer Prisma Client or TypedSQL over raw SQL.

Forbid by default:
- `prisma db push` for shared environments.
- `queryRawUnsafe` or `executeRawUnsafe`.
- Editing an applied migration file.
- `deleteMany` or `updateMany` without `where`.
- Per-row Prisma calls in loops when one relation query would do.

CI:
- `prisma validate`
- `prisma format --check`
- `prisma generate`
- `prisma migrate status`

Agent protocol:
1. Model invariants in the schema.
2. Make migrations additive and reversible.
3. Tighten queries before optimizing.
4. Preserve behavior.
