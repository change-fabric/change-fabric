---
name: cf:security
group: rubrics
description: Application security rubric drawn from the OWASP Top 10 and OWASP ASVS. A cf:roast lens only (--lens cf:security), routed to plan roasts by keyword; never auto-applied.
lens:
  keywords: [login, log in, auth, sign-in, sign in, session, password, OAuth, JWT, OIDC, SAML, CSRF, secret]
---

# Security

Source: OWASP Top 10 (2021), https://owasp.org/Top10/; OWASP Application Security Verification Standard (ASVS) 4.0, https://owasp.org/www-project-application-security-verification-standard/. Category names are used as labels; the checks are our own words. Read the sources for the authoritative text.

A lens for cf:roast (`--lens cf:security`) on a plan, an architecture doc, or a diff. It has no `auto:` block on purpose, so it never joins the per-change review; cf:plan routes it to a plan roast when the plan talks about logins, sessions, tokens of identity, or secrets. It advises; it never blocks a push or a plan handoff.

## The question

Who can do what to which data, how does the system know, and what happens when an attacker lies to it?

## Checks by OWASP Top 10 category

Each line: what to look for, then the default fix.

1. Broken access control. Every read and write checks that the caller may touch that specific record, on the server, deny by default. Fix: one authorization check per handler, keyed to the resource owner or role, with a test for the cross-tenant case.
2. Cryptographic failures. Sensitive data is named, encrypted in transit and at rest, and passwords use a slow, salted hash (argon2id, scrypt, or bcrypt). Fix: TLS everywhere, a managed key store, no home-made crypto.
3. Injection. Every query, command, and template takes untrusted input through parameters or escaping, never string building. Fix: parameterized queries, an allow-list for anything that reaches a shell, context-aware output encoding.
4. Insecure design. The plan names its threats (who attacks, what they want) and the controls that answer each. Fix: a short threat model for each new trust boundary, with abuse cases next to the use cases.
5. Security misconfiguration. Defaults are locked down: no debug output, no default accounts, strict headers, least-privilege service accounts. Fix: a hardened baseline in code, checked in CI.
6. Vulnerable and outdated components. Dependencies are pinned, scanned, and updated on a schedule. Fix: a lockfile, an automated update bot, and a scan that fails on known critical issues.
7. Identification and authentication failures. Login resists credential stuffing and brute force, supports multi-factor authentication where the risk calls for it, and session identifiers rotate on login and expire. Fix: rate limiting, MFA, secure cookie flags (HttpOnly, Secure, SameSite), server-side session invalidation on logout.
8. Software and data integrity failures. Builds, updates, and deserialized data are verified before they are trusted. Fix: signed artifacts, pinned CI actions, no deserialization of untrusted objects.
9. Security logging and monitoring failures. Logins, access denials, and admin actions are logged without secrets and alerted on. Fix: structured security events routed to an owner, with retention stated.
10. Server-side request forgery. Any server fetch of a user-supplied URL is restricted to an allow-list and blocked from internal addresses. Fix: an egress allow-list and a resolver check that rejects private ranges and metadata endpoints.

## Authentication and session design (ASVS-informed)

- Prefer a proven identity provider (OIDC, SAML) over a home-built login.
- OAuth flows use authorization code with PKCE; no implicit flow, no tokens in URLs.
- JWTs: verify signature and algorithm (reject `none`), issuer, audience, and expiry; keep lifetimes short and plan revocation.
- Cookies that carry a session are HttpOnly, Secure, and SameSite; state-changing requests carry CSRF protection when cookies authenticate.
- Password reset and account recovery are as strong as login: single-use, short-lived, and not revealing whether an account exists.
- Secrets live in a managed store, never in code, logs, or client bundles, and have a rotation path.

## Planning checks

Apply these to a plan or design doc before code exists:

1. Every new trust boundary (a new endpoint, queue consumer, webhook, or third party) is listed with who may call it.
2. The plan names how each caller is authenticated and how each action is authorized.
3. Sensitive data is named, with where it is stored, how it is encrypted, and who can read it.
4. Session and token lifetimes, rotation, and revocation are stated.
5. Secrets have a named store and a rotation story; none are in config files or the client.
6. Untrusted input paths (forms, uploads, URLs, headers) name their validation and encoding.
7. Security events to log and alert on are named, with an owner.
8. Dependencies added by the plan are named, with how they are kept current.

## Agent protocol

1. Read the change through the ten categories, then report only the findings that apply.
2. Name the attacker and the asset for each finding; skip findings with neither.
3. Prefer the platform's proven control over a custom one.
4. Do not add controls the threat does not need.
