---
name: pst:figma
description: Implement Figma designs into production-ready code - layered on Figma implement-design with opinionated project conventions
argument-hint: "<figma-url> [--dry-run]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

# Figma Design Implementation

Translate Figma designs into production-ready code with pixel-perfect accuracy. Uses Figma's implement-design as the structured baseline, Vercel react-best-practices as the supplementary code quality layer, and personal override rules for architecture and design system integration.

---

## Stage 1 - Input Parsing

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- Figma URL (e.g., `https://figma.com/design/:fileKey/:fileName?node-id=1-2`) - the design to implement
- `--dry-run` - fetch design context and report what would be implemented, no file creation

**Extract from URL:**

- **File key:** the segment after `/design/`
- **Node ID:** the `node-id` query parameter value (convert `-` to `:` for API calls)
- **Branch URLs:** `figma.com/design/:fileKey/branch/:branchKey/:fileName` → use `branchKey` as fileKey

If no Figma URL provided, ask the user via AskUserQuestion.

---

## Stage 2 - External Rules Loading

### Primary: Figma implement-design

Load the Figma implement-design skill as the structured baseline workflow. Installed by `install.sh` via `npx skills add https://github.com/figma/mcp-server-guide -g`.

**Resolution order** (first match wins):

1. `~/.claude/skills/figma-implement-design/SKILL.md` - global skills CLI install location
2. `./.claude/skills/figma-implement-design/SKILL.md` - project-local skills CLI install
3. `~/.claude/plugins/cache/**/figma-implement-design/SKILL.md` - Claude plugin cache (resolve via Glob)

**If found:** Read with the `Read` tool. Internalize the 7-step workflow as the baseline layer. Personal override rules (Stage 3) take precedence on any conflict.

**If not found:** Auto-install and retry:

```bash
npx -y skills@latest add https://github.com/figma/mcp-server-guide -g
```

After install, re-check the resolution paths above. If found now, read and internalize as normal.

**If install fails or skill still not found after install:** Log this warning and proceed with personal rules only:

```
WARNING: Figma implement-design skill not found.
         Run ./install.sh or: npx -y skills@latest add https://github.com/figma/mcp-server-guide -g
```

### Supplementary: Vercel react-best-practices

Load Vercel react-best-practices for React/Next.js code quality rules.

**Resolution order** (first match wins):

1. `~/.claude/skills/vercel-react-best-practices/SKILL.md` - global skills CLI install location
2. `./.claude/skills/vercel-react-best-practices/SKILL.md` - project-local skills CLI install
3. `~/.claude/commands/vercel-react-best-practices.md` - legacy commands directory

**If found:** Read `SKILL.md` and `AGENTS.md` with the `Read` tool. Internalize as supplementary quality layer.

**If not found:** Auto-install and retry:

```bash
npx -y skills@latest add vercel-labs/agent-skills -g
```

After install, re-check the resolution paths above. If found now, read and internalize as normal.

**If install fails or skill still not found after install:** Skip silently - this is supplementary, not required.

---

## Stage 3 - Personal Override Rules

### Shared rules (load first)

Locate and read the shared rules file via Glob for `**/skills/_shared/pst-react-rules.md`. These 8 rules are the shared React/Next.js code quality baseline used across all `/pst:*` skills.

**If not found:** Use these inline fallbacks - S1: Named exports only. S2: Server components by default. S3: `next/image` over `<img>`. S4: Strict TypeScript. S5: Zero `eslint-disable`. S6: ESLint `--max-warnings 0`. S7: Prettier compliance. S8: Business logic in hooks.

### Figma-specific rules

These 5 additional rules apply specifically to Figma design implementation:

