---
name: cf:screenshot
description: Captures before/after screenshots of every configured route and viewport at two git refs, keeps only the pairs that pixel-differ, uploads them to GitHub, and offers to splice them into the pull request body's Demo section. Boots the base ref in an ephemeral git worktree inside the existing ephemeral browserless Chromium container tooling; invocable directly.
---

# CF screenshot

Question: what visibly changed on screen between two git refs?

Not "does this page pass a rubric", which is what `cf:a11y` and the browserless
lane of `cf:change` answer. This tool photographs the same route at the same
viewport at two refs, compares the two images pixel by pixel, and keeps only the
pairs that actually differ. Everything else is discarded, so what reaches a pull
request is signal only.

## Doctrine: cf:docker applies

One ephemeral, digest-pinned browserless Chromium container per run, started
through `ChangeDocker.with_browserless`, `--rm`, torn down on exit whether the
run succeeds or raises. Never a host browser, never a long-lived container,
never a second pinned image. The full rubric is `skills/docker/SKILL.md`.

Docker unavailable is a stop, not a fallback.

## Trigger and flags

```
/cf:screenshot [<target>] [--base <ref>] [--base-url <url>] [--pr <number>] [--no-upload]
```

The work is done by the script, run from the target repo root (a repo carrying
a root `CHANGE.md`):

```
ruby ~/.claude/cf/bin/change_screenshot.rb \
  [--base <ref>] [--base-url <url>] [--config <path>] \
  [--profile <name>] [--out <dir>] [--pr <number>] [--no-upload]
```

- `--base <ref>` overrides ref resolution entirely, using the ref literally.
- `--base-url <url>` points the base side at something already running and
  skips the worktree and the boot for that side.
- `--out <dir>` is where the PNGs and `manifest.json` land (default
  `cf-screenshots/`).
- `--no-upload` captures and diffs without touching GitHub.

## Ref resolution

In order, with no step guessing a branch name:

1. `--base <ref>` given: use it literally, no merge-base computation.
2. A resolvable pull request: the merge-base of HEAD and its base branch.

   ```sh
   base_ref=$(gh pr view "$PR" --json baseRefName --jq .baseRefName)
   base=$(git -C "$REPO" merge-base HEAD "origin/$base_ref")
   ```

3. Otherwise the merge-base of HEAD and the repo's default branch.

   ```sh
   default=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD)
   base=$(git -C "$REPO" merge-base HEAD "$default")
   ```

   If `origin/HEAD` is not set, the default branch comes from `gh repo view
   --json defaultBranchRef --jq .defaultBranchRef.name`, prefixed with
   `origin/`.

4. If that also fails, abort naming the problem. Guessing `main` against a repo
   that uses something else produces a diff that is wrong without looking
   wrong.

Merge-base rather than the branch tip is the point: it is the only choice that
guarantees the diff is caused by this branch alone rather than by trunk drift
that landed after the branch forked. The resolved merge-base commit, not a
branch tip, is what gets checked out.

## Capture

The flow, in order:

1. Resolve the base ref.
2. Preflight: if `boot.up` is configured and the health URL already answers
   with `expect_status` before anything has been booted, a stale server is
   holding the port. Abort, naming the URL and the listener.
3. Base side. With `--base-url`, skip to step 4 and point capture at that URL.
   Otherwise:

   ```sh
   d=$(mktemp -d) && git -C "$REPO" worktree add --detach "$d" "$base"
   # boot.up with chdir set to "$d", wait_healthy, capture, boot.down
   git -C "$REPO" worktree remove --force "$d"
   ```

   `--detach` matters: a merge-base is a commit, not a branch, and a
   non-detached add of a bare commit fails. `chdir` is the worktree, never the
   repo root: booting the base side from the main working tree boots HEAD's
   code and produces a same-ref-twice diff presented as a real one.
4. Verify the base side's server is gone. See below.
5. Boot and capture HEAD in the main working tree, which is already on HEAD, so
   no second worktree is needed.
6. Diff, then tear HEAD's app down the same way.

