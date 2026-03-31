---
name: pst:patch
description: Detect and remediate cybersecurity vulnerabilities -- OWASP Top 10 static analysis, dependency CVE audits, and optional OWASP ZAP pen testing
argument-hint: "<scan|pentest|setup-ci> [path|url] [--output path]"
allowed-tools: Bash, Read, Edit, Grep, Glob, Agent, AskUserQuestion
---

# Security Vulnerability Detection & Remediation

Detect and remediate security vulnerabilities across a codebase -- OWASP Top 10 static analysis, multi-source dependency CVE audits with tiered auto-fix, and optional OWASP ZAP pen testing.

## Arguments

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `subcommand` (required): `scan`, `pentest`, or `setup-ci`
- `path` (optional, scan only): directory or file to scan (defaults to smart scope)
- `url` (required for pentest): target URL for active scanning
- `--output path` (optional): write JSON report to the specified path

Examples:

- `/pst:patch scan` -- scan changed files + full dep audit
- `/pst:patch scan packages/api/src` -- scan specific path
- `/pst:patch scan --output report.json` -- scan and save report
- `/pst:patch pentest http://localhost:3000` -- run ZAP against local app
- `/pst:patch pentest http://localhost:3000 --output zap-report.json`
- `/pst:patch setup-ci` -- scaffold security CI workflow

---

## Subcommand: `scan`

Passive, always safe. No network requests except dependency advisory lookups.

### Phase 0: Read Project Context

Read `CLAUDE.md` and `package.json` from the project root to understand:

- Internal package scope (e.g., `@myorg/`) from workspace config
- Package manager (pnpm, npm, yarn) from lockfile presence
- Project type (app vs library) from dependencies and config files

### Phase 1: Scope Discovery

Determine what to scan:

1. **Code scope** -- smart scope based on context:
   - If in a commit/PR workflow: diff-scoped (`git diff --name-only origin/main...HEAD`)
   - Otherwise: scan the provided `path` argument, or default to `src/`
   - File types: `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.go`, `.java`, `.rb`

2. **Dependency scope** -- always full:
   - **Detect workspace:** Check for `pnpm-workspace.yaml`, or `workspaces` field in root `package.json`. If present, use monorepo path. Otherwise, single-package path.
   - **Monorepo/workspace:** Use `pnpm ls --prod --json -r --depth 0` to collect production dependencies from all workspace packages (root `package.json` alone misses workspace package deps). Filter out internal workspace packages.
   - **Single-package:** Read `package.json`, `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`
   - Also check: `requirements.txt`, `Pipfile.lock`, `go.sum`, `Gemfile.lock`

3. **Config scope** -- always full:
   - Scan for: `.env*`, `docker-compose*.yml`, `Dockerfile*`, `nginx.conf`, CI workflow files

### Phase 2: Dependency Audit

Run parallel multi-source CVE lookups. Use Bash for all commands.

**Source 1: GitHub Advisory Database**

```bash
gh api graphql -f query='
  query {
    securityVulnerabilities(first: 100, ecosystem: NPM, package: "<pkg>") {
      nodes {
        advisory { ghsaId summary severity cvss { score } }
        vulnerableVersionRange
        firstPatchedVersion { identifier }
      }
    }
  }
'
```

Only query dependencies that do not appear in the OSV.dev or package manager audit results (use those sources first, then backfill with GitHub Advisory for any packages with no findings).

**Source 2: OSV.dev**

Collect all production dependencies, then batch-query OSV. In monorepos, use `pnpm ls` to capture deps from all workspace packages -- not just root `package.json`:

