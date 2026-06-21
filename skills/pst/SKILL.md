---
name: pst
description: Activate Patrick's engineering doctrine as hard, standing rules for the REST of this session, portable to whatever repo or area you're in. Eager background-agent swarms in isolated worktrees, mandatory adversarial review, root-cause CI fixes, local-k8s QA arsenal as the quality gate before any remote deploy, squash-merge-only-on-green-CI, run-to-completion persistence, and a no-em-dash / de-slop voice enforced by session-scoped hooks. Invoke when the user types /pst, or says "enter pst mode", "apply my dev preferences here", "bring my doctrine to this repo".
argument-hint: "[off]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion, Skill
---

# /pst, Patrick's engineering doctrine (session mode)

Invoking installs the rules below as standing preferences for the rest of the
session, layered over everything else until the session ends or a rule is
overridden. Comply silently; do not re-announce the doctrine each turn; surface a
rule only when it changes what you are about to do. `[HOOK]` marks rules a hook
enforces deterministically (a block or an automatic action); `[NUDGE]` marks
rules a hook reminds about (non-blocking). Detail and examples are in
`REFERENCE.md`.

## On invoke

1. Bootstrap (install the inert global hook shim if missing, git identity guard,
   arm this session): `ruby "$(dirname "$0")/scripts/pst-mode.rb"`
2. Ask the merge mode with `AskUserQuestion`, re-asking on every invoke so it can
   change per repo: **admin-bypass squash** / **auto-merge on approval** /
   **merge-ready only** / **local only**. Hold the choice for the session.
   Approval-gated repos (for example REDACTED, where Conner must approve) must not
   be admin-bypassed. If **local only** is chosen, run `ruby
"$(dirname "$0")/scripts/pst-mode.rb" local on` so the guard enforces it (rule
   18).
3. Confirm PST mode active in one line plus the chosen merge mode, and state the
   delegate-by-default rule (implementation goes to background worktree agents,
   not inline), then continue.

`/pst off` disarms this session.

## Doctrine

1. **Delegate by default** `[NUDGE]`. Before doing a unit of work inline, test
   it: (1) independent (no live user back-and-forth), (2) well-scoped (clear
   inputs, verifiable done-condition), (3) not a gating judgment (a plan, a
   choice between options, or accept-reject validation). All three yes: spawn a
   background agent in an isolated worktree (Sonnet/medium by default, tier per
   rule 2). Any no: foreground is right. Legitimately foreground: conversational
   replies, planning and decomposition (for non-rule-19 work), choosing between options, spawning and
   monitoring and merging agents, final validation (for non-rule-19 work), and a lone trivial edit
   (batch several trivial edits to one Haiku agent). The default verb for
   implementation, research, format fixes, and sequential mechanical work is
   delegate; inline work is the exception to justify. Fan out via `/pst:sweep`,
   `/pst:ready`, `/pst:auto`, and workflow. For feature and fix work specifically, prefer the three-agent pipeline (rule 19).
2. **Model tiers** `[HOOK]` (default, not absolute): foreground Opus/high;
   background implementers Sonnet/medium; Opus only for deep audits; Haiku/low for
   trivial, well-defined mechanical work. Spawns must set an explicit model
   (enforced); escalate on ambiguity; default Sonnet/medium.
3. **Isolated worktrees.** Any file-mutating agent runs in its own worktree.
   Read-only exploration does not.
4. **Tidy, prompt before destroying.** Run `scripts/pst-worktrees.rb`, prompt
   before pruning; never auto-prune. Surface other cleanups as suggestions.
5. **Merge** `[HOOK]`. PR then prefer squash, by the chosen merge mode. A direct
   `gh pr merge` is blocked unless CI is fully green; `--auto` defers to GitHub;
   override `PST_ALLOW_RED_MERGE=1`. `/pst:ready` and `/pst:rebase` assist.
   **PR creation always includes CI watch and merge -- do not ask.** In
   admin-bypass mode, the moment a PR exists and adversarial review is recorded
   (rule 7), immediately queue `gh pr merge --auto --squash` so GitHub merges
   when CI goes green. Never stop after PR creation and ask whether to watch CI;
   that is always yes. If `--auto` is unavailable on the repo, fall back to
   `gh pr checks <PR#> --watch` then merge on pass. If CI did not trigger,
   re-run with `gh pr checks <PR#> --rerun-failed` and watch.
6. **CI root cause.** Fix CI for real; no band-aids that mask the issue. Flag any
   unavoidable quick fix as debt.
7. **Adversarial review before merge** `[HOOK]`. At least one round
   (`/pst:adversarial-review`, `/pst:code-review`); implement findings and
   re-review to clean. Record it with `scripts/pst-reviewed.rb mark` so the merge
   guard allows the merge.
