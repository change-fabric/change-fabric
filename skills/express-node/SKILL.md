---
name: cf:express-node
description: Express and Node.js ESM backend. Auto-applied by the cf shim on every Express backend change; also invocable directly.
auto:
  extensions: [js, mjs]
  require:
    - dep: [express]
  detect: [package.json, "**/server.js", "**/app.js", "**/routes/**/*.js"]
---

# Express and Node ESM Cheat Sheet

Source: Express 5 Guides + Express Production Best Practices + Node.js Security Best Practices

Question: Will every request be validated, bounded, and failed through one path?

Favor:
- Use ESM and one router module per resource.
- Validate `params`, `query`, and `body` before handler logic.
- Use `async` handlers and one terminal error middleware.
- `return` after `res.send`, `res.json`, or `res.end`, unless a local middleware convention deliberately falls through.
- Set `helmet()` and explicit CORS policy.
- Set JSON and urlencoded body size limits.
- Log method, path, status, latency, and request id.
- Handle `SIGTERM` and close servers gracefully.

Forbid by default:
- Throwing strings.
- Sending raw error objects or stacks to clients.
- Trusting `req.body` shape without validation.
- Floating promises in middleware or handlers.
- Sync `fs` calls in the request path.
- Missing 404 and error middleware at the end of the stack.

CI:
- `npx --no-install eslint . --max-warnings 0`
- `npm audit --omit=dev`

Agent protocol:
1. Validate request boundaries first.
2. Route success and failure through one path.
3. Add security headers, limits, and graceful shutdown.
4. Defer to an established local convention when it conflicts with a line here.
5. Preserve behavior.