| #   | Rule                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1  | **Project design tokens over Figma raw values.** Never hardcode hex colors, pixel font sizes, or magic-number spacing from Figma. Map every Figma value to the project's design system tokens (CSS variables, Tailwind theme, styled-components theme, etc.). If no matching token exists, flag it via AskUserQuestion: create a new token or use the closest existing one.                                                                                                                                                             |
| F2  | **Reuse existing components before creating new ones.** Before implementing a Figma element, search the project for an existing component that matches (buttons, inputs, cards, modals, etc.). Extend or compose existing components rather than duplicating. Document the decision.                                                                                                                                                                                                                                                    |
| F3  | **No inline styles except truly dynamic values** (e.g., computed positions, user-controlled colors). All static styling must go through the project's styling system (CSS modules, Tailwind classes, styled-components, etc.).                                                                                                                                                                                                                                                                                                          |
| F4  | **Responsive implementation required.** Do not implement only the single viewport shown in Figma. Infer responsive behavior from Figma auto-layout constraints. If breakpoint behavior is ambiguous, ask the user via AskUserQuestion.                                                                                                                                                                                                                                                                                                  |
| F5  | **Progressive Figma fetching for large artboards.** Never call `get_design_context` or `get_screenshot` on a node that may contain multiple pages or states (e.g., an entire page-level frame). Start with `get_metadata` to inspect the node tree and child count. If the node has more than ~5 direct children or appears to be a page-level container, fetch each child node individually via separate `get_design_context` calls rather than pulling the entire artboard at once. This avoids MCP timeouts and oversized responses. |

All 13 rules (8 shared + 5 specific) are **OVERRIDE priority** - they take precedence over any Figma or Vercel baseline rule on conflict.

---

## Stage 4 - Design Context Fetching

This stage wraps the Figma baseline Steps 1–4 with personal guardrails. Always use the progressive fetching strategy (Rule F5) to avoid MCP timeouts on large artboards.

1. **Probe node structure first** via `get_metadata(fileKey=":fileKey", nodeId=":nodeId")` - inspect the node type, child count, and tree depth before fetching design context
2. **If node is small** (≤5 direct children, not a page-level container): proceed normally with `get_design_context` and `get_screenshot`
3. **If node is large** (>5 direct children or is a page-level container): fetch each child node individually via separate `get_design_context` calls and capture screenshots per child - do not attempt to pull the entire artboard at once
4. **Capture screenshot(s)** via `get_screenshot` - keep as visual reference throughout implementation (per-child if using progressive fetching)
5. **Download assets** from Figma MCP server - use `localhost` sources directly, do not import icon packages or create placeholders
6. **Scan project** for existing design system: search for theme files, token definitions, component libraries

**If `--dry-run`:** Print the design context summary (components identified, tokens to map, assets to download, existing components that could be reused) and stop here.

---

## Stage 5 - Project Convention Discovery

Before writing any code, survey the target project:

1. **Framework:** Check for `next.config.*` (Next.js), `vite.config.*` (Vite), `remix.config.*` (Remix)
2. **Styling system:** Check for `tailwind.config.*` (Tailwind), `*.module.css` (CSS Modules), styled-components, etc.
3. **Component library:** Check for shadcn/ui (`components/ui/`), MUI, Chakra, Radix, etc.
4. **Design tokens:** Search for CSS custom properties, Tailwind theme extensions, theme files
5. **Package manager:** `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, else npm
6. **Existing components:** Grep for component names matching the Figma node names

**Print discovery report:**

```
PROJECT DISCOVERY
─────────────────
Framework:        Next.js 14 (App Router)
Styling:          Tailwind CSS
Component lib:    shadcn/ui
Design tokens:    Tailwind theme + CSS variables in globals.css
Package manager:  pnpm
Existing matches: Button, Card, Input (reusable)
```

---

## Stage 5b - Target Location Confirmation

Before writing any code, infer where in the application this design should be implemented and confirm with the user via AskUserQuestion.

**Steps:**

1. **Infer the target location** from the design context (Stage 4) and project structure (Stage 5). Use the Figma node name, page name, and visual content to identify the most likely route, page, or component location in the project. For example:
   - A design named "Search Results" with a search bar and result cards → `src/app/search/page.tsx`
   - A design showing a modal with form fields → a new component in the project's component directory
   - A design matching an existing page's layout → modification of that existing page

2. **Search the project** for existing files that match the inferred target - check for route directories, page files, and components that already implement similar UI.

3. **Present the inference and ask for confirmation** via AskUserQuestion. Include:
   - What the design appears to represent (e.g., "This looks like a search results page")
   - The inferred target file path(s) (e.g., "I'd implement this at `src/app/search/page.tsx`")
   - Whether this would create new files or modify existing ones
   - Any ambiguity (e.g., "This could be a standalone page or a section within the dashboard - which is it?")

4. **If the design spans multiple locations** (e.g., a prototype showing a flow across several pages or screens), list each screen and its inferred target separately. Ask the user to confirm all locations and whether they want the full flow implemented or just a subset.

**Example - single location:**

```
Based on the Figma design, this appears to be a **search results page** with filters and pagination.