8. **Local k8s gate before remote.** If the app runs in the local k3s cloud,
   deploy and pass real E2E there before any remote (AWS, staging, prod). Gate
   pre-merge via blue-green when CI auto-deploys on merge, else pre-promotion.
9. **QA arsenal, with discernment.** Use `cluster-qa-audit` (Playwright, axe, ZAP
   active, k6) and `private-cloud-deploy` when a change warrants it; skip for copy
   or docs changes.
10. **Identity.** Every commit, including background agents, uses the no-reply
    email `1963845+pstaylor-patrick@users.noreply.github.com`.
11. **No em dashes** `[HOOK]`. Rewrite with commas, colons, parentheses, or two
    sentences. Find or strip with `scripts/pst-emdash.rb check|prune`.
12. **De-slop.** Cut filler, hedging, marketing, restated obvious, emoji. In
    code: YAGNI, KISS, no speculative generality, no error theater, delete dead
    code. Gate with `/pst:slop`.
13. **Run to completion.** On completion-intent ("don't stop until you're done"
    and similar), work autonomously through every gate; stop early only for a
    real blocker or a user-only decision.
14. **Prove it works.** Wait for green in the target environment, then validate
    with real E2E (scaled per rule 9). Never report success from "should work"
    or a passing unit test alone.
15. **Refactor like a craftsman.** Two hats (never mix refactor with behavior
    change), refactor only under green tests (characterization tests first), Tidy
    First, no coverage regression on changed lines, rule of three before
    abstracting. Smell catalog in `MAINTAINABILITY.md` (shared with rule 23).
16. **Response brevity** (soft default). Keep each paragraph to 320 characters or
    less and each flat-list bullet to 160 or less; prefer at most 5 bullets. Split
    long prose into multiple short paragraphs rather than one long one.
    Enumerations the user asks for (PR lists, Jira tasks) may exceed the bullet
    count.
17. **Open on post** `[HOOK]`. Actions taken under Patrick's name open in the
    browser so he sees what went out with his face on it: a PR created, a
    PR/issue or Jira comment posted, a Jira issue created, and a PR/issue/Jira
    description updated. Side effect, not a block. Skip a run with
    `PST_NO_BROWSER=1`.
18. **Local-only mode (merge mode 4)** `[HOOK]`. When chosen, the guard denies
    every remote GitHub mutation (`git push`, `gh pr` and `gh issue`
    create/merge/ready/edit/comment/close); work stays in local worktrees and
    commits. This is the mode for validating a complex feature set end to end in
    the local k3s cluster first (rules 8, 14): build it across stacked local
    feature branches, deploy to an arbitrary `*.pstaylor.net` subdomain, prove it
    there, and only later reconcile the stack into real GitHub PRs under another
    merge mode. Arm with `pst-mode.rb local on`; bootstrap resets it each invoke.
    Override once with `PST_ALLOW_REMOTE=1`.
19. **Three-agent sequence for features and fixes** `[NUDGE]`. For any feature implementation or bug fix, run this pipeline. Haiku helper stages handle discovery, compression, scaffolding, cleanup, and the commit message around the three thinking tiers (Opus plan, Sonnet implement, Opus validate). Skip the whole pipeline only on a clear rule-2 trivial match; the Stage 0 classifier makes that call. 0. **Haiku classifier** (background, `model: haiku`, `effort: low`): read the request and return `trivial` or `substantive` plus a rationale (80 chars max). Trivial means a clear rule-2 Haiku-tier match; anything else or any doubt is `substantive`. On `trivial`, skip stages 0.5 through 4.5 and handle directly. Schema and sample prompt in `REFERENCE.md`.
    0.5. **Haiku pre-flight** (background, `model: haiku`): scout the repo (directory tree, recent git log, relevant file contents) and hand the Opus planner a compact context bundle so Opus tokens go to reasoning, not discovery.
    1. **Opus planner** (background, `model: opus`, `effort: high`): produce a concrete, step-by-step implementation plan with file targets and acceptance criteria, using the pre-flight bundle as context.
       1.5. **Haiku distiller** (background, `model: haiku`): compress the Opus plan into a 320-character exec summary for the plan gate. Haiku compresses; Opus thinks.
    2. **Plan gate**: foreground `AskUserQuestion` presents the distilled summary (320 characters max). Up to two additional questions if needed. Proceed only on approval; treat no objection as approval.
       2.5. **Haiku test scaffolder** (background, `model: haiku`, isolated worktree per rule 3): from the plan's acceptance criteria, write failing test stubs and fixture files so the implementer has a concrete target.
    3. **Sonnet implementer** (background, `model: sonnet`, `effort: medium`, same worktree as Stage 2.5): implement the plan exactly as written, no additions, making the scaffolded stubs pass.
       3.5. **Haiku lint/format** (background, `model: haiku`): cleanup pass after implementation (em-dash check via `scripts/pst-emdash.rb`, import sorting, trailing whitespace, obvious style) so the validator sees clean output.
    4. **Opus validator** (background, `model: opus`, `effort: high`): verify the implementation matches the plan, run smoke/integration tests, apply any inline fixes, then report results.
       4.5. **Haiku commit writer** (background, `model: haiku`): after validation passes, read the diff and the original plan and produce a conventional-commit message (rule-10 co-author trailer, no em dashes).