Each shot is a full-page PNG, not the audit lane's quality-72 JPEG: these
images are both the deliverable a human reads inline and the diff's own input,
where a lossy encoder's ringing around text is indistinguishable from a real
change. The stability CSS (`DIFF_STABILITY_CSS`: animations and transitions
frozen, caret hidden, font smoothing pinned) is injected before every shot, and
`deviceScaleFactor` is pinned to `DEVICE_SCALE_FACTOR`.

Before each shot the page is settled: web fonts awaited, then
`document.documentElement.scrollHeight` polled until three consecutive readings
agree, bounded by `SETTLE_TIMEOUT_MS`. The lane's readiness contract answers
"has a document been parsed", which a client-rendered app satisfies before it
has rendered anything, so a full-page shot taken on that signal alone catches
some cells mid-render and others complete, and the diff then reports that race
rather than the branch. This is a condition, not a fixed sleep: a page that
genuinely never settles is photographed at the bound rather than hung on.

### Verify the old server is gone

Do not trust `boot.down` exiting. After it returns, poll the health URL every
second for up to 30 seconds and require it to stop answering with
`expect_status`. A connection refused, a non-2xx, and a curl failure all count
as gone; the question is whether the old server is still serving, not why it is
not.

If it is still answering at the deadline, fail loudly, naming the health URL,
the port, and the listening process (`lsof -nP -iTCP:<port> -sTCP:LISTEN`, best
effort), and do not capture the second ref. The single worst failure mode for a
before/after tool is photographing the same ref twice and presenting it as a
correct diff, so a stuck port is a hard stop.

## Route and viewport source

`lanes.browserless.routes` and `lanes.browserless.viewports`, from the target
repo's root `CHANGE.md`, read through the same `normalize_route` and
`DEFAULT_VIEWPORTS` the browserless audit lane uses. A mapping-shaped route
entry keeps its `wait_for` readiness contract.

There is no new `CHANGE.md` config key for this capability, and none should be
added. A repo that already declares what to audit has already declared what to
photograph; a second parallel route list would drift from the first and quietly
photograph a different site than the one being audited. Nothing here needs a
`ChangeSchema::VERSION` bump or a spec release.

## Diff and filtering

Capture the full route x viewport matrix at both refs and keep only the pairs
that differ. Fully deterministic: no model call decides what is interesting.

- Per-pixel comparison uses `ChangeLaneBrowserless.diff_against_reference_js`
  at `FIGMA_DIFF_THRESHOLD` (32, the RGB Euclidean-distance cutoff). What counts
  as two pixels being different does not depend on why they are being compared.
- A pair counts as changed when its `diffPercent` exceeds
  `CHANGED_MIN_DIFF_PERCENT` (0.1). Below that a pair is noise: a re-rendered
  timestamp, one antialiased glyph.
- A dimension mismatch (`shotWidth != refWidth || shotHeight != refHeight`) is
  changed regardless of `diffPercent`. The diff function only compares the
  overlapping region, so a full-page capture that got taller is a real layout
  change the overlap's percentage would understate.
- A route present at only one ref (a new page, a deleted page) is kept and
  marked as such, never dropped. It is the most visible change there is.

Unchanged pairs are discarded and never uploaded.

## Upload

Uploads go to GitHub's own user-attachments endpoint, the one the web UI uses
when an image is pasted into a comment. Stable inline URLs, nothing added to
repo history, no third-party host. This is the toolkit's one raw HTTPS call to
GitHub; every other GitHub interaction goes through a `gh` subcommand, and this
one does not because the endpoint has no `gh` subcommand and no Octokit
support. The token still comes from `gh auth token`, so no new credential is
introduced, and it is never logged.

```
POST https://uploads.github.com/user-attachments/assets
  ?name=<basename>&content_type=image%2Fpng&repository_id=<numeric id>
Authorization: Bearer <token>
Content-Type: image/png
<binary body>
-> 201 {"url":"https://github.com/user-attachments/assets/<uuid>"}
```

`repository_id` is the numeric database id from `gh api repos/<owner>/<repo>
--jq .id`, not the GraphQL node id `gh repo view --json id` returns. The
endpoint rejects the node id with a status that reads like an auth problem.

