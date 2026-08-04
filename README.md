# change-fabric

The canonical source for the `cf` toolkit: the system-wide Claude Code skills
and hooks that enforce a house design rubric, gate pushes and merges on a
completed review, and run the dockerized `cf:change` audit lanes. What is
installed on a machine is what is in this repo; `install.rb` makes the live
install match the tree.

The repo also holds the `CHANGE.md` spec that `cf:change` reads, and the site
that publishes it at [changefabric.org](https://changefabric.org).

## What is in here

Everything is a Claude Code skill under the `cf:` namespace, plus the hooks that
surface them. Skills come in two kinds.

**Commands you invoke.** `cf` sets the session's merge mode. `cf:change` runs
the release-gate sweep, four dockerized audit lanes (k6 load, axe-core
accessibility, OWASP ZAP pentest, browserless responsive UX) against a repo's
root `CHANGE.md`, and records a pass or fail for the head commit. `cf:drive`
takes a PR to approved and green. `cf:code-review`, `cf:qa`,
`cf:resolve-threads`, `cf:refactor`, `cf:prune` and `cf:ctx` cover the rest of
the PR lifecycle.

**Rubrics that fire on their own.** Most skills carry an `auto:` block and
surface without being asked: on an edit to a matching file, on a project
fingerprint at session start, or as a review when a turn ends. `cf:ruby` on
Ruby, `cf:react` on components, `cf:ai-slop` on every file you author.

The hooks are the enforcement half. They ask for a merge mode at session start,
deny AI-slop glyphs and host-daemon commands before the tool call runs, and gate
a push or a protected-branch merge on a completed review.

[`skills/README.md`](skills/README.md) is the full inventory and explains the
two kinds properly. Individual skills document themselves in their own
`SKILL.md`.

## Install

With Homebrew:

```sh
brew tap change-fabric/cf
brew install change-fabric
change-fabric-install
```

`brew install` stages the toolkit under Homebrew's prefix and puts one command,
`change-fabric-install`, on your `PATH`. Running it does the wiring. Homebrew
cannot do that step for you: it runs formula install and post-install hooks with
`$HOME` pointed at a temp directory, inside a sandbox that denies writes to your
real home, so nothing a formula does there would survive.

Without Homebrew, clone and run the installer directly:

```sh
git clone https://github.com/change-fabric/change-fabric.git
ruby change-fabric/install.rb
```

Either path symlinks the skills into `~/.claude/skills`, wires the hooks into
`~/.claude/settings.json` (backed up alongside it as `settings.json.bak`), and
mirrors into `~/.pi` and `~/.config/opencode` when present. The installer needs
Ruby 3.0 or newer, takes no input, and is idempotent.

**Re-run the installer after every upgrade.** For a clone that is
`ruby install.rb` after every `git pull`; for Homebrew it is
`change-fabric-install` after every `brew upgrade change-fabric`. The skills are
symlinks into wherever the source tree lives, so an upgrade that moves or
replaces that tree leaves them dangling until you relink. Homebrew's version
directories change on every upgrade, which makes this mandatory rather than
tidy. The [tap's README](https://github.com/change-fabric/homebrew-cf) covers
the Homebrew lifecycle, including uninstalling, in full.

## Verify the install

The installer prints the hook directory, every skill it linked, and the settings
file it wrote. Two checks confirm it from the outside:

```sh
ls -l ~/.claude/skills | grep -c 'cf:'           # skill symlinks, expect dozens
grep -c '.claude/cf/bin' ~/.claude/settings.json  # wired hooks, expect > 0
```

Then start a new `claude` session in any git repo. Before it answers anything,
cf's SessionStart hook makes it ask you to pick a merge mode. That prompt is the
end-to-end proof: the hooks are wired and firing. Hooks are read once at session
start, so a session that was already open when you installed will not show it.

## Troubleshooting

**Hooks error or stop firing after `brew upgrade ruby`.** The hook commands in
`settings.json` name a Ruby interpreter by path, and a Ruby upgrade moves it.
Re-run the installer.

**A `cf:` skill is not found, or the links look broken.** The symlinks point at
a source tree that moved, was deleted, or (on Homebrew) was replaced by an
upgrade. List the broken ones with

```sh
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print
```

and re-run the installer.

**A new skill from a release never appeared.** Same cause: the upgrade staged
it, nothing linked it. Re-run the installer.

**You already have a hand-rolled `~/.claude`.** The installer only touches what
it owns. It removes and rewrites hook entries whose command names
`~/.claude/cf/bin` (or the pre-rename `~/.claude/pst/bin`) and leaves every other
hook and every other settings key alone, after backing the file up. In
`~/.claude/skills` it prunes only symlinks pointing into this repo's `skills/`,
leaving real directories and links into other repos untouched.

**`~/.claude/settings.json.bak` is not a pre-cf settings file.** It is rewritten
on every install run, so it holds the state from just before the most recent
one, which already had cf hooks in it.

## Contributing

Merging to `main` stages work; nothing is released until the matching tag is
pushed. Three tracks (the toolkit, the spec, and the site) each release on their
own tag. See [RELEASING.md](RELEASING.md) for the full model and the runbook,
and [CLAUDE.md](CLAUDE.md) for the rules this repo holds itself to.

### From a merged PR to somebody's machine

`RELEASING.md` covers cutting a release. This is what happens after, for the
toolkit track, and how much of it is automatic.

1. Your PR merges to `main`. Nothing is released. No user sees the change.
2. A maintainer pushes a `skills/vX.Y.Z` tag by hand. Workflows never push tags.
3. The tag fires two independent workflows. `release-skills.yml` publishes a
   GitHub Release covering the commits since the previous toolkit tag.
   `bump-tap-formula.yml` runs `brew bump-formula-pr` against
   [`change-fabric/homebrew-cf`](https://github.com/change-fabric/homebrew-cf)
   and opens a PR there bumping the formula's `url`, `version` and `sha256` to
   the new tag's release tarball. They are separate on purpose, so a tap failure
   never blocks the release.
4. **A human reviews and merges that tap PR.** Nothing is automatic here.
   Until it merges, `brew upgrade change-fabric` still resolves to the previous
   release.
5. A user runs `brew upgrade change-fabric`, then `change-fabric-install`. Both
   steps are theirs to take; Homebrew's sandbox rules out doing the second one
   for them.

So a change reaches a machine only after a merge, a tag, a tap-PR merge, and a
user upgrading. A clone install skips steps 2 through 4 entirely and picks the
change up on the next `git pull` plus `ruby install.rb`.

## Docs

The spec and the platform docs live at
[changefabric.org](https://changefabric.org).
