# change-fabric

Canonical source for the cf toolkit (skills and hooks), the `CHANGE.md` spec,
and the site. What is installed is what is here.

Read first:

1. `ARCHITECTURE.md`: what lives where, the hooks, host portability, and the
   release model.
2. `PRINCIPLES.md`: every rule this repo enforces, each with its enforcer.
3. `RELEASING.md`: the release runbook and team setup.

## Must know

1. `install.rb` makes the live install match this checkout. Re-run it after
   pulling.
2. Squash merge. In admin-bypass mode the agent squash-merges a PR at the
   ready bar in `CHANGE.md` (rebased, CI green, CLEAN, 0 open threads, cf:change
   passed at head). Carve-out PRs and escalation triggers go to the maintainer.
   For `change_approve`, `change_override`, carve-outs and releases, only
   Patrick's phone approves: the agent starts the request (`--remote`, or
   `approval_console.rb request`), posts the console link, and records the
   receipt (`approval_console.rb record <id>` resumes). Until the release
   type lands, tag and Homebrew steps go in a script under
   `~/.claude/cf/manual/`, not a question.
3. Merging stages; a human-pushed tag releases. A toolkit PR bumps nothing (the
   `skills/v*` tag is the version). A spec or site change bumps
   `ChangeSchema::VERSION` or `site/VERSION` in the same PR. The browserless-cf
   image (`docker/browserless-cf`) is its own track: no version file, a human
   pushes `image/vX.Y.Z`, and a follow-up PR pins the published digest.
4. Docs are the living set only. A new markdown file fails `rake test` unless
   `scripts/docs_check.rb` allows it; put lasting lessons in `PRINCIPLES.md`.
5. Run `bundle exec rubocop` and `bundle exec rake test` before pushing.

## Gates and escape hatches

1. Push or PR denied by the review gate: run the review it returns, then
   `ruby ~/.claude/cf/bin/review_ack.rb <session_id>`.
2. Host daemon denied: `CF_ALLOW_HOSTDAEMON=1`.
3. Sensitive term denied: `CF_ALLOW_SENSITIVE_TERM=1`.
4. Protected merge or tag denied: `CF_ALLOW_UNGATED_MERGE=1`, exported before
   the session started, or a human runs
   `ruby ~/.claude/cf/bin/change_override.rb <sha> --reason '<why>'` from a real
   terminal. An agent cannot run it.
