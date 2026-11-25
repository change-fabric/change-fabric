// Human-readable release notes for the CHANGE.md frontmatter spec.
//
// Deliberately separate from the spec text itself. The spec's own "Changelog"
// section is written for someone implementing against the schema and reads like
// a field-set delta; this is written for someone deciding whether a version
// affects them, and says what changed, why, and what they have to do about it.
//
// One entry per version that has something to say. A version with no entry
// simply renders no panel, so adding a version here is optional and never a
// build-time requirement. Keyed by the exact version string used in
// src/spec.ts's VERSIONS, so the current version and every archived version
// resolve their own notes and never each other's.

export interface ReleaseHighlight {
  title: string;
  body: string;
}

export interface ReleaseNote {
  version: string;
  date: string;
  headline: string;
  highlights: ReleaseHighlight[];
  // What an existing CHANGE.md has to do to move to this version. Every
  // release so far has been additive, and saying so plainly is the single
  // most useful line on the page.
  upgrade: string;
}

export const RELEASE_NOTES: Record<string, ReleaseNote> = {
"0.35.0": {
  version: "0.35.0",
  date: "2026-11-25",
  headline: "Scheduled lanes: nightly and on-request checks with a one-flag-at-a-time matrix.",
  highlights: [
    {
      title: "A scheduled_lanes list in CHANGE.md",
      body:
        "A repo declares lanes that run on a cadence or on request. Each lane is graded only from a result file, records the deployed SHA around the run, and reports to a GitHub issue, a release comment or a chat command. An optional matrix turns on each listed flag alone in a non-production env and restores it, with a revert ledger written before every flip.",
    },
  ],
  upgrade: "Additive for CHANGE.md. Nothing changes until a repo declares scheduled_lanes and runs scripts/scheduled_lane.rb from a workflow.",
},
  "0.34.0": {
    version: "0.34.0",
    date: "2026-11-25",
    headline: "Timed testcase steps: a wait can pass, warn or fail on how long it took.",
    highlights: [
      {
        title: "Step timing with a warning band",
        body:
          "A testcase wait may declare timing with warn_ms and fail_ms. Under warn_ms it passes, up to fail_ms it passes with a warning, and at fail_ms it fails. The wait's timeout defaults to fail_ms plus 60 seconds so a slow step is measured, and a case with a timed step cannot retry. Reports gain a step_ms column.",
      },
    ],
    upgrade: "Additive for CHANGE.md. Nothing changes until a suite file declares suite_version 8 and a timing.",
  },
  "0.33.0": {
    version: "0.33.0",
    date: "2026-11-24",
    headline: "Row threshold: an operation can set how many rows a statement may touch before it needs a recovery artifact.",
    highlights: [
      {
        title: "Per-operation row threshold",
        body:
          "An operation may set row_threshold, a positive integer defaulting to 1000. Under an autopilot, a statement estimated to touch more rows runs only after a verified snapshot or checksummed dump.",
      },
    ],
    upgrade: "Additive for CHANGE.md. Nothing changes until an operation sets row_threshold.",
  },
  "0.32.0": {
    version: "0.32.0",
    date: "2026-11-22",
    headline: "Route states: the browserless lane grades layout stability of a route's UI states.",
    highlights: [
      {
        title: "Named states per route",
        body:
          "A route lists states, each reached from a fresh load by a click and a ready selector. Watched elements may not move or resize past a tolerance, and the page may not overflow in the state.",
      },
    ],
    upgrade: "Additive for CHANGE.md. Nothing changes until a route declares states.",
  },
  "0.31.0": {
    version: "0.31.0",
    date: "2026-11-20",
    headline: "Maintenance windows: ops wait for a window, fit its budget and always exit.",
    highlights: [
      {
        title: "Window, budget and lease",
        body:
          "An op waits for its window and is refused when its enter, verify, op and exit timeouts do not fit what is left. A durable lease is written before maintenance is entered, and exit always runs.",
      },
      {
        title: "A generated reconciler",
        body:
          "cf-prod-reconcile.yml runs every 10 minutes. It exits an expired lease only when no mutation started, and pages when an op is launching or uncertain.",
      },
    ],
    upgrade: "Additive for CHANGE.md. Add runners.prod.reconcile_role when maintenance has an enter command. maintenance.verify now exits 0 while maintenance is on.",
  },
  "0.30.0": {
    version: "0.30.0",
    date: "2026-11-20",
    headline: "Backup providers and a weekly restore probe: the runner refuses without recoverable data.",
    highlights: [
      {
        title: "Snapshot, PITR and restore probe",
        body:
          "RDS, Aurora, pg_dump to S3 and command backups take and verify a fresh snapshot, measure the PITR window and run a restore probe. An op is refused on PITR under 72 hours, a probe older than 7 days or failed, or a snapshot that fails verify.",
      },
      {
        title: "A generated weekly probe workflow",
        body:
          "cf-restore-probe.yml runs each probe weekly with its own role and uploads the evidence. Doctor flags a hand edit and a probe that no workflow runs.",
      },
    ],
    upgrade: "Additive for CHANGE.md. pg_dump_s3 and command backups now name a snapshot command.",
  },
  "0.29.0": {
    version: "0.29.0",
    date: "2026-11-20",
    headline: "Bounded prod runner keys: declared ops, backups and maintenance windows with fixed floors.",
    highlights: [
      {
        title: "runners, backups, maintenance and operations",
        body:
          "Declare the ops an agent may request, the backup each one needs, and the window it runs in. A validator enforces both approval factors with a remote proof, PITR of at least 72 hours, a 7 day probe age, a maintenance exit, and a window or reasoned online_safe opt-out on every op.",
      },
      {
        title: "Doctor reports the runner",
        body:
          "Doctor lists ops by class, flags every online_safe opt-out and every backup with no restore probe, and flags a hand-edited cf-prod.yml.",
      },
    ],
    upgrade: "Additive for CHANGE.md. A repo with none of the new blocks is unaffected.",
  },
  "0.28.0": {
    version: "0.28.0",
    date: "2026-11-20",
    headline: "Carve-out enforcement: the merge guard merges a carve-out PR only at a phone-approved head.",
    highlights: [
      {
        title: "admin_bypass.carve_out_paths is enforced",
        body:
          "The merge guard classifies a PR by the base carve_out_paths, renames on both names, and requires a phone passkey carve-out receipt for the exact head plus --match-head-commit. A gh error fails closed.",
      },
    ],
    upgrade: "Additive for CHANGE.md. A repo with no carve_out_paths is unaffected.",
  },
  "0.27.0": {
    version: "0.27.0",
    date: "2026-11-19",
    headline: "Roast floor 8: outbound messages and triage diagnoses may now stop at a score of 8.",
    highlights: [
      {
        title: "outbound.roast_target and roast_rounds",
        body:
          "roast_target is now 8 to 10 (default 8) and roast_rounds 1 to 5 (default 5). The triage gate min_score floor is 8. Open P1s go through the local P1 pass, not another roast.",
      },
    ],
    upgrade: "Additive for CHANGE.md. Every value valid before stays valid.",
  },
  "0.26.0": {
    version: "0.26.0",
    date: "2026-11-19",
    headline: "Passkey approvals: only a phone passkey approval, checked against pinned keys, unlocks a gate.",
    highlights: [
      {
        title: "require_approval_proof: passkey",
        body:
          "Accepts only a phone passkey approval with a console receipt. Overrides also need a 20-character reason and a receipt under 24h old when used. Run-time trust verifies proofs too.",
      },
      {
        title: "change_policy.approval_pins and admin_bypass.carve_out_paths",
        body:
          "The receipt key fingerprint and rpId the local pins must match, and the carve-out glob list, all read from the default branch or PR base.",
      },
    ],
    upgrade: "Additive for CHANGE.md. passkey requires approval_pins; proofless and terminal-minted records stop counting.",
  },
  "0.25.0": {
    version: "0.25.0",
    date: "2026-11-19",
    headline: "Approval proofs: the release gates verify who approved a step or an override.",
    highlights: [
      {
        title: "change_policy.require_approval_proof",
        body:
          "local accepts any verified approval proof, terminal TOTP included; remote requires a signed approval console receipt. An invalid proof is refused at every setting.",
      },
    ],
    upgrade: "Additive for CHANGE.md. Unset, records without a proof still pass with a warning.",
  },
  "0.24.0": {
    version: "0.24.0",
    date: "2026-11-18",
    headline: "Progressive delivery: flagged features walk named cohorts under absolute guards.",
    highlights: [
      {
        title: "change_config.delivery",
        body:
          "Flag adapters, metric sources, cohorts (selector, hash bucket, all), verdict sources, and rollouts whose ordered stages end at everyone, inline or in a per-flag delivery/<flag>.yml.",
      },
      {
        title: "change_policy.delivery",
        body:
          "Absolute guards, pacing, human checkpoints, and a breach response that turns the flag off first, then runs a roast-gated triage inside fixed limits. doctor reports every rollout and each floor it breaks.",
      },
    ],
    upgrade: "Additive for CHANGE.md. Nothing changes until a repo declares a delivery block.",
  },
  "0.23.0": {
    version: "0.23.0",
    date: "2026-11-18",
    headline: "A command entry's trust digest covers the scripts it runs.",
    highlights: [
      {
        title: "Covered files",
        body:
          "Repo files named in a command entry's run string are hashed into its trust digest, so editing one needs change_approve like editing the entry.",
      },
      {
        title: "lanes.command.commands[].trust_paths",
        body: "Repo-relative globs for files a script sources, folded into the same digest.",
      },
    ],
    upgrade:
      "Additive for CHANGE.md. Every command entry's digest changes once, so approvals recorded before 0.23.0 no longer match.",
  },
  "0.22.0": {
    version: "0.22.0",
    date: "2026-11-18",
    headline: "Test cases run as named personas, each logged in once per run.",
    highlights: [
      {
        title: "lanes.testcases.personas",
        body:
          "Named logins in the auth block's shape. A case names one with persona:, logs in once per run, and re-logs in once when its declared expired_when probe says the session ended.",
      },
      {
        title: "Duplicate suite ids",
        body: "Two suite files declaring the same suite id now fail to load, by name.",
      },
    ],
    upgrade:
      "Additive for CHANGE.md. Cases of one persona now share one login's server-side session instead of logging in per case.",
  },
  "0.21.0": {
    version: "0.21.0",
    date: "2026-11-18",
    headline: "Long test-case suites: one call per case, an opt-in parallel pool, and versioned suite files.",
    highlights: [
      {
        title: "lanes.testcases.parallel",
        body:
          "Each test case runs in its own browserless call with its own budget and duration. Serial by default, up to 10 at once.",
      },
      {
        title: "suite_version",
        body:
          "Suite files declare the format version they were written for. An install that is too old says to pull and run install.rb.",
      },
    ],
    upgrade:
      "Additive for CHANGE.md. Suite files with unknown keys now fail to load, and retries needs safe_rerun: true.",
  },
  "0.20.0": {
    version: "0.20.0",
    date: "2026-11-17",
    headline: "Lanes on a clock: scheduled runs, an opt-in active scan, and promotions that require a recent scheduled pass.",
    highlights: [
      {
        title: "change_config.schedules",
        body:
          "A named schedule runs the existing lanes against a profile on a five-field UTC cron, on a GitHub Actions or local runner, with its own zap.mode and k6.script overrides.",
      },
      {
        title: "Active scans are opt-in",
        body:
          "lanes.zap.mode stays baseline on every PR. full is an active scan, accepted only in a schedule override whose profile sets allow_active_scan: true.",
      },
      {
        title: "require_scheduled",
        body:
          "A promotion rule can require a passing run of a named schedule no older than max_age_days before it lets a change through.",
      },
    ],
    upgrade:
      "Additive. Nothing changes for a CHANGE.md that does not set the new keys.",
  },
  "0.19.0": {
    version: "0.19.0",
    date: "2026-11-16",
    headline: "Plan phases an outside agent runs, one checked send path, and a tracker workflow per project.",
    highlights: [
      {
        title: "execution and outbound",
        body:
          "An adapter hands a plan phase to an agent outside the harness through a labeled GitHub issue. Every message it causes goes through one send path that scans it, roasts written prose at 9 or more, caps spend at $2 per run, and holds instead of guessing.",
      },
      {
        title: "Tracker workflows",
        body:
          "change_policy.trackers declares a project's states, the moves each cf event makes, the evidence a move needs, and which role holds each state. Roles only, never a person; estimates, board moves and renames are locked off.",
      },
    ],
    upgrade:
      "Additive. Nothing changes for a CHANGE.md that does not set the new blocks.",
  },
  "0.18.0": {
    version: "0.18.0",
    date: "2026-11-13",
    headline: "Design targets: one design system per app in a monorepo, built from the live theme.",
    highlights: [
      {
        title: "design.targets",
        body:
          "Each target names its live theme, its presentational components and a kit package that renders them, so a prototype links the real system instead of a copied token file. An optional app link reuses that app's base_url and lane auth.",
      },
      {
        title: "Reference apps",
        body:
          "A target can name reference routes on a running app, with mask selectors for volatile regions and auth by env var name only. Prototype stills are compared with those captures before sign-off.",
      },
    ],
    upgrade:
      "Additive. A flat design block keeps working as one target named default. To adopt targets, move flat tokens or tailwind into a target entry; setting both forms is an error.",
  },
  "0.17.0": {
    version: "0.17.0",
    date: "2026-11-10",
    headline: "A command lane for your own checks, and host-run steps that run as the base branch defines them.",
    highlights: [
      {
        title: "lanes.command",
        body:
          "A sixth lane, run on the host: integration tests against a throwaway database container, an end-to-end suite, data cleanup, a deployed smoke test. Each entry passes on exit 0, has a required timeout, optional retries and a per-entry profiles filter, and its masked transcript and artifacts land beside the report.",
      },
      {
        title: "Base-branch trust for boot and command steps",
        body:
          "A boot step or command entry that differs from the base branch runs only after a human approves it for that commit with change_approve.rb, from their own terminal. Gate records carry each step's digest, and the merge and tag guards check them.",
      },
      {
        title: "boot.env and boot.timeout_seconds",
        body:
          "Boot steps see PATH, HOME, DOCKER_HOST, TERM, the CF_CHANGE_* values and the names boot.env lists, with declared values masked in output. boot.timeout_seconds bounds each step.",
      },
    ],
    upgrade:
      "Breaking. List every variable your boot needs under boot.env; boot.env_file keys are value sources only. A missing name stops the run and names it. Re-run change_run.rb all for any commit whose older gate record lacks a trust block.",
  },
  "0.16.0": {
    version: "0.16.0",
    date: "2026-11-10",
    headline: "The testcases lane can launch its browser with extra Chromium flags.",
    highlights: [
      {
        title: "lanes.testcases.launch_args",
        body:
          "A list of Chromium flags, each starting with --, for the browser every case runs in. The motivating case is --disable-features=LocalNetworkAccessChecks, so a code_source fetch can reach a private address like host.docker.internal.",
      },
    ],
    upgrade: "Nothing to do. The field is optional and additive.",
  },
  "0.15.0": {
    version: "0.15.0",
    date: "2026-11-07",
    headline:
      "A profile can say how the browser reaches a local HTTPS dev app behind a reverse proxy, so cf:change and cf:qa need no flags.",
    highlights: [
      {
        title: "boot.add_hosts maps a dev hostname into the browser container",
        body:
          "HOST:TARGET docker --add-host entries, TARGET an IP or host-gateway, because the container cannot read the host's /etc/hosts. Overridable per profile.",
      },
      {
        title: "boot.ignore_https_errors, for local targets only",
        body:
          "Skips the local dev CA's certificate check. Rejected at load unless boot.target_url is local, and while on, every HTTPS request to a non-local host from any page or popup fails, so no public certificate is skipped.",
      },
    ],
    upgrade:
      "Nothing to do. Both fields are optional and additive; a CHANGE.md without them runs exactly as it did under 0.14.0.",
  },
  "0.14.0": {
    version: "0.14.0",
    date: "2026-11-05",
    headline: "A repo can say whether the cf:change gate applies to every merge or only to environment promotions.",
    highlights: [
      {
        title: "change_policy.gate.require_on",
        body:
          "every_merge (the default, the 0.13.0 behavior) or promotion. Under promotion a PR merge into trunk passes without a recorded cf:change run, while merges between other protected branches and every tag: rule stay gated.",
      },
      {
        title: "change_policy.gate.trunk",
        body: "Names the trunk branch promotion exempts, main by default.",
      },
    ],
    upgrade: "Nothing to do. An absent gate block means every_merge, exactly the 0.13.0 behavior.",
  },
  "0.13.0": {
    version: "0.13.0",
    date: "2026-10-29",
    headline:
      "CHANGE.md can say where a project's design truth lives, which Figma file it answers to, and what the critics may spend.",
    highlights: [
      {
        title: "change_config.design, one block for design governance",
        body:
          "Names the canonical tokens.css, whether Tailwind is compiled for drift, a Figma file URL with its variables snapshot and Code Connect opt-in, per-area parity, roast settings, and critic_rounds. tokens.css stays the one source; Figma is evidence, never canon.",
      },
      {
        title: "Parity is stated, not guessed",
        body:
          "Each area is must_match, intentional, or unreviewed. An intentional divergence requires a reason, so a deliberate difference from Figma is recorded rather than silently accepted.",
      },
      {
        title: "Validated at load",
        body:
          "A figma.url that does not parse as a Figma file URL, an out-of-range roast target, rounds, max_usd, or critic_rounds, and any unknown key under design are config errors naming the field.",
      },
    ],
    upgrade:
      "Nothing to do. The block is optional and additive; a CHANGE.md without it parses and runs exactly as it did under 0.12.0, with roast spend capped at 2.00 USD by default.",
  },
  "0.11.0": {
    version: "0.11.0",
    date: "2026-09-15",
    headline:
      "The accessibility lane can log in, and a route it never actually reached stops counting as a clean one.",
    highlights: [
      {
        title: "lanes.a11y.auth, the same login block the browser lane already had",
        body:
          "Shorthand (login_url, email_env, password_env, the three selectors, wait_for_selector, timeout_ms) or an explicit steps[] list for a login that needs more than one form. It is compiled by the same flow compiler and run by the same login runtime as lanes.browserless.auth and lanes.testcases.auth, so a repo that has written its login once does not write a second dialect of it.",
      },
      {
        title: "One login, then every route",
        body:
          "The flow runs once in the scan page before the route loop, so every route after it is fetched with the session cookies. There is no per-route auth: true opt-in the way the browserless lane has one: an a11y route is a plain path string, and a login that has already happened costs a public route nothing.",
      },
      {
        title: "A redirected route now fails instead of warning",
        body:
          "Requesting /dashboard and being served /login means axe graded a page nobody asked about. That was a moderate warn, which reads as green on a summary, so a route list that had collapsed onto a single login page could report a clean lane. It is a failing finding now. A redirect that only adds or drops a trailing slash, or only changes scheme or host, is still not a redirect.",
      },
      {
        title: "A login that cannot run says so, and scans nothing",
        body:
          "An unset credential env var, a missing login_url, or a login that fails inside the container produces one auth login failure naming the reason plus one route not scanned finding per route. The lane never falls back to scanning those routes logged out, because the violations of a login page filed under seven route names is the false coverage this whole change exists to end.",
      },
    ],
    upgrade:
      "The fields are additive: a CHANGE.md with no a11y auth block still parses and runs. The redirect grading is not additive. If any a11y route currently redirects, that route moves from warn to fail, so a lane that was passing on warnings alone will go red until either the route is reachable or an auth block is added. That is the point of the release, but budget for it rather than meeting it at tag time.",
  },

  "0.10.0": {
    version: "0.10.0",
    date: "2026-08-22",
    headline:
      "A fifth lane runs regression cases committed to the repo, and four fields that were already live are finally documented.",
    highlights: [
      {
        title: "testcases: browser checks that give the same answer twice",
        body:
          "A case is a suite id, tags, a plain-English acceptance sentence, and a list of declarative steps. Ruby compiles those steps into the browser payload, so nothing is generated at run time and the same case at the same commit gives the same verdict. It shares the existing browser container and adds no image.",
      },
      {
        title: "Cases live beside the code they test, not in CHANGE.md",
        body:
          "lanes.testcases.suites is a list of globs naming sidecar suite files such as qa/checkout.cf-testcases.yml. Those files carry their own schema, their own spec doc and their own drift test, so a new step verb never needs a CHANGE.md version bump, and a repo with twenty flows does not carry twenty flows' assertions in its governance file.",
      },
      {
        title: "A failing case fails the gate, and gate_tags is the way in",
        body:
          "By default every case gates, because a test case that cannot fail the build is a comment. gate_tags names the tags that may fail the gate while a brand-new suite is still being trusted; the rest still run and still report. promotion.<ref>.require_testcases lets a branch require the lane specifically, which require_change_pass alone never asked.",
      },
      {
        title: "Four already-shipped fields stop being undocumented",
        body:
          "wait_for (an explicit readiness contract in place of a networkidle timing heuristic), retries (opt-in, zero by default, recording flaky beside a real status), cell_isolation (a fresh browser context per matrix cell) and locale (pinned, not inherited from the host) were all live in the code with no registry row. They have one now.",
      },
    ],
    upgrade:
      "Additive. A CHANGE.md with no testcases lane parses, runs, reports and gates exactly as it did under 0.9.0. Adopting the lane is two steps: write a suite file beside the flow it covers, and point lanes.testcases.suites at it.",
  },

  "0.9.0": {
    version: "0.9.0",
    date: "2026-08-22",
    headline:
      "A repo with one trunk and release tags instead of long-lived staging/production branches can now be governed too.",
    highlights: [
      {
        title: "tag: rules live in the same promotion map as branches",
        body:
          "change_policy.promotion accepts a tag:-prefixed key (tag:staging/v*) right alongside a branch key, in the same map. Every field a branch rule carries -- require_change_pass, profile, apps, review_required, ci_gate -- means exactly the same thing on a tag rule; promoting to staging is one concept, a branch topology expresses it as a merge and a tag topology expresses it as a tag push.",
      },
      {
        title: "Publishing a protected tag is gated, not just documented",
        body:
          "change_tag_guard.rb denies a git push (or gh release create) that would publish a matching tag with no passing cf:change run recorded for the exact commit, sharing its decision with the merge guard so both events answer the same question the same way.",
      },
      {
        title: "require_trunk_ancestor and require_prior_tag replace what branch order used to say for free",
        body:
          "A branch topology encodes promotion order and provenance in the graph itself: you cannot merge to production except from staging. A trunk with tags loses both unless a rule states them. require_trunk_ancestor: main stops a tag being cut on an unmerged commit; require_prior_tag: \"staging/v*\" requires the same commit to already carry a lower tag.",
      },
      {
        title: "change_run.rb all --for-tag and gate-status",
        body:
          "--for-tag <tagname> resolves a tag against its matching rules, sweeps the profile(s) they name, and refuses to run against the wrong commit. gate-status [--ref REF] is read-only -- no docker, no boot, no lanes -- and answers whether a ref's matching rules are already satisfied, the same question the tag guard's own deny decision answers.",
      },
    ],
    upgrade:
      "Fully additive. A CHANGE.md with no tag: key anywhere parses, runs, reports, and gates exactly as it did under 0.8.0; protected_branches is retained unchanged, and change_tag_guard.rb never fires without a tag rule to fire on.",
  },

  "0.8.0": {
    version: "0.8.0",
    date: "2026-08-21",
    headline:
      "A profile may now override the browserless lane's login flow, so one audit surface reaches environments that log in differently.",
    highlights: [
      {
        title: "browserless.auth is overridable per profile",
        body:
          "change_config.profiles.<profile>.lanes.browserless.auth.* deep-merges over the base browserless.auth block field by field. Staging's login url, its credential env vars, its selectors, its timeout, and each step of a multi-step login can differ from local dev's without a second CHANGE.md or a second lane.",
      },
      {
        title: "It is the second deliberate exception to \"a profile changes where, never what\"",
        body:
          "PROFILE_LANE_KEYS already treats zap.targets that way. A login url and its credential env vars are the same kind of exception: how a profile's environment is reached, not what gets audited once the login succeeds. Rejected on every other lane, including a11y, which drives a real browser page but only ever reads basic_auth.",
      },
    ],
    upgrade:
      "Fully additive. A CHANGE.md whose profiles declare no browserless.auth override parses, runs, reports, and gates exactly as it did under 0.6.0. 0.7.0 is skipped, not missing: it stays reserved for the contributors_team.artifacts removal 0.6.0 announced.",
  },

  "0.6.0": {
    version: "0.6.0",
    date: "2026-08-02",
    headline:
      "Findings artifacts publish through a hosted service instead of a bucket each team provisions for itself.",
    highlights: [
      {
        title: "organization, team and platform replace the artifacts block",
        body:
          "A repo now says where its findings go with two slugs and a small platform block: which organization and team it belongs to on the hosted service, and which API origin to talk to. It no longer names a bucket, a region, a CloudFront distribution, a DynamoDB table, or an AWS profile, because none of those are the repo's to state.",
      },
      {
        title: "Publishing is three HTTP calls and no cloud credential",
        body:
          "The publisher declares the run and its files, PUTs each file to the presigned URL that comes back, and says it finished. It authenticates with a team API key and nothing else. There is no AWS SDK on the client, no AWS credential, no bucket name, and no key prefix: the service assigns the prefix, records the run, lists it on the team's findings page, and decides who may open it.",
      },
      {
        title: "A team API key lives in the Keychain, not in the repo or the shell",
        body:
          "ruby scripts/cf_team_join.rb --platform <organization> <team> --stdin stores a contributor's key in the macOS Keychain under service change-fabric-platform, account <organization>/<team>. The publisher reads the environment variable named by api_key_env first and falls back to that entry.",
      },
      {
        title: "One command migrates an already registered team",
        body:
          "ruby scripts/cf_team_migrate.rb --org <slug> --email <you> carries an existing registration onto the platform in a single run: it resolves or creates the organization, a team carrying the old team_id as its legacyTeamId and the old public key, your own membership, one contributor alias per roster entry, a repo link, and a team API key.",
      },
      {
        title: "The legacy identity fields are not going anywhere",
        body:
          "team_id, public_key_ed25519 and contributors are not deprecated and have no removal version. They are what the presence and secret-alert capabilities read: this machine's identity resolves from them, the telemetry Lambdas verify signatures against the public key, and the cf-teams table is keyed on team_id. A migrated repo carries both sets permanently, and they answer different questions: who the contributors are, and where the artifacts go.",
      },
      {
        title: "artifacts is deprecated, not removed",
        body:
          "The per-team S3 bucket block still parses and still resolves a configuration. When both are present, platform wins. The legacy block is removed at 0.7.0, and it is the only thing in contributors_team slated for removal.",
      },
    ],
    upgrade:
      "Additive. A CHANGE.md with no platform block captures no media, builds no bundle, publishes nothing, and audits, reports and gates exactly as it did under 0.5.0. Publishing stays best effort: a publish that fails is a named warning on a run whose verdict the four audit lanes alone decided.",
  },

  "0.5.0": {
    version: "0.5.0",
    date: "2026-08-01",
    headline:
      "contributors_team is documented for the first time, and gains a findings-artifact pipeline.",
    highlights: [
      {
        title: "The third top-level block finally has a spec",
        body:
          "team_id, public_key_ed25519 and contributors[] were always read by the code; until 0.5.0 the field registry covered only two of the three frontmatter blocks. Naming them here closes that gap. No behaviour changed with the documenting.",
      },
      {
        title: "A sweep can publish its findings as a self-contained artifact",
        body:
          "With an artifacts block present, a completed sweep renders one static HTML page carrying the run's contributor and git context, every lane's findings, the browserless lane's full-page screenshots, one recording per viewport, and one annotated PDF per viewport, then uploads the bundle to the team's private S3 bucket behind CloudFront and rebuilds the team index from a DynamoDB listing.",
      },
      {
        title: "Provisioning is one human-run command",
        body:
          "ruby scripts/cf_artifacts_init.rb <team_id> creates the bucket, the distribution, the Basic Auth CloudFront function and the manifest table, then prints the artifacts block filled in.",
      },
      {
        title: "Nothing in the block is a credential",
        body:
          "basic_auth names where the viewer credential lives (an SSM SecureString parameter, a 1Password item reference), never what it is. The CloudFront function that enforces HTTP Basic Auth carries only the SHA-256 digest of that credential, because a CloudFront function has no network access and cannot fetch a secret at request time.",
      },
      {
        title: "Media capture is tunable",
        body:
          "media.screenshots, media.video and media.video_fps decide what the browserless lane captures for the artifact. The recording travels base64 inside that lane's single browserless response, so the frame rate is the main lever on that payload.",
      },
    ],
    upgrade:
      "Additive and default off. A CHANGE.md with no artifacts block captures no media, builds no bundle, uploads nothing, and audits, reports and gates byte for byte as it did under 0.4.0. Publishing is reported separately from the gate, since the four audit lanes are the release decision and the artifact is the evidence attached to it.",
  },

  "0.4.0": {
    version: "0.4.0",
    date: "2026-07-27",
    headline:
      "One repo can register several genuinely different apps, and a ZAP scope can travel between deploy targets.",
    highlights: [
      {
        title: "change_config.apps, a monorepo registry",
        body:
          "Each app gets its own config file, conventionally <app-dir>/CHANGE.app.yml, carrying its own boot, lanes and profiles. This is the axis profiles deliberately does not cover: a profile changes where one audit runs, never what it audits, so a second app with different routes, a different boot and no auth at all cannot be expressed as a profile. An app file's only accepted top-level key is change_config; governance stays repo-wide in the root CHANGE.md.",
      },
      {
        title: "Sweeps and gates became app-aware",
        body:
          "A bare sweep runs every registered enabled app and passes only if all of them pass. --app NAME narrows it, repeats, and composes with --profile. The gate record for a head SHA carries a per-app map and merges across separate --app runs instead of overwriting. change_policy.promotion.<branch>.apps restricts which apps' passes gate a branch; omitted, every registered enabled app is required.",
      },
      {
        title: "Relative ZAP targets",
        body:
          "lanes.zap.targets entries may be relative and resolve against the lane base url, exactly as a11y.routes and browserless.routes already do, so a multi-path ZAP scope is portable across profiles instead of pinning every profile to one committed host. A profile may restate targets for the one case relative paths cannot express, a scope spanning two genuinely distinct services.",
      },
      {
        title: "doctor names the deployment each lane will actually hit",
        body:
          "It prints every enabled lane's resolved target and warns when an absolute lane literal's host differs from the resolved profile's boot target host. The report meta and the gate record now carry the resolved profile and target, not just the requested one, so a report states which deployment it audited. --target-url and --health-url override the resolved target at invocation time, so an ephemeral preview deployment's url never has to be committed.",
      },
    ],
    upgrade:
      "Additive. A CHANGE.md with no apps key parses, runs, reports and gates exactly as it did under 0.3.1. When apps is present the root may not also declare its own boot, lanes or profiles, so adopting the monorepo shape is a verbatim move of the existing block into one app file.",
  },
};

export function releaseNote(version: string): ReleaseNote | undefined {
  return RELEASE_NOTES[version];
}