20. **OrbStack Docker for ephemeral infra and app servers** `[NUDGE]`. Common dev infrastructure (Postgres, Redis, RabbitMQ, and similar) AND application dev servers (Next.js, and similar Node/frontend apps) must run as OrbStack Docker containers, not as native installs, bare k3s services, or host-native `npm run dev`. Prefer a named `docker run -d` over compose when a single service suffices. Track each session-scoped container with `scripts/pst-docker.rb register <name-or-id>` so the session-end hook can reap it (`docker stop` + `docker rm`). Containers started with `--rm` are self-cleaning and do not need tracking. Suppress reaping with `PST_KEEP_DOCKER=1`.

    For tailnet access from any device, run containers through the shared host Caddy proxy: start the container with a published host port, pick a subdomain under `dev.pstaylor.net` (e.g. `app-x.dev.pstaylor.net` for the primary branch, `app-x-<shorthash>.dev.pstaylor.net` for ephemeral variants), add a Caddy route via the admin API, and register with `pst-docker.rb register <name> <port> <subdomain>`. The session-end reaper removes the Caddy route and the container. One wildcard `*.dev.pstaylor.net` A record (Route53) and one wildcard TLS cert (DNS-01/Route53) back all envs; no per-environment DNS or cert work is needed.

    **Escape hatch:** when an app has hard host-whitelisting (NextAuth/Auth.js OAuth callbacks, Google/GitHub OAuth apps, CORS allowlists), set the app's self-URL env var (e.g. `NEXTAUTH_URL`, `AUTH_URL`, `NEXT_PUBLIC_SITE_URL`) to `http://localhost:3000` and access it on that port instead. The `localhost` mode is explicitly sanctioned. For throwaway A/B variants of OAuth-locked apps, use mock sessions or MailPit magic-link rather than live third-party OAuth.

21. **gh CLI for GitHub** `[NUDGE]`. Use `gh` as the primary interface for all GitHub interactions: creating PRs, viewing checks, commenting, listing issues, and cutting releases. Do not reach for the browser or raw API calls when `gh` covers the task. Common invocations: `gh pr create`, `gh pr checks`, `gh pr view --web`, `gh issue list`, `gh release create`. Read commands are always allowed; mutating commands are blocked in local-only mode (rule 18).

22. **Multi-repo orchestration ledger** `[NUDGE]`. When spanning 2 or more repos, directories, or parallel tasks in a single session, initialize a session ledger (`pst-ledger.rb init` -- called automatically on arm) and register each spawned task on creation (`pst-ledger.rb register <id> --repo <path> --intent <summary>`). Update status on completion (`pst-ledger.rb done|fail <id>`). Pass `pst-ledger.rb context` as the context header to each new agent so sibling task state is always known. Inspect with `/pst:tasks`.

23. **Maintainability review on every code change** `[NUDGE]`. After any change that touches at least one code file (non-docs, non-lockfile), run a Fowler-smell pass using `MAINTAINABILITY.md` as the rubric. This is a separate refactoring commit (two hats per rule 15): behavior stays identical, only structure improves. The pass is Haiku-tier since it is lightweight. The only exemption is a changeset that touches zero code files (docs-only, lockfile-only, or pure config values). A small diff does not exempt a change -- smells manifest at any size. Run with `/pst:adversarial-review` or inline. See `MAINTAINABILITY.md` for the 16 canonical smells.

24. **Best-of-N implementation tournament** `[NUDGE]`. For substantive refactors or extensions where multiple valid implementations exist, spawn 2-5 parallel Sonnet agents in isolated worktrees with divergent strategies, then have an Opus judge pick the winner using MAINTAINABILITY.md criteria. Skip for trivial one-way fixes. Rule 15 two-hats applies. `/pst:refactor` is the full implementation protocol.

## Usage

`/pst` activates, `/pst off` disarms. Mechanics, merge modes, and rule detail are
in `REFERENCE.md` beside this file; read it only when you need specifics.
