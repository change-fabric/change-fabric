# Distributing change-fabric via Homebrew: a design plan

Status: draft, planning only. Nothing in here is implemented. This document is the deliverable.

## 0. Context and constraints this plan is grounded in

Before recommending anything, the facts that actually constrain the design, read from the repo:

- **What the toolkit is.** Per `CLAUDE.md`: "Canonical source for system-wide Claude Code skills and hooks. What's installed is what's here." It is a tree of Ruby hook scripts (`scripts/*.rb`), skill directories (`skills/*/SKILL.md` plus references), and one orchestrating installer (`install.rb`). There is no compiled artifact and no `bin/` entrypoint a user runs day to day. The "product" is a set of side effects under `~/.claude/`.
- **What `install.rb` actually does** (read in full). Its `Installer#install` runs, in order: `place_hooks` (wipes `~/.claude/pst/bin`, then copies every `scripts/*.rb` in and `chmod 0755`), `pin_expected_home` (writes `~/.claude/pst/bin/.expected-home` with `Dir.home`), `link_skills` (symlinks `~/.claude/skills/<pst:name>` at each `skills/*` source dir inside the repo checkout, and prunes stale links it owns), `link_pi_extension` (symlinks the Pi hook extension), `mirror_to_pi` (prunes legacy Pi skill copies, appends `~/.claude/skills` to `~/.pi/agent/settings.json`'s `skills` array), `mirror_to_opencode` (copies a JSONC-safe, renamed `pst-foo` mirror of each skill into `~/.config/opencode/skills` and registers the path in `~/.config/opencode/opencode.jsonc`), and `wire_settings` (rewrites `~/.claude/settings.json` `hooks` for six events, keeping a `.bak`).
- **The critical asymmetry.** Hooks are copied; skills are symlinked into the repo checkout. `settings.json` hook commands are absolute paths into `~/.claude/pst/bin` (stable, home-relative). But `~/.claude/skills/*` symlinks point at `<repo>/skills/*`. The repo checkout must persist at a stable path for the install to keep working. This single fact dominates the Homebrew fit question.
- **Idempotency contract.** `CLAUDE.md`: "`install.rb` makes the live install match this repo. Re-run after pulling." The code backs this up: `place_hooks` does `rm_rf` then recopy; `link_skills`/`prune_stale_links` reconcile the symlink set to exactly the current sources; `SettingsFile#wire` clears previously-managed hooks (scoped by `managed_dir`) before re-adding. Re-running is safe and convergent by construction. This holds for any re-run, including one triggered by a `brew upgrade`.
- **Runtime dependencies.** Ruby (CI pins 3.4) plus gems `rake`, `csv`, `rubocop-rails-omakase` (`Gemfile`); Node is only a dev toolchain (`package.json` devDependencies: `@earendil-works/pi-coding-agent`, `typescript`, `@types/node`) used for typecheck and the Pi extension build, not required at skill-runtime. Docker is a hard runtime dependency for the `pst:change` lanes (k6/a11y/zap/browserless all run dockerized), and `docker_doctrine_guard.rb` actively polices host daemons.
- **Versioning, two independent axes.** `VERSION` (currently `0.29.0`) versions the whole toolkit; tags are `skills/vX.Y.Z` (renamed this session from bare `vX.Y.Z`). `ChangeSchema::VERSION` (currently `0.3.1`, in `scripts/change_schema.rb`) versions the CHANGE.md frontmatter schema independently; tags are `change-schema/vX.Y.Z`. The schema spec (`skills/change/reference/CHANGE-frontmatter-spec.md`, "Versioning and changelog") defines a `-alpha.N`/`-beta.N` SemVer 2.0.0 prerelease convention, currently used only for the schema, not for `skills/vX.Y.Z`.
- **Release cadence.** `git tag` shows around 35 `skills/v*` tags, all dated the same working session, several per hour. This is a fast, personal-adjacent, high-churn project, not a slow-cadence library.
- **Existing CI/CD.** `ci.yml` (push to `main` plus PRs): rubocop, `tsc --noEmit`, `rake test`. `tag-on-version.yml` (push to `main`, path-filtered to `VERSION`): tags `skills/v${VERSION}` if absent and pushes it, using the default `GITHUB_TOKEN` with `contents: write`. `version-reminder.yml` (PRs touching `scripts/**`, `skills/**`, `install.rb`): a warning-only annotation when `VERSION` isn't bumped. Note `ci.yml` and `tag-on-version.yml` both trigger on the same push-to-`main` event and run independently and concurrently; there is no dependency gate making the tag wait for CI.
- **The docs site is a separate channel.** `site/` is a Vite/React SPA deployed to `changefabric.org` via Terraform/S3/CloudFront. It is documentation, not the toolkit. This plan does not touch it, except that the formula's `homepage` should point at `https://changefabric.org` and its `desc` should match the site's framing.

## 1. What a `brew install` should actually do

Recommendation: a formula that vendors the repo tree into the Cellar as unmanaged files, then shells out to the existing `install.rb` from a `post_install` step. Do not try to make Homebrew "own" the `~/.claude/` side effects.

Homebrew's native model is: unpack sources into `#{prefix}` (a versioned Cellar dir), then symlink a curated subset into `#{HOMEBREW_PREFIX}/opt/<formula>` and `bin/`. That model assumes the payload is self-contained and relocatable, and that "install" means "make these files reachable on PATH." This toolkit violates both assumptions:

- Its entire job is to mutate files outside the prefix (`~/.claude/`, `~/.pi/`, `~/.config/opencode/`). Homebrew has no concept of those and must not try to manage them.
- `install.rb` symlinks `~/.claude/skills/*` back at the source tree. So the source tree cannot be a throwaway build dir; it must remain at a stable readable path for the lifetime of the install.

The clean way to satisfy both: let the formula's `install` method copy the whole repo checkout into the Cellar (`libexec` is the idiomatic home for a "private support tree not meant for PATH"), and then run `install.rb` against that libexec copy so the `~/.claude/skills` symlinks point at `#{libexec}/skills/*`.

Concretely, the `install` block does essentially:

```ruby
def install
  libexec.install Dir["*"]           # vendor the whole tree (scripts, skills, install.rb, Gemfile, ...)
  # do NOT put anything in bin/; there is no user-facing CLI
end

def post_install
  system Formula["ruby"].opt_bin/"ruby", libexec/"install.rb"
end
```

Why `post_install` and not `install`: `install` runs in a sandbox that forbids writing outside the prefix, and `~/.claude/` is outside the prefix. `post_install` runs unsandboxed against the user's real home, which is exactly what `install.rb` needs (it reads `Dir.home` and writes `~/.claude/settings.json` etc.). This is the supported Homebrew seam for "I need to touch the user's environment after files land."

Why shell out to `install.rb` rather than reimplement it in the formula: `install.rb` is the single source of truth for the hook wiring, the six-event hooks map, the skill-name resolution, the Pi/OpenCode mirrors, the `.expected-home` pin, and the `settings.json` `.bak` discipline. Reimplementing any of that in Ruby inside a formula would immediately drift and duplicate the very logic `CLAUDE.md` calls canonical. The formula stays a thin delivery wrapper; `install.rb` stays the installer.

Consequences that fall out of this and must be handled (see section 5):

- Because skills symlink into `#{libexec}`, and each `brew upgrade` installs into a new Cellar version dir, the old symlinks would dangle after an upgrade. Therefore `post_install` must re-run `install.rb` on every upgrade, not just first install. Homebrew runs `post_install` on upgrade as well as install, so `link_skills`' reconcile-to-current behavior re-points the symlinks at the new `#{libexec}` automatically. This is exactly the idempotent "make the live install match this repo" contract, now driven by Homebrew instead of a human `git pull && ruby install.rb`.
- Ruby: depend on Homebrew's `ruby` (`depends_on "ruby"`) rather than assuming system Ruby, so the shebang-resolution in `install.rb`'s ruby interpreter handling (which pins the running interpreter into hook shebangs) resolves to a stable, kept-updated interpreter. Do not vendor gems into the formula; the runtime gem surface (`rake`, `csv`, `rubocop`) is only needed for development/CI and the `pst:change` Rakefile paths, not for the hooks themselves, which are plain stdlib Ruby. If a specific skill turns out to need a gem at runtime, express it via a `bundle install --path` inside `libexec` from `post_install`, not via core-managed gem formulae.
- Docker is not expressed as a formula dependency. It is a runtime requirement of one skill (`pst:change`) invoked on demand, often Docker Desktop (a cask/app, not a formula), and forcing `depends_on "docker"` would be both wrong (wrong artifact) and hostile (pulls a heavy dependency for users who never run the change lanes). Document it as a runtime prerequisite in the `caveats` string instead.

## 2. Formula location: custom tap, not homebrew-core

Recommendation: a custom tap, `pstaylor-patrick/homebrew-pst` (installed as `brew tap pstaylor-patrick/pst` then `brew install pstaylor-patrick/pst/change-fabric`). Do not attempt homebrew-core.

The case, on homebrew-core's actual acceptance bars:

- Notability. Core wants broadly-used, independently-notable software. This is a personal-adjacent toolkit whose audience is "people running this specific Claude Code hook system." It would not clear the notability bar, and pretending otherwise wastes reviewer time.
- No unusual external runtime requirements. Core is hostile to formulae that only function alongside a heavy out-of-band runtime. `pst:change` requires Docker at runtime; expressing that in core would demand awkward conditionals or a caveats-only hand-wave that core reviewers dislike.
- It writes all over the user's home directory. A core formula whose `post_install` mutates `~/.claude/settings.json`, `~/.pi/`, and `~/.config/opencode/` is exactly the kind of "installs things outside the prefix" behavior core rejects. Core wants installs confined to the Cellar; this toolkit's whole purpose is the opposite.
- Stable-releases-only and no prerelease channels. Core takes tagged stable releases only. This project's cadence (dozens of tags in a day, active prerelease conventions in flight) is a poor match for core's slow, reviewed formula-bump process.
- Bundled ecosystems. Core dislikes formulae that awkwardly straddle Ruby, Node, and Docker. This one does.

A custom tap removes every one of those frictions: it is just a Git repo (`homebrew-pst`) with a `Formula/change-fabric.rb`. No notability bar, no reviewer, no core-style objection to `post_install` home mutation, and the maintainer (who already merges every PR manually, per `CLAUDE.md`) keeps the same self-owned control over releases. It also composes cleanly with the existing self-hosted release automation (section 4) because the tap is a repo this project's own CI can push to.

Name the tap `homebrew-pst` (so the namespace is `pst`, matching the `pst:` skill namespace and the `pst` merge-mode shim identity) rather than `homebrew-change-fabric`, because the tap is the natural home for the whole `pst` toolkit and any future sibling formulae, not just this one repo's artifact. The formula itself is named `change-fabric` to match the repo.

## 3. Version-to-formula mapping and prerelease handling

Recommendation: one stable formula tracking `skills/vX.Y.Z` tags, bumped automatically on each tag. Add a `head` block pointing at `main` for bleeding-edge users. Do not build any formula-level prerelease channel.

### Stable mapping

The formula's `url`/`sha256` point at the GitHub-generated tarball for a `skills/vX.Y.Z` tag:

```ruby
url "https://github.com/pstaylor-patrick/change-fabric/archive/refs/tags/skills/v0.29.0.tar.gz"
sha256 "..."
```

Note the tag contains a slash (`skills/v0.29.0`); GitHub's archive URL accepts it as a path segment and the resulting tarball's top-level dir is `change-fabric-skills-v0.29.0`. The formula's `install` uses `Dir["*"]` off the extracted root, so the odd dirname is irrelevant. This is worth calling out because the slash-in-tag is unusual and a hand-written url is easy to get wrong; the automation in section 4 should construct it mechanically.

Every `skills/vX.Y.Z` tag gets a formula bump, automatically (section 4). Given the cadence (multiple tags per day), hand-bumping is a non-starter and would guarantee the formula lags reality. The bump is cheap and mechanical (recompute one sha256, rewrite two lines), so automating all of them, including patch releases, costs nothing and keeps `brew install` honest. There is no value in a curated subset.

### `--HEAD` for bleeding edge

Add:

```ruby
head "https://github.com/pstaylor-patrick/change-fabric.git", branch: "main"
```

so `brew install --HEAD pstaylor-patrick/pst/change-fabric` installs from the `main` tip for anyone who wants unreleased work between tags. This is the modern, supported Homebrew mechanism for "I want the development version," it requires no extra automation (Homebrew clones `main` at install time), and it exactly matches this project's reality that `main` is always the integrated truth and `VERSION` bumps trail behind merged work. `--HEAD` is opt-in, so it never affects normal `brew install` users.

### Prerelease tracks: none at the formula level

The schema's `-alpha.N`/`-beta.N` convention exists, per the spec, to let a schema consumer pin a floated CHANGE.md spec version on a branch before it stabilizes. That is a concern of the `change-schema/v*` tag axis and the `/spec` site index, not of how the toolkit binary is delivered. The plan's position:

- The toolkit itself should not, yet, adopt `-alpha.N` on its `skills/v*` tags. There is no evidence of demand: the tag history is all clean `X.Y.Z` (plus ordinary patch releases like `v0.22.1`, `v0.25.1`, `v0.27.1`/`.2`), never a prerelease. Adding a toolkit prerelease convention now would be speculative infrastructure (see section 6). If a genuine need appears (wanting to dogfood an unreleased hook change across devices without merging to `main`), `--HEAD` already covers "I want main," and a one-off `skills/v0.30.0-alpha.1` tag would still produce a valid archive URL the same way, so the door is open without building anything.
- Even if the toolkit adopted the suffix, the stable formula must never track it. A `brew install` with no flags must always land a stable release. Homebrew's supported ways to offer a parallel prerelease track are heavyweight: a separate `change-fabric@next`-style versioned formula, or the long-deprecated pre-1.5 `devel` block (gone, do not use). Standing up a `@next` formula and wiring its own automation is exactly the speculative infra section 6 says to punt. The `head` block already serves every "I want it before it's stable" user at zero cost.

So the concrete mechanism is: stable formula tracks tagged stable `skills/v*` releases; `--HEAD` serves bleeding-edge; no formula-level prerelease channel. Defended against the cadence: with several releases a day, a prerelease channel would churn faster than anyone could consume it and would fragment an already-tiny user base; `--HEAD` gives the same "latest unreleased" value with one code path and no extra tags.

## 4. CI/CD: getting a tagged release into the tap formula

Recommendation: a new, separate workflow in the toolkit repo, triggered on `skills/v*` tag pushes, that runs `brew bump-formula-pr` against the tap using a scoped PAT (or GitHub App token). Do not overload `tag-on-version.yml`, and do not hand-roll the sha256/git-push.

### Trigger and separation of concerns

`tag-on-version.yml` already does one job well: on a `VERSION` change pushed to `main`, it creates and pushes `skills/v${VERSION}`. Keep it single-purpose. Add a new workflow, `bump-tap-formula.yml`, triggered on the tag itself:

```yaml
on:
  push:
    tags: ["skills/v*"]
```

This is cleaner than extending `tag-on-version.yml` for three reasons: it decouples "make the tag" from "publish the formula," so a formula-publish failure never blocks tagging and can be re-run independently; it triggers off the durable artifact (the tag) rather than racing inside the same job that just created it; and the tag trigger also fires for any manually-pushed tag (a hotfix tag, or a future prerelease tag), so the formula pipeline isn't coupled to the `VERSION`-file path filter.

### Mechanism: `brew bump-formula-pr`, not hand-rolled

Homebrew ships `brew bump-formula-pr` precisely for this: given a formula and a new `--url` (or `--tag`), it fetches the tarball, computes the sha256 itself, edits the formula, and opens a PR against the tap. Use it. Hand-rolling `curl | shasum` plus `sed` plus `git push` reinvents exactly this tool and gets the slash-in-tag archive URL, the tarball resolution, and the audit-trail PR wrong more easily. The job is roughly:

```yaml
jobs:
  bump:
    runs-on: macos-latest
    steps:
      - name: Compute version from tag
        run: echo "VERSION=${GITHUB_REF_NAME#skills/v}" >> "$GITHUB_ENV"
      - name: Bump the tap formula
        env:
          HOMEBREW_GITHUB_API_TOKEN: ${{ secrets.TAP_BUMP_TOKEN }}
        run: |
          brew tap pstaylor-patrick/pst
          brew bump-formula-pr \
            --no-browse --no-audit \
            --url "https://github.com/pstaylor-patrick/change-fabric/archive/refs/tags/skills/v${VERSION}.tar.gz" \
            pstaylor-patrick/pst/change-fabric
```

Given the maintainer merges every PR manually (`CLAUDE.md`), `bump-formula-pr` opening a PR (not pushing to the tap's default branch) is the right default: it keeps the human-merge discipline on the tap too. If the maintainer later wants the tap fully hands-off, switch to a direct commit; but the PR default matches the stated workflow and is the safer first cut.

### Auth: this is the one genuinely new secret

The default `GITHUB_TOKEN` in the toolkit repo's Actions is scoped to `pstaylor-patrick/change-fabric` only. Writing to a different repo (`pstaylor-patrick/homebrew-pst`) requires a cross-repo credential: either a fine-grained PAT with `contents: write` plus `pull_requests: write` on the tap repo, stored as `secrets.TAP_BUMP_TOKEN`, or a GitHub App installed on both repos with a token minted per-run. For a single-maintainer setup, a fine-grained PAT scoped to only the tap repo is the pragmatic first cut (least moving parts); a GitHub App is the upgrade if the PAT's expiry/rotation becomes annoying or more repos join. `brew bump-formula-pr` reads the token from `HOMEBREW_GITHUB_API_TOKEN`. Note `tag-on-version.yml` needs no such secret because it writes tags in its own repo with the default token; the tap-bump is the first automation that crosses a repo boundary, and that boundary is the entire reason a PAT or App is unavoidable.

### Should CI gate the release/bump?

Checked against the actual workflow files: `ci.yml` and `tag-on-version.yml` both trigger on push to `main` with no ordering between them, so it is not true "by construction" that CI is green before the tag is cut; they race. In practice a bad commit rarely reaches `main` because PRs run `ci.yml` and the maintainer merges manually, but the tag workflow does not verify green.

For the bump step this mostly doesn't matter, because the bump triggers off the tag (which only exists because `VERSION` changed on `main`, which only happens post-merge), and the formula bump changes no toolkit code, only a tap url/sha256. The real safety belt lives on the tap side: the tap repo should have its own minimal CI running `brew audit --strict --online change-fabric` and `brew install --build-from-source change-fabric` on the PR that `bump-formula-pr` opens, so a broken formula (bad sha, install.rb failing under the sandbox seam) is caught before the maintainer merges the tap PR. That is a better gate than trying to make the toolkit's `ci.yml` a prerequisite of tagging, and it keeps each repo's CI concerns local to that repo.

If desired, harden `bump-tap-formula.yml` with a cheap guard that re-checks the tagged commit is an ancestor of `origin/main` before bumping (rejects a stray tag pushed off a feature branch). That is one `git merge-base --is-ancestor` line, not a heavier workflow dependency, and it is optional for a first cut.

### `version-reminder.yml`

Leave it as-is. Its job (warn on a PR that changes shipped code without a `VERSION` bump) is upstream of releases and unrelated to formula publishing. Giving it any release role would blur a pre-merge advisory into a release gate. No change.

## 5. What the formula automates vs. what stays manual, and up/downgrade semantics

### Automated at install and every upgrade

Run `install.rb` from `post_install` on both first install and every `brew upgrade`. Justification: it is idempotent by design (`place_hooks` wipes-and-recopies; `link_skills` plus `prune_stale_links` reconcile to the current source set; `SettingsFile#wire` clears its own managed hooks before re-adding), and it must re-run on upgrade anyway to re-point the `~/.claude/skills/*` symlinks at the new Cellar `libexec` (see section 1). So the same call satisfies both "wire a fresh install" and "heal the symlinks after the Cellar dir moved." This includes the Pi and OpenCode mirrors and the `.expected-home` pin, all of which `install.rb` already does in one pass; there is no reason to split them out.

### Stays a manual, explicit user action

Everything that is session behavior, not install-time state, stays out of the formula:

- Merge mode (the `pst` skill: local-only, merge-ready, admin-bypass, yolo) is per-session and set inside a Claude Code session, never at install time. The formula must not presume a mode.
- The change-merge override (`change_override.rb`) explicitly refuses without a real TTY and must be run by a human from a real terminal; a formula's `post_install` neither can nor should invoke it.
- `pst:change` runs, `pst:drive`, review gates, and ctx captures are all invoked on demand during work, never at install.

The formula's `caveats` string should state, in plain text (glyph-clean, per `CLAUDE.md`): that hooks and skills are now wired into `~/.claude/`; that a backup of the prior `settings.json` is at `~/.claude/settings.json.bak`; that `pst:change` needs Docker running; and that merge mode is chosen per session, not here.

### `brew upgrade` idempotency: confirmed, with one sharp edge

The `CLAUDE.md` claim that `install.rb` makes the live install match the repo is borne out by the code for a re-run, and a `brew upgrade`-driven re-run is not materially different from a manual `ruby install.rb` re-run, with one nuance the plan flags: on upgrade the source path changes (new Cellar version dir). `link_skills` handles this correctly because it computes links from the current skill sources (the new `libexec`), and `prune_stale_links` removes any managed link not in the new keep-set. In practice `ln_sf` in the same pass overwrites each `~/.claude/skills/<name>` link in place (same link name, new target), so the live links are corrected regardless; the only residue would be a link whose skill was renamed or deleted across the upgrade, pointing into a vanished Cellar dir. That is a pre-existing property of `install.rb`, not something Homebrew introduces, and it is cosmetic (a dangling link Claude Code ignores). Worth a note in the tap's install-test, not a blocker.

### `brew uninstall`: needs a real teardown, and `install.rb` has no uninstall path

`brew uninstall` removes the Cellar `libexec`. That leaves behind, unmanaged by Homebrew: the copied hooks in `~/.claude/pst/bin`, the `~/.claude/settings.json` hook wiring that references them, the `~/.claude/skills/*` symlinks (now dangling into the removed Cellar dir), the Pi/OpenCode registrations, and `.expected-home`. `install.rb` has no reverse operation. Options:

- First cut, recommended: document, don't automate the reversal. Homebrew's `caveats` text can tell the user how to fully unwind: restore `~/.claude/settings.json` from the `.bak` the installer kept, and remove `~/.claude/pst/bin` and the `~/.claude/skills/pst:*` links. This matches the repo's demonstrated preference for not building speculative infra, and it is honest: a clean automated uninstall needs an `install.rb --uninstall` that doesn't exist yet.
- Later, if warranted: add an `uninstall.rb` (or `install.rb --uninstall`) to the repo that reverses the wiring using the same backup and managed-dir scoping the installer already relies on, and call it from the formula's `uninstall` phase. This is a change to the toolkit, not the formula, and should land there first with its own tests. Flag it as a follow-up, not part of the first Homebrew cut.

The `settings.json` backup is a single-slot backup (overwritten on each install), so it reflects the state just before the last install, not the pristine pre-toolkit state. An uninstall that restores it is good enough (it removes the managed hooks block via the next-best snapshot), but the caveats text should be honest that the cleanest reset is manual. Do not oversell an automated uninstall the installer can't yet truly deliver.

## 6. Explicitly punted for a first cut

Matching this repo's demonstrated preference for not building infrastructure ahead of demand, the first Homebrew cut deliberately does not include:

- A homebrew-core submission. Custom tap only (section 2). Revisit only if the toolkit ever acquires a broad, independent user base, which nothing today suggests.
- Any formula-level prerelease/`@next` channel and any adoption of `-alpha.N` on `skills/v*` tags (section 3). `--HEAD` covers bleeding-edge at zero cost; build a prerelease track only when a concrete cross-device-dogfooding need appears that `--HEAD` genuinely can't serve.
- An automated, fully-reversing `brew uninstall`. Ship caveats-driven manual teardown first; add `install.rb --uninstall` to the toolkit as a later, separately-tested change (section 5).
- A GitHub App for tap auth. Start with a fine-grained PAT scoped to the tap repo; graduate to an App only if PAT rotation becomes a real burden (section 4).
- Direct-commit tap bumps. Keep `bump-formula-pr`'s open-a-PR default to preserve the maintainer's manual-merge discipline; switch to auto-commit only if the PR step proves to be pure friction (section 4).
- Bottling (prebuilt binary bottles). There is nothing to compile; the payload is scripts. `brew install` from source is instant. No bottle infrastructure. Revisit never, unless the payload grows a compiled component.
- Bundling Ruby gems or Node into the formula. The hooks are stdlib Ruby; depend on Homebrew `ruby` and stop there (section 1). Add a `libexec` `bundle install` only if a specific skill is shown to need a runtime gem.
- A Linuxbrew story. The toolkit targets macOS Claude Code setups (Docker Desktop, `~/.claude`); don't invest in verifying or patching for Homebrew-on-Linux until someone asks.

## Summary of the concrete recommendation

1. Custom tap `pstaylor-patrick/homebrew-pst`, formula `change-fabric`.
2. Formula vendors the whole tree into `libexec`, no `bin/`, `depends_on "ruby"`, and runs `install.rb` from `post_install` on install and every upgrade (the only way the `~/.claude/skills` symlinks stay valid across Cellar moves).
3. Stable `url`/`sha256` track `skills/vX.Y.Z` tags; a `head` block pointing at `main` serves bleeding-edge; no prerelease channel.
4. A new `bump-tap-formula.yml` in the toolkit repo, triggered on `skills/v*` tag pushes, runs `brew bump-formula-pr` against the tap using a tap-scoped fine-grained PAT; `tag-on-version.yml`, `ci.yml`, and `version-reminder.yml` are left unchanged, and formula-correctness is gated by the tap repo's own audit/install-test CI on the bump PR.
5. Automate wiring (`install.rb`) on install and upgrade; keep session behavior (merge mode, change override, change runs) manual; ship manual, caveats-documented uninstall teardown for now.
6. Punt homebrew-core, prerelease channels, an automated uninstall, a GitHub App, bottling, and gem/Node bundling until real demand appears.
