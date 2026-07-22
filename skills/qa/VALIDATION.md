# cf:qa validation prompt (run on a host with real Docker access)

This repo's cloud session proved the `cf:qa` orchestration (opus scope ->
clarify -> opus refine -> sonnet execute -> report) end to end against a
throwaway two-page Express app, using the sandbox's pre-installed local
Chromium in place of the ephemeral browserless Docker container, because
Docker registry pulls are network-blocked in that sandbox (the daemon runs,
but any `docker pull` gets a 403 from the egress policy). All four flows
passed; findings are in the PR description.

What was not provable there: the actual Docker+CDP path, and the wider range
of tech stacks the skill needs to hold up against. Paste the prompt below into
Claude Code on a host with real Docker access (e.g. the Mac mini) to finish
validation and land any further fixes as a follow-up PR against this branch.

---

## Prompt to paste

Validate the `cf:qa` skill (`skills/qa/SKILL.md` in `pstaylor-patrick/skills`)
against real Docker. Build each app below in a private temp directory outside
this repo (e.g. under `/tmp` or `~/scratch`), never commit them, and delete
them when done. For each app, invoke `cf:qa` ad hoc with a natural-language
target describing a real flow in that app, let it run its full phase
sequence, and confirm:

- Phase 1 (opus, background) produces a plan with concrete, disambiguated
  assertions and only flags `open_questions` that are genuinely ambiguous.
- Phase 2 only calls `AskUserQuestion` when phase 1 actually found ambiguity.
- Phase 3 correctly loops on your answers (test at least one app with a
  deliberately ambiguous target to exercise a second round) and hard-stops at
  3 rounds.
- Phase 4 (sonnet, background) launches the browserless Chromium image with
  `docker run --rm ...` (verify with `docker ps` mid-run that a container
  exists, and that it is gone after), connects Playwright over CDP, and tears
  the container down even when a flow fails.
- Phase 5 reports findings in chat, and only drafts/posts GitHub PR comments
  when the target is a real PR and after an explicit `AskUserQuestion`
  approval - confirm no comment ever posts without that approval, and that
  each posted comment is <= 640 characters (split into up to 3 if needed).

Apps to build and test against:

1. **Node.js + Express** - a couple of routes, one that renders server-side
   HTML, one JSON API route. Target: a rendered-page flow plus an API-only
   flow in the same run.
2. **Next.js (App Router)** - a page with server-side rendering and at least
   one Server Action (e.g. a form that mutates state without a client-side
   fetch). Target: confirm SSR content and that the Server Action's effect is
   observable after submit (Playwright waiting on the resulting DOM change,
   not on a network call it can see).
3. **Ruby on Rails** - a scaffolded resource (index/show/create) with a real
   form. Target: create-and-redirect-and-show flow, including a CSRF-token
   form submit (a stack Playwright/Docker-Chromium setups sometimes fight).
4. **Python (a local Lambda-style handler)** - use a lightweight local
   emulator (e.g. AWS SAM CLI `sam local start-api`, or a plain Flask/Chalice
   dev server standing in for the handler) fronted by a couple of HTTP
   routes. Target: an API-only flow with no browser chrome, to prove `cf:qa`
   degrades sensibly when there is little or nothing to visually assert.
5. **Multi-container Docker Compose app** - at least a frontend container plus
   a backend/API container (add a datastore container if convenient). Target:
   a flow that only passes if both containers are actually talking (e.g. a
   page that round-trips through the backend), to prove the skill's own
   ephemeral browserless-Chromium container coexists cleanly with a
   Compose-managed application stack rather than colliding with it.

For each app, after the run: note any place the skill's plan, clarification,
execution, or reporting behavior was wrong, silently guessed, or produced a
comment over 640 characters, and fix `skills/qa/SKILL.md` directly. Commit
each fix with a message naming which scenario surfaced it. Push to this same
branch (or its current tip if already merged - restart from `main` per the
repo's merge-mode rules) and leave a short summary of what each of the five
scenarios exercised and what, if anything, got fixed.