```bash
# Monorepo: collect prod deps from all workspace packages
node -e "
  const { execSync } = require('child_process');
  const fs = require('fs');
  const data = JSON.parse(execSync('pnpm ls --prod --json -r --depth 0', { encoding: 'utf8' }));
  const seen = new Map();
  const pkgJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  // Detect internal scope from workspaces config
  const internalScope = (pkgJson.name || '').split('/')[0] + '/';
  for (const pkg of data) {
    for (const [name, info] of Object.entries(pkg.dependencies || {})) {
      if (!internalScope || !name.startsWith(internalScope)) {
        seen.set(name, info.version);
      }
    }
  }
  const queries = [...seen.entries()].map(([name, version]) => ({
    package: { name, ecosystem: 'npm' },
    version
  }));
  const batch = queries.slice(0, 1000);
  fs.writeFileSync('osv-query.json', JSON.stringify({ queries: batch }));
  console.log('OSV query: ' + batch.length + ' production dependencies');
"

curl -s -X POST https://api.osv.dev/v1/querybatch \
  -H "Content-Type: application/json" \
  -d @osv-query.json
```

For single-package repos, read `package.json` directly instead of `pnpm ls`.

**Source 3: Package manager audit**

Detect the package manager and run its audit. **Always use `--prod` to audit production dependencies only** -- dev tool vulnerabilities (eslint, vitest, webpack transitive deps) are not exploitable in production and create false-positive noise.

```bash
# Detect package manager from lockfile -- audit prod deps only
if [ -f pnpm-lock.yaml ]; then
  pnpm audit --prod --json > audit-results.json 2>&1 || true
elif [ -f package-lock.json ]; then
  npm audit --omit=dev --json > audit-results.json 2>&1 || true
elif [ -f yarn.lock ]; then
  yarn audit --json > audit-results.json 2>&1 || true
fi
```

Parse `audit-results.json` for findings regardless of exit code.

**Deduplication:** Merge findings by CVE ID. When the same CVE appears in multiple sources, keep the entry with the highest CVSS score and most complete metadata.

### Phase 2.1: Transitive CVE Remediation via pnpm.overrides

When a vulnerable package is a transitive dependency and a patched version exists but upstream hasn't released a fix, use `pnpm.overrides` to force the patched version.

**When to apply (safe tier -- auto-apply):**

1. The vulnerable package is transitive (not a direct dependency)
2. A patched version exists (`Patched versions` in advisory)
3. The override is semver-compatible with what upstream expects

**Implementation:**

```json
{
  "pnpm": {
    "overrides": {
      "vulnerable-pkg": ">=PATCHED_VERSION"
    }
  }
}
```

After adding overrides: run `pnpm install`, then `pnpm test`. If tests fail, revert the override and escalate to moderate tier.

### Phase 3: Static Analysis

Apply heuristic pattern detection mapped to OWASP Top 10 2021 categories. Read each in-scope file and check for:

#### A01 Broken Access Control

- Missing auth middleware -- route handlers without authentication checks
- IDOR -- direct object references using user-supplied IDs without ownership verification
- Path traversal -- user input in file paths (`path.join(base, userInput)` without sanitization)
- Directory listing -- static file serving without explicit index restriction
- CORS misconfiguration -- `Access-Control-Allow-Origin: *` combined with `credentials: true`

#### A02 Cryptographic Failures

- Weak hashing -- `md5`, `sha1` used for passwords or tokens (grep for `createHash('md5')`, `createHash('sha1')`)
- Hardcoded secrets -- string literals matching patterns: `password\s*=\s*['"]`, `api[_-]?key\s*=\s*['"]`, `secret\s*=\s*['"]`
- Insecure TLS -- `rejectUnauthorized: false`, `NODE_TLS_REJECT_UNAUTHORIZED=0`
- Sensitive data in URLs -- tokens/keys in query parameters
- Missing encryption -- PII stored or transmitted without encryption

#### A03 Injection

- SQL injection -- template literals or concatenation in SQL queries (`\`SELECT.*\$\{`, `.query(.*\+`)
- Command injection -- template literals in `exec`, `spawn`, `execSync` (`exec(\`.*\$\{`)
- XSS -- `dangerouslySetInnerHTML` without sanitization, `innerHTML` assignment with user data
- Template injection -- user input in template engine render calls
- NoSQL injection -- user input directly in MongoDB query objects