The equivalent a human can paste to reproduce a failure by hand:

```sh
curl -sS -w '\n%{http_code}\n' -X POST \
  -H "Authorization: Bearer $(gh auth token)" \
  -H "Content-Type: image/png" \
  --data-binary @"$file" \
  "https://uploads.github.com/user-attachments/assets?name=$(basename "$file")&content_type=image%2Fpng&repository_id=$repo_id"
```

Confirm an uploaded URL renders inline by asking GitHub to render it: `gh api
/markdown -f text=...` rewrites it to a signed
`private-user-images.githubusercontent.com` URL.

Documented risks, accepted rather than designed around:

- The endpoint is undocumented. GitHub has acknowledged the gap without
  shipping docs, so it can break silently.
- There is no delete API. An attachment uploaded by a run that then failed is
  an orphan that 404s publicly until something references it.
- Behavior under an Actions `GITHUB_TOKEN` is unverified. It was confirmed with
  a user's own `gh auth token` only. This is a locally-invoked skill, not a
  CI-mandatory one; if it is ever wired into a workflow, test this first.

Anything other than 201, a missing or unauthenticated `gh`, or a network error:
stop uploading, report every local file path from the manifest, and say the run
degraded. Do not retry against a different mechanism, and do not fail the whole
run. The captures are useful without the inline embed.

## The `## Demo` section

Compose a `## Demo` markdown section pairing each surviving before/after image
by route and viewport, appending to an existing Demo section rather than
replacing the body if the pull request already has one.

Then call `AskUserQuestion` showing the composed section and asking whether to
write it, edit it first, or skip. Write via `gh pr edit --body` only on explicit
approval, preserving the rest of the existing body.

A pull request body edit is comment-class, not landing code. cf merge mode does
not gate it: post in every mode (Local only included) whenever the user
approves, mirroring the carve-out already in `skills/code-review/SKILL.md`.
Merge mode restricts only landing code, never commentary on a pull request that
already exists.

Under away mode, skip the question, do not edit, and report that the edit was
skipped, mirroring `cf:qa`'s report phase.

## Output

`<out_dir>/manifest.json` lists every route/viewport pair with both local image
paths, its `diffPercent`, and whether it was kept as changed, alongside a
human-readable summary on stdout. The upload step and the Demo composer both
read the manifest, so a run can be re-uploaded without being re-captured.

## Failure modes

- **Docker unavailable, or the browserless image cannot be pulled.** Report and
  stop. No unmanaged host-browser fallback.
- **The upload fails** (non-201, no `gh auth token`, a network error). Degrade
  to reporting the local screenshot paths from the manifest and stop uploading.
  Not a run failure.
- **The old server is still responding after teardown.** Fail loudly, naming
  the health URL, the port, and the listening process. Do not capture the
  second ref.
- **`boot.up` is not relocatable to a worktree path** (absolute paths, a shared
  pidfile, a fixed port claimed elsewhere). This surfaces as a boot failure
  inside the worktree. Report it with the boot command's own output; `--base-url`
  is the escape hatch, pointing the base side at an instance started elsewhere.
- **`boot.up` is absent entirely** (the "assume it is already running"
  contract). Skip boot, teardown, and the verify-gone check for that side. The
  base side is then reachable only via `--base-url`; without it, abort with a
  named reason.
- **No resolvable second git state** (a live-app-only target, a bare
  description with no diff). Nothing to compare; report plainly.
- **No root `CHANGE.md`.** A direct invocation aborts with a clear message:
  there is no route or viewport list to work from.
- **Zero pairs differ.** A valid, successful outcome, not a failure. Report "no
  visible change across N routes at M viewports" and skip the upload and the
  Demo offer entirely. Never post an empty Demo section.
- **An orphaned attachment.** An upload that succeeds for some pairs and then
  fails, or a run abandoned before the `gh pr edit`, leaves attachments that
  404 publicly and cannot be deleted. Note the uploaded URLs in the run's report
  so a human at least knows they exist. There is no cleanup path.
