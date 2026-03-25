# PST Shared React/Next.js Rules

These rules are **OVERRIDE priority** - they take precedence over any external baseline rule on conflict. They are the shared code quality baseline used across all `/pst:*` skills that produce React/Next.js code.

| # | Rule |
|---|------|
| S1 | **Named exports only** - no default exports for hooks or components. |
| S2 | **Server components by default** in Next.js. Add `'use client'` only when the component genuinely needs client-side interactivity. Do not add it preemptively. |
| S3 | **Use `next/image` `<Image>` instead of HTML `<img>`** in Next.js projects. Provide required `width`/`height` or `fill` props. Skip if not Next.js. |
| S4 | **Strict TypeScript - no escape hatches**: No `any` types, no `@ts-ignore`, no `@ts-expect-error`, no `as` type assertions unless truly unavoidable (document why inline). Prefer type guards or generics. |
| S5 | **Zero `eslint-disable` comments** in all files. If the linter complains, fix the code or adjust the ESLint config. **NEVER introduce an `eslint-disable` without explicit user approval** - use AskUserQuestion to explain the lint error, context, and propose alternatives (fix the code, adjust the rule config, or suppress). Default recommendation: do NOT suppress. |
| S6 | **ESLint `--max-warnings 0`**: All lint runs MUST pass with zero warnings. Warnings are treated as errors. |
| S7 | **Prettier compliance**: All created and modified files MUST conform to the project's Prettier configuration. Run Prettier check as part of verification. Skip if Prettier is not configured in the project. |
| S8 | **Business logic in hooks** - state management, data fetching, and complex interactions belong in `use*.ts` hooks. Components are for UI composition only. Standard React hook patterns only - no workarounds or hacks that fight the framework. |
