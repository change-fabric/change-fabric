# change-fabric

The canonical source for the `cf` toolkit: the system-wide Claude Code skills
and hooks that enforce a house design rubric, gate pushes and merges on a
completed review, and run the dockerized `cf:change` audit lanes. What is
installed on a machine is what is in this repo; `install.rb` makes the live
install match the tree.

The repo also holds the `CHANGE.md` spec that `cf:change` reads, and the site
that publishes it at [changefabric.org](https://changefabric.org).

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
Ruby 3.0 or newer, takes no input, and is idempotent. Run it again after every
upgrade or `git pull` to pick up new or renamed skills and hooks.

## Contributing

Merging to `main` stages work; nothing is released until the matching tag is
pushed. Three tracks (the toolkit, the spec, and the site) each release on their
own tag. See [RELEASING.md](RELEASING.md) for the full model and the runbook,
and [CLAUDE.md](CLAUDE.md) for the rules this repo holds itself to.

## Docs

The spec and the platform docs live at
[changefabric.org](https://changefabric.org).