#### A04 Insecure Design

- Missing rate limiting -- authentication endpoints without rate limiter middleware
- No CSRF protection -- state-changing endpoints without CSRF tokens
- No input length limits -- request body parsing without size limits
- Missing account lockout -- login endpoints without brute-force protection
- Insecure password reset -- token-based reset without expiration

#### A05 Security Misconfiguration

- Permissive CORS -- `Access-Control-Allow-Origin: *` in production configs
- Debug mode -- `debug: true`, `NODE_ENV !== 'production'` in deployed configs
- Verbose errors -- stack traces or internal details in error responses to clients
- Default credentials -- hardcoded default usernames/passwords
- Missing security headers -- no `helmet()` or manual security header configuration

#### A06 Vulnerable Components

Populated from Phase 2 dependency audit findings. Each CVE maps here.

#### A07 Authentication Failures

- Weak password policy -- no minimum length/complexity validation on password fields
- Session fixation -- session ID not regenerated after authentication
- Missing MFA hooks -- authentication flow without multi-factor authentication support
- Credential exposure -- passwords logged or included in API responses
- Insecure session storage -- session data in localStorage instead of httpOnly cookies

#### A08 Software & Data Integrity Failures

- Unsigned dependencies -- no lockfile integrity verification
- CI injection vectors -- `${{ github.event }}` interpolation in GitHub Actions `run:` steps
- Missing SRI -- `<script>` and `<link>` tags loading external resources without `integrity` attribute
- Insecure deserialization -- `JSON.parse` on untrusted input without schema validation
- Auto-update without verification -- dependency updates without checksum/signature verification

#### A09 Security Logging & Monitoring Failures

- Sensitive data in logs -- passwords, tokens, PII in log output
- Missing audit trail -- authentication events (login, logout, failed attempts) not logged
- No security event logging -- authorization failures not logged
- Log injection -- user input included in log messages without sanitization
- Missing alerting -- no monitoring for repeated authentication failures

#### A10 Server-Side Request Forgery (SSRF)

- User-controlled URLs -- user input passed to `fetch`, `http.get`, `axios` without URL allowlist
- DNS rebinding -- no validation that resolved IP is not internal/private
- Redirect following -- HTTP clients following redirects to internal resources
- Protocol smuggling -- URL parsing allowing `file://`, `gopher://`, etc.

### Phase 4: AI Augmentation

For ambiguous findings only -- use AI judgment to assess:

- Is this endpoint intentionally public? (A01)
- Is this hash used for non-security purposes (e.g., cache keys)? (A02)
- Is this `exec` call using a hardcoded command string? (A03)
- Does this CORS config apply to a public API? (A05)

Heuristic patterns are primary. AI is secondary for reducing false positives.

### Phase 5: Classify & Tier

Each finding gets:

| Field   | Description                                                                                               |
| ------- | --------------------------------------------------------------------------------------------------------- |
| `owasp` | OWASP Top 10 category (A01--A10)                                                                          |
| `cwe`   | CWE identifier                                                                                            |
| `cve`   | CVE identifier (dependency findings only)                                                                 |
| `cvss`  | CVSS score (0.0--10.0)                                                                                    |
| `risk`  | `critical` (CVSS >= 9.0), `high` (7.0--8.9), `medium` (4.0--6.9), `low` (0.1--3.9), `info` (0.0 or none) |
| `tier`  | Remediation tier: `safe`, `moderate`, or `risky`                                                          |

**CVSS fallback:** When a finding has no numeric CVSS score (e.g., GitHub advisories with severity label only), map the severity label: `critical` -> 9.5, `high` -> 7.5, `medium` -> 5.0, `low` -> 2.0. Use these synthetic scores for risk classification and sorting only -- do not include them in the CVSS field of the output (use `null` instead).

**Remediation tiers:**