I'd implement this at:
  → src/app/search/page.tsx (new page)
  → src/components/search/SearchResults.tsx (new component)
  → src/components/search/SearchFilters.tsx (new component)

The project already has src/app/search/ with a basic page - I'd extend it.

Is this the right location, or should this go somewhere else?
```

**Example - multi-location prototype:**

```
This Figma prototype covers a 3-screen flow:

  1. Search page       → src/app/search/page.tsx (existing - extend)
  2. Result detail      → src/app/results/[id]/page.tsx (new)
  3. Booking confirm    → src/app/booking/confirm/page.tsx (new)

Shared components across screens:
  → src/components/search/SearchHeader.tsx (reuse in all 3)
  → src/components/booking/BookingSummary.tsx (screens 2–3)

Should I implement the full flow, or focus on specific screens?
```

**Example - entire app / top-level Figma:**

If the design covers an entire application (many pages, flows, or the top-level Figma file), do **not** attempt to implement everything at once. Instead, ask the user to scope down:

```
This Figma file appears to contain the full application with ~12 screens across
multiple flows (onboarding, dashboard, search, settings, etc.).

Implementing everything at once would be too broad. Which section should I focus on?

  1. Onboarding flow (3 screens)
  2. Dashboard (2 screens)
  3. Search & results (3 screens)
  4. Settings (2 screens)
  5. Other - tell me which screens

Best practice: focus on one flow or section at a time for higher fidelity.
```

Do not proceed to Stage 6 until the user confirms the target location(s) and scope.

---

## Stage 6 - Implementation

Use Agent sub-tasks for complex multi-component designs. For each component/element from the Figma design:

### 6a. Map to Existing Components

Search the project for existing components that match the Figma element. If found, use or extend them rather than creating new ones (Rule F2).

### 6b. Create New Components

When no existing component matches, create new ones following all override rules:

- Named exports (S1)
- Server component by default; `'use client'` only if needed (S2)
- `next/image` for images (S3)
- Strict TypeScript interfaces for all props (S4)
- Design tokens mapped from Figma values, never hardcoded (F1)
- Styling through project's system, no inline styles (F3)
- Responsive layout from auto-layout constraints (F4)

### 6c. Handle Assets

- Download from Figma MCP `localhost` URLs directly
- Place in project's asset directory convention (e.g., `public/`, `src/assets/`)
- Use `next/image` with proper `width`/`height` or `fill` props

### 6d. Wire Interactivity

- Implement hover, active, disabled, and focus states from the design
- Extract complex interaction logic into `use*.ts` hooks (S8)
- Ensure keyboard navigation and focus management

### 6e. Accessibility

- Proper ARIA attributes on all interactive elements
- Keyboard navigation support
- Focus management for modals, dropdowns, etc.
- Alt text for all images
- Color contrast meeting WCAG AA
- Do not sacrifice accessibility for visual parity

---

## Stage 7 - Anti-Pattern Scan

After implementation, scan all created and modified files using dedicated tools (not shell equivalents):

- **Grep** for hardcoded hex colors (`#[0-9a-fA-F]{3,8}` outside token definitions) - should use design tokens (F1)
- **Grep** for `eslint-disable` - zero tolerance (S5)
- **Grep** for `export default` in new files - should be named exports (S1)
- **Grep** for `: any` or `as any` - strict TypeScript violation (S4)
- **Grep** for `@ts-ignore` and `@ts-expect-error` - violation (S4)
- **Grep** for `<img` in `.tsx` files (Next.js only) - should be `<Image>` from `next/image` (S3)
- **Grep** for inline `style=` attributes - should use styling system (F3)

