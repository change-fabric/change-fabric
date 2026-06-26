---
name: pst:github-actions
description: GitHub Actions CI/CD workflows. Auto-applied by the pst shim on every workflow change; also invocable directly.
auto:
  paths:
    - ".github/workflows/*.yml"
    - ".github/workflows/*.yaml"
  detect: [".github/workflows/*.yml", ".github/workflows/*.yaml"]
---

# GitHub Actions Cheat Sheet

Source: GitHub Actions workflow syntax + Secure use reference + Security for GitHub Actions + actionlint

Question: Are workflows pinned, least-privilege, and reproducible from a clean checkout?

Favor:
- Pin third-party actions to full commit SHA.
- Set explicit `permissions` at workflow or job scope.
- Use `concurrency` on deploy and release workflows.
- Use `npm ci` and pinned runtime versions.
- Pass data between steps with outputs or env files.
- Prefer OIDC or GitHub App auth over long-lived cloud secrets.
- Reuse workflows for repeated pipelines.

Forbid by default:
- `uses: owner/action@main`, `@master`, or bare version tags.
- `pull_request_target` for untrusted code paths.
- `permissions: write-all`.
- Plaintext secrets in workflow `env`.
- Mutable container tags like `:latest`.
- Self-hosted runners for public forks by default.

CI:
- `actionlint`
- `yamllint .github/workflows`
- `out=$(git diff --name-only --diff-filter=AM origin/HEAD -- '.github/workflows/*' | xargs -I{} git grep -nP "uses:\\s+[^@]+@(main|master|v?[0-9]+(\\.[0-9]+){0,2})\\b|pull_request_target|permissions:\\s*write-all|:latest\\b" -- {}); [ -z "$out" ]`

Agent protocol:
1. Pin and scope every trust boundary.
2. Make permissions explicit and minimal.
3. Keep builds clean-room and reproducible.
4. Preserve behavior.