- **Safe** -- auto-apply without prompting: dependency version bumps (with test verification), security header additions, cookie flag fixes, SRI attribute additions
- **Moderate** -- prompt via AskUserQuestion before applying: CORS policy changes, auth middleware additions, session configuration changes, rate limiter additions
- **Risky** -- report only, never auto-apply: encryption algorithm changes, key rotation, authentication architecture changes, database schema changes

### Phase 6: Remediation

Apply fixes based on tier:

**Safe tier (auto-apply):**

1. For dependency bumps:
   - Update the version in package.json
   - Run `pnpm install` (or detected package manager)
   - Run `pnpm test`
   - If tests fail: revert the change, escalate to moderate tier
   - If tests pass: stage and continue
2. For security headers: add `helmet()` or individual headers
3. For cookie flags: add `httpOnly`, `secure`, `sameSite` attributes

**Moderate tier (prompt):**

Use **AskUserQuestion** for each finding:

```
Question: "Apply fix for [issue description]?"
Options:
1. Apply fix (Recommended)
2. Skip -- I'll handle this manually
3. Show details
```

If "Show details": display the full finding with current code and proposed fix, then re-prompt.

**Risky tier (report only):**

Include in the report with full remediation guidance but do not offer to apply.

### Phase 7: Report

Generate the output report (see Output Contract below).

---

## Subcommand: `pentest`

Active scanning -- explicit opt-in required. Sends HTTP requests to the target URL.

### Phase 1: Prerequisites

1. **Validate URL and confirm target:**

   Parse the URL. Use **AskUserQuestion** to confirm before proceeding:

   ```
   Question: "Run active security scan against <url>? This will send HTTP requests to probe for vulnerabilities."
   Options:
   1. Yes -- I own/control this target
   2. Abort
   ```

   Then verify reachability:

   ```bash
   curl -s -o /dev/null -w "%{http_code}" <url>
   ```

   If not reachable, abort with error.

2. **Check Docker:**

   ```bash
   docker info > /dev/null 2>&1
   ```

   If Docker is not available, abort:

   ```
   Docker is required for pentest mode. Install Docker Desktop and try again.
   ```

3. **Pull ZAP image** (if needed):

   Default image: `ghcr.io/zaproxy/zaproxy:stable`. Override by setting `ZAP_IMAGE` environment variable.

   ```bash
   docker pull ${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable}
   ```

### Phase 2: API Spec Detection

Auto-detect OpenAPI/GraphQL specs at common locations:

```bash
# OpenAPI
curl -s -o /dev/null -w "%{http_code}" <url>/openapi.json
curl -s -o /dev/null -w "%{http_code}" <url>/swagger.json
curl -s -o /dev/null -w "%{http_code}" <url>/api-docs
curl -s -o /dev/null -w "%{http_code}" <url>/v1/openapi.json

# GraphQL
curl -s -o /dev/null -w "%{http_code}" <url>/graphql
```

If a spec is found, note the URL for Phase 3 API scan mode.

### Phase 3: Run ZAP

**Network mode:** `--network host` does not work on Docker Desktop for macOS (the VM isolates the network). Detect the platform and adjust:

```bash
# Detect platform for Docker networking
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS: replace localhost/127.0.0.1 with host.docker.internal
  ZAP_URL="${url//localhost/host.docker.internal}"
  ZAP_URL="${ZAP_URL//127.0.0.1/host.docker.internal}"
  DOCKER_NET_FLAG=""
else
  ZAP_URL="$url"
  DOCKER_NET_FLAG="--network host"
fi
```

**If API spec found:**

```bash
docker run --rm -v "$(pwd)/zap-output:/zap/wrk" \
  $DOCKER_NET_FLAG \
  ${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable} zap-api-scan.py \
  -t <spec-url-with-ZAP_URL> \
  -f openapi \
  -J zap-report.json \
  -I
```

**If no API spec (baseline scan):**

```bash
docker run --rm -v "$(pwd)/zap-output:/zap/wrk" \
  $DOCKER_NET_FLAG \
  ${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable} zap-baseline.py \
  -t $ZAP_URL \
  -J zap-report.json \
  -I
```