Fix all violations found. For `eslint-disable` findings, follow the AskUserQuestion workflow in shared rule S5 before taking action.

---

## Stage 8 - Visual Validation

Compare the implemented UI against the Figma screenshot from Stage 4.

**Validation checklist:**

- [ ] Layout matches (spacing, alignment, sizing)
- [ ] Typography matches (font, size, weight, line height)
- [ ] Colors match exactly - and all use project tokens, not raw hex
- [ ] Spacing uses project scale, no magic numbers
- [ ] Interactive states work as designed (hover, active, disabled, focus)
- [ ] Responsive behavior follows Figma auto-layout constraints
- [ ] Assets render correctly
- [ ] Keyboard navigation works for all interactive elements
- [ ] Accessibility standards met (ARIA, contrast, alt text)

---

## Stage 9 - Quality Gates

Detect the package manager:

```bash
if [ -f pnpm-lock.yaml ]; then PKG="pnpm"; elif [ -f yarn.lock ]; then PKG="yarn"; else PKG="npm"; fi
```

Run full quality gates:

| Check           | Command                                                                                                  |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| Build           | `$PKG run build`                                                                                         |
| Lint            | `$PKG run lint -- --max-warnings 0`                                                                      |
| Typecheck       | `$PKG run typecheck`                                                                                     |
| Prettier        | `$PKG exec prettier --check .` (or `$PKG run format:check` if available)                                 |
| Type assertions | Grep all modified/created files for `: any`, `as any`, `@ts-ignore`, `@ts-expect-error` - zero tolerance |

**Lint note:** If the project's `lint` script already includes `--max-warnings 0`, bare `$PKG run lint` is sufficient. Check `package.json` scripts first.

**Prettier note:** If Prettier is not configured (no `.prettierrc`, `prettier.config.*`, or `prettier` key in `package.json`), skip and note in the summary.

If any gate fails: read the error, fix the issue, re-run all gates (max 3 fix cycles). If a script doesn't exist, skip it and note.

---

## Stage 10 - Summary Report

```
FIGMA IMPLEMENTATION COMPLETE
──────────────────────────────
Components created:    {N}
Components reused:     {M}
Assets downloaded:     {A}
Design tokens mapped:  {T}
Quality gates:         {ALL PASSED | FAILED - see above}
Prettier:              {COMPLIANT | NOT CHECKED - no config}
ESLint warnings:       {0 | N remaining}
Type safety:           {CLEAN | N violations}
next/image:            {COMPLIANT | N/A - not Next.js}
Accessibility:         {CHECKED | ISSUES - see above}
Responsive:            {IMPLEMENTED | SINGLE VIEWPORT - see above}

External rules: Figma implement-design {loaded | not installed}
Supplementary:  Vercel react-best-practices {loaded | not installed}
Shared rules:   8 loaded from pst-react-rules.md
Figma rules:    5 applied

Files created:
  src/components/...

Files modified:
  ...

Design token mappings:
  Figma #1A73E8 → var(--color-primary-600)
  Figma 16px → text-base
  ...
```

---

## Error Handling

| Condition                                                           | Action                                                                                     |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| No Figma URL provided                                               | Ask user via AskUserQuestion                                                               |
| Figma MCP server not connected                                      | Exit: "Figma MCP server not accessible. Ensure it's configured."                           |
| Design context too large, truncated, or MCP call exceeds ~2 minutes | Use `get_metadata` to probe node tree first, then fetch child nodes individually (Rule F5) |
| No design system tokens found in project                            | Warn user, offer to create token file via AskUserQuestion                                  |
| No matching token for a Figma value                                 | AskUserQuestion: create new token or use closest existing                                  |
| Asset download fails                                                | Log warning, use placeholder with TODO comment                                             |
| Quality gate failures after 3 cycles                                | Report and stop                                                                            |
| Figma implement-design skill not found                              | Degrade gracefully, log install command                                                    |
| Target location ambiguous or no matching route found                | Ask user via AskUserQuestion before proceeding                                             |
| Ambiguous responsive behavior                                       | Ask user via AskUserQuestion                                                               |
| Component already exists in project                                 | Reuse/extend it, do not duplicate                                                          |
