---
name: pst:nextjs
description: Next.js App Router rubric for server-first rendering, Server Actions, and correct async APIs. Auto-applied by the pst shim on every Next.js change; also invocable directly.
auto:
  extensions: [ts, tsx, js, jsx]
  require:
    - dep: [next]
---

# Next.js Cheat Sheet

Source: Next.js docs (nextjs.org/docs) + Next.js repo (github.com/vercel/next.js)

Question: Does this route render on the server by default and mutate through a Server Action?

Favor:
- Server Components by default; `'use client'` only at the smallest leaf that needs interactivity
- Server Actions for every write and form submission, even from inside a Client Component
- Node.js runtime by default; edge only for a measured, specific requirement
- `params`/`searchParams` typed as `Promise<...>` and awaited (Next.js 15+)
- `metadata`/`generateMetadata` in Server Components only
- `React.cache()` to dedupe a fetch shared by `generateMetadata` and the page
- Suspense boundaries around slow segments, with explicit `loading`/`error`/`not-found` files
- `next/script` with `strategy="afterInteractive"` for third-party scripts that would otherwise break hydration

Avoid:
- `'use client'` as a default wrapper on a page or layout
- a client-side `fetch`/`axios` mutation where a Server Action would do
- an `app/api` route handler standing in for a form submission a Server Action already covers
- edge runtime picked with no measured reason
- synchronous access to `params`/`searchParams` without `await` or `use()`
- `'use cache'` without first enabling `experimental.useCache` or `experimental.dynamicIO`

Exception: client-side mutation is fine when a feature needs client-only interaction a Server
Action round-trip cannot give (drag state, optimistic UI mid-keystroke). Keep the `'use client'`
boundary small even then, and still call a Server Action for the write.

CI (mechanically enforced):
- `next build` passes
- lint max warnings = 0
- `tsc --noEmit` passes; catches unawaited `params`/`searchParams` once typed as `Promise<...>`

Review-time (no tool checks these):
- Server Actions preferred over client-side fetch/axios mutations
- `'use client'` boundaries kept minimal
- every exception carries a stated reason

Agent protocol:
1. Default new routes/pages/layouts to Server Components.
2. Route every write through a Server Action; note the reason for any exception.
3. Await `params`/`searchParams`; never access them synchronously.
4. Keep `'use client'` boundaries minimal and push state down.
5. Preserve visible behavior.