**Full scan** (use when the user explicitly requests a deep scan):

```bash
docker run --rm -v "$(pwd)/zap-output:/zap/wrk" \
  $DOCKER_NET_FLAG \
  ${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable} zap-full-scan.py \
  -t $ZAP_URL \
  -J zap-report.json \
  -I
```

The `-I` flag prevents ZAP from returning error codes on findings (we parse them ourselves).

### Phase 4: Parse

Read `zap-output/zap-report.json` and extract alerts. Map each ZAP alert to:

| ZAP Risk Level    | Risk   |
| ----------------- | ------ |
| 3 (High)          | high   |
| 2 (Medium)        | medium |
| 1 (Low)           | low    |
| 0 (Informational) | info   |

Map ZAP alerts to OWASP categories using CWE mappings in the ZAP output.

### Phase 5: Merge

If a `scan` was also run (or run one automatically before pentest):

1. Combine static analysis findings with pentest findings
2. Deduplicate by CWE + file/URL
3. Prefer the finding with higher CVSS / more detail

---

## Subcommand: `setup-ci`

Scaffold a security CI workflow for the target repository.

### Phase 1: Detect Project Type

Determine if this is a web app or library:

- **Web app indicators:** `next.config.*` exists, `express`/`fastify`/`koa` in dependencies, a `start` script in package.json
- **Library/CLI indicators:** `main`/`bin` in package.json, no server framework dependencies

### Phase 2: Generate Workflow

**For Library/CLI projects:**

```yaml
name: Security

on:
  pull_request:
    branches: [main]

jobs:
  secret-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      # gitleaks-action@v2 requires a paid license for GitHub orgs.
      # Install the CLI directly from releases instead.
      - name: Install gitleaks
        run: |
          curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_linux_x64.tar.gz | tar -xz
          sudo mv gitleaks /usr/local/bin/
      - name: Run gitleaks
        run: gitleaks detect --source . --verbose --redact

  dependency-audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: "pnpm"
      - run: pnpm install --frozen-lockfile
      - name: Audit production dependencies
        run: pnpm audit --prod --audit-level=high
        continue-on-error: true
      - name: Query OSV.dev for known CVEs (production only)
        run: |
          node -e "
            const { execSync } = require('child_process');
            const fs = require('fs');
            const pkgJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
            const internalScope = (pkgJson.name || '').includes('/') ? pkgJson.name.split('/')[0] + '/' : null;
            let data;
            try {
              data = JSON.parse(execSync('pnpm ls --prod --json -r --depth 0', { encoding: 'utf8' }));
            } catch {
              data = [{ dependencies: Object.fromEntries(
                Object.entries(pkgJson.dependencies || {}).map(([n, v]) => [n, { version: v.replace(/^[~^]/, '') }])
              )}];
            }
            const seen = new Map();
            for (const pkg of data) {
              for (const [name, info] of Object.entries(pkg.dependencies || {})) {
                if (!internalScope || !name.startsWith(internalScope)) {
                  seen.set(name, info.version);
                }
              }
            }
            const queries = [...seen.entries()].map(([name, version]) => ({
              package: { name, ecosystem: 'npm' },
              version
            }));
            const batch = queries.slice(0, 1000);
            fs.writeFileSync('osv-query.json', JSON.stringify({ queries: batch }));
            console.log('OSV query: ' + batch.length + ' production dependencies');
          "
          curl -s -X POST https://api.osv.dev/v1/querybatch \
            -H "Content-Type: application/json" \
            -d @osv-query.json > osv-results.json
          node -e "
            const r = JSON.parse(require('fs').readFileSync('osv-results.json','utf8'));
            const q = JSON.parse(require('fs').readFileSync('osv-query.json','utf8'));
            let fail = false;
            r.results.forEach((res, i) => {
              if (res.vulns && res.vulns.length > 0) {
                const pkg = q.queries[i].package.name + '@' + q.queries[i].version;
                res.vulns.forEach(v => {
                  const sev = (v.database_specific?.severity || 'UNKNOWN').toUpperCase();
                  const prefix = ['CRITICAL','HIGH'].includes(sev) ? '::error' : '::warning';
                  console.log(prefix + '::' + pkg + ': ' + v.id + ' (' + sev + ')');
                  if (['CRITICAL','HIGH'].includes(sev)) fail = true;
                });
              }
            });
            if (fail) { console.log('::error::High/critical CVEs found'); process.exit(1); }
          "
      - name: Save audit report
        if: always()
        run: pnpm audit --prod --json > audit-results.json 2>&1 || true
      - name: Upload audit report
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: dependency-audit
          path: |
            audit-results.json
            osv-results.json
          retention-days: 30
```

