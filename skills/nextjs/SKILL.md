---
name: cf:nextjs
group: rubrics
review: true
description: Next.js App Router rubric for server-first rendering and Server Actions. Auto-applied only when the project depends on next; also invocable directly.
auto:
  min_level: lean
  extensions: [ts, tsx, js, jsx]
  require:
    - dep: [next]
---

# Next.js

Question: does this route render on the server and mutate through a Server Action?

- Server Components by default; `'use client'` only on the smallest leaf that needs interactivity, never as a wrapper on a page or layout.
- Every write goes through a Server Action, even from a Client Component. A client `fetch` mutation or an `app/api` handler standing in for a form needs a stated reason.
- `params` and `searchParams` are `Promise<...>`: await them (Next.js 15+), never read them synchronously.
- Node runtime unless a measured requirement says edge.
- `metadata` and `generateMetadata` live in Server Components; `React.cache()` dedupes a fetch they share with the page.
- Suspense around slow segments, with `loading`, `error`, and `not-found` files.
- `'use cache'` needs `experimental.useCache` or `experimental.dynamicIO` first.
