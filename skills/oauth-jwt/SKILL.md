---
name: cf:oauth-jwt
description: OAuth 2.0 and JWT auth flows. Auto-applied by the cf shim on every auth-related change; also invocable directly.
auto:
  extensions: [js, jsx, mjs]
  require:
    - dep: [jsonwebtoken, jose, passport, passport-jwt, "@node-oauth/express-oauth-server", openid-client]
  detect: ["**/*auth*.js", "**/*oauth*.js", "**/*jwt*.js", "**/*session*.js"]
---

# OAuth 2.0 and JWT Cheat Sheet

Source: RFC 9700 + RFC 7519 + RFC 8725 + OWASP Session Management Cheat Sheet

Question: Are tokens issued, stored, and validated so theft or replay fails closed?

Favor:
- Use Authorization Code + PKCE for user auth.
- Store browser tokens in `HttpOnly`, `Secure`, `SameSite` cookies or a BFF.
- Validate issuer, audience, expiry, not-before, and signature on every token.
- Pin accepted algorithms and key ids.
- Keep access tokens short-lived and rotate refresh tokens.
- Scope tokens minimally and separate user vs machine tokens.
- Keep client secrets and signing keys in secret stores only.

Forbid by default:
- Implicit flow or password grant.
- `jwt.decode()` as an auth check.
- Tokens in query strings.
- Tokens in `localStorage` or `sessionStorage`.
- Accepting `alg: none` or algorithm choices from token headers alone.
- Logging raw tokens or `Authorization` headers.

CI:
- `npx --no-install eslint . --max-warnings 0`
- `npm audit --omit=dev`
- `out=$(git diff --name-only --diff-filter=AM origin/HEAD -- '*.js' '*.jsx' '*.mjs' '*.ts' '*.tsx' | xargs -I{} git grep -niP "jwt\\.decode\\(|(local|session)Storage\\.\\w*(token|jwt)|(local|session)Storage\\.\\w+\\([^)]*(token|jwt|auth)|[?&](access_token|id_token)=|response_type=token|grant_type=password" -- {}); [ -z "$out" ]`

Agent protocol:
1. Choose the safest supported flow first.
2. Lock down storage, scope, and expiry.
3. Verify every token claim before trust.
4. Preserve behavior.