**For Web app projects:**

Add a `zap-scan` job after `dependency-audit`. Use **AskUserQuestion** to get:

- App start command (e.g., `pnpm start`, `pnpm dev`)
- Health check URL (e.g., `http://localhost:3000/api/health`)

```yaml
  zap-scan:
    runs-on: ubuntu-latest
    needs: dependency-audit
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: "pnpm"
      - run: pnpm install --frozen-lockfile
      - name: Build application
        run: pnpm build
      - name: Start application
        run: |
          <app-start-command> &
          APP_READY=false
          for i in $(seq 1 30); do
            if curl -s -o /dev/null -w "%{http_code}" <health-url> | grep -qE "200|302"; then
              echo "App is ready"
              APP_READY=true
              break
            fi
            echo "Waiting for app... ($i/30)"
            sleep 2
          done
          if [ "$APP_READY" != "true" ]; then
            echo "::error::App failed to start within 60 seconds"
            exit 1
          fi
      - name: Run ZAP Baseline Scan
        uses: zaproxy/action-baseline@v0.14.0
        with:
          target: <health-url>
          allow_issue_writing: false
      - name: Upload ZAP report
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: zap-scan
          path: report_html.html
          retention-days: 30
```

### Phase 3: Write Workflow

Use **AskUserQuestion** to confirm:

```
Question: "Write security CI workflow to .github/workflows/security.yml?"
Options:
1. Yes -- create the workflow (Recommended)
2. Preview first -- show me the YAML
3. Skip
```

If "Preview": display the YAML, then re-prompt with Yes/Skip.

Write the file using the Write tool.

---

## Output Contract

Every `scan` or `pentest` invocation **must** produce a delimited result block:

```
--- PST SECURITY REPORT ---
scan-type: [scan|pentest]
risk-score: [0-100]
critical: N | high: N | medium: N | low: N | info: N

[A01 Broken Access Control]:
  - file: path/to/file.ts:LL
    cwe: CWE-XXX
    cvss: X.X
    risk: critical|high|medium|low|info
    tier: safe|moderate|risky
    issue: one-line description
    fix: proposed remediation

[A06 Vulnerable Components]:
  - package: lodash@4.17.20
    cve: CVE-2021-23337
    cvss: 7.2
    fixed-in: 4.17.21
    tier: safe

[Pentest Results]: (pentest mode only)
  - url: https://target/path
    alert: Missing Anti-CSRF Token
    risk: medium
    cwe: CWE-352

report-path: /path/to/report.json (if --output)
--- END PST SECURITY REPORT ---
```

**Risk score** (0--100) is calculated as:

- Start at 0
- +25 per critical finding
- +10 per high finding
- +5 per medium finding
- +1 per low finding
- Cap at 100

**If `--output` is specified:** Write the full report as JSON to the specified path:

```json
{
  "scanType": "scan|pentest",
  "riskScore": 42,
  "summary": { "critical": 0, "high": 2, "medium": 5, "low": 3, "info": 1 },
  "findings": [
    {
      "owasp": "A03",
      "cwe": "CWE-89",
      "cve": null,
      "cvss": 8.6,
      "risk": "high",
      "tier": "moderate",
      "file": "src/api/users.ts:42",
      "issue": "SQL injection via template literal in user query",
      "fix": "Use parameterized query with $1 placeholder",
      "ref": null
    }
  ],
  "timestamp": "2024-01-15T10:30:00Z"
}
```

