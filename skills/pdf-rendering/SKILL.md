---
name: cf:pdf-rendering
description: Server-side PDF generation with Puppeteer and Handlebars. Auto-applied by the cf shim on every PDF-rendering change; also invocable directly.
auto:
  extensions: [js, mjs, hbs, handlebars, html]
  require:
    - dep: [puppeteer, puppeteer-core, playwright, handlebars]
  detect: ["**/*pdf*.js", "**/*.hbs", "**/*.handlebars", "**/*template*.html"]
---

# Server-side PDF Generation Cheat Sheet

Source: Puppeteer PDF and network interception docs + Handlebars guide

Question: Will identical input render identical PDFs without leaks or remote dependencies?

Favor:
- Compile Handlebars templates once and pass plain data objects.
- Keep `{{ }}` escaping on; validate data before render.
- Use local assets, fonts, and CSS only.
- Set explicit format, margins, and `printBackground`.
- Wait for content and fonts before `page.pdf()`.
- Close page, context, and browser in `finally`.
- Cap concurrency and set timeouts.
- Fix locale, timezone, and clock in tests.

Forbid by default:
- `{{{` or `SafeString` on untrusted data.
- Remote CDN assets in templates.
- Calling `page.pdf()` without options.
- Leaving browser instances open on error paths.
- Writing temp files outside a managed directory.
- Mixing template compilation with request globals.

CI:
- `npx --no-install eslint . --max-warnings 0`
- `base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") && l=$(mktemp) && trap 'rm -f "$l"' EXIT && git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- '*.hbs' '*.handlebars' '*.html' >"$l" && f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" && { [ ${#f[@]} -eq 0 ] || { GIT_LITERAL_PATHSPECS=1 git grep -nP "\\{\\{\\{|https?://" -- "${f[@]}"; [ $? -eq 1 ]; }; }` (see skills/README.md, CI diff-grep checks)
- `base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") && l=$(mktemp) && trap 'rm -f "$l"' EXIT && git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- '*.js' '*.mjs' >"$l" && f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" && { [ ${#f[@]} -eq 0 ] || { GIT_LITERAL_PATHSPECS=1 git grep -nP "\\bSafeString\\b|page\\.pdf\\(\\s*\\)" -- "${f[@]}"; [ $? -eq 1 ]; }; }` (see skills/README.md, CI diff-grep checks)
- `base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") && l=$(mktemp) && l2=$(mktemp) && l3=$(mktemp) && trap 'rm -f "$l" "$l2" "$l3"' EXIT && git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- '*.js' '*.mjs' >"$l" && f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" && { [ ${#f[@]} -eq 0 ] || { GIT_LITERAL_PATHSPECS=1 git grep -lzP "\\.(pdf|newPage)\\(" -- "${f[@]}" >"$l2"; s=$?; { [ $s -eq 0 ] || [ $s -eq 1 ]; } && g=() && while IFS= read -r -d "" p; do g+=("$p"); done <"$l2" && { [ ${#g[@]} -eq 0 ] || { GIT_LITERAL_PATHSPECS=1 git grep -LzP "finally" -- "${g[@]}" >"$l3"; s=$?; { [ $s -eq 0 ] || [ $s -eq 1 ]; } && h=() && while IFS= read -r -d "" p; do h+=("$p"); done <"$l3" && [ ${#h[@]} -eq 0 ]; }; }; }; }` (see skills/README.md, CI diff-grep checks)

Agent protocol:
1. Lock down templates and input data first.
2. Make rendering deterministic.
3. Close every browser resource on every path.
4. Preserve behavior.