## Important Guidelines

- **Scan is passive:** The `scan` subcommand never makes network requests to the target application. Dependency advisory lookups are the only network activity.
- **Pentest requires opt-in:** The `pentest` subcommand actively probes the target. Only run against URLs the user explicitly provides.
- **Tiered remediation:** Never auto-apply risky fixes. Always prompt for moderate fixes. Only auto-apply safe fixes.
- **Test after dep bumps:** Every dependency version bump must pass tests before being accepted. Revert and escalate on failure.
- **Deduplicate across sources:** Merge findings by CVE/CWE to avoid duplicate reporting.
- **Cap findings:** Report up to 50 findings, prioritized by risk level (critical first).
- **Preserve context:** Include file paths with line numbers, CVE/CWE references, and advisory links where available.
- **No paid GitHub features:** Never generate workflows that depend on GitHub Advanced Security (CodeQL, code scanning, secret scanning alerts). These require paid add-ons for private repos on org plans. Use free alternatives: gitleaks CLI binary for secret scanning, the `scan` subcommand for static analysis, and OSV.dev + `pnpm audit` for dependency CVEs.
- **gitleaks CLI over gitleaks-action:** Always install gitleaks from GitHub releases (`curl` + `tar`) rather than using `gitleaks/gitleaks-action@v2`, which requires a `GITLEAKS_LICENSE` secret for GitHub organizations.
- **Dependency audit must fail CI on high/critical:** Generated dependency audit jobs must `exit 1` when high or critical CVEs are found -- not just emit warnings. Use `::error::` annotations and a `FAIL` flag pattern so the job collects all results before exiting non-zero. This applies to both package manager audit and OSV.dev results.
- **Audit production dependencies only:** Always use `pnpm audit --prod` (or `npm audit --omit=dev`) in both CI and scan mode. Dev tool vulnerabilities (eslint, vitest, webpack transitive deps) are not exploitable in production and create noise that dilutes signal for real risks. When dev-only CVEs need attention, note them in the report's info section but do not fail CI for them.
- **Monorepo dep collection:** In workspaces/monorepos, root `package.json` typically has no production dependencies -- all real deps live in workspace packages. Always use `pnpm ls --prod --json -r --depth 0` to collect deps from the entire workspace, deduplicate by package name, and filter out internal workspace packages before querying OSV or generating CI workflows.
- **Use pnpm.overrides for transitive CVEs:** When a patched version of a vulnerable transitive dep exists but upstream hasn't released a fix, add `pnpm.overrides` in root `package.json` to force the patched version. This is a safe-tier remediation -- auto-apply with test verification.
- **Never IGNORE security-relevant ZAP rules:** When generating ZAP rules tuning files, never set action to `IGNORE` for rules that represent real attack vectors -- especially Open Redirect (10028), which is used in phishing and OAuth token theft. Use `WARN` to surface findings without blocking CI. Reserve `IGNORE` only for purely informational rules (cache status, timestamps) that create noise with no security signal.

## Error Handling

| Condition                    | Action                                                  |
| ---------------------------- | ------------------------------------------------------- |
| Not a git repo               | Stop: "Not a git repo."                                 |
| No package.json found        | Skip dependency audit, run static analysis only         |
| Docker not available         | Abort pentest with install instructions                 |
| ZAP image pull fails         | Abort pentest with network troubleshooting hint         |
| Target URL unreachable       | Abort pentest with connectivity error                   |
| GitHub API rate limit (429)  | Wait, retry once, then skip GitHub Advisory source      |
| OSV.dev unreachable          | Warn and continue with other sources                    |
| pnpm audit fails to parse    | Warn and continue with other sources                    |
| No findings                  | Report clean scan with risk-score: 0                    |
| Test failure after dep bump  | Revert change, escalate to moderate tier                |
