---
name: cf:away
description: Sets the session to away mode, so the agent stops asking questions and takes the recommended or safe default instead, reporting what it assumed. Run cf:active to end it.
---

# CF Away

Trigger: `/cf:away`.

## What it means

Away mode is on for this session. The human has stepped away: run full auto
and non interactive. Do not call `AskUserQuestion` to ask a judgment call.
Instead take the recommended option, or the safe default when there is no
recommended one, continue the work, and report in the run's output what was
skipped and what was assumed.

The `mode_command.rb` `UserPromptSubmit` hook has already persisted the away
flag for this session (`AwayStore`, keyed by session id) by the time this
skill body is read. `away_restate.rb` restates the directive above at the
start of every following turn while away stays on. `away_guard.rb` denies any
`AskUserQuestion` call made while away is on, unless the call carries one of
the floor questions below.

## Floor questions that still fire

A small, fixed set of questions are never silenced, because their default is
destructive or a real secret is at stake and no safe default exists:

- `Remote delete`, before deleting a remote branch that may exist nowhere
  else.
- `Untracked`, before `git clean` removes untracked files that may include an
  unclassified secret.
- `Secret alert`, when a leaked credential is found and its disposition must
  not be auto decided.

Everything else that would normally ask instead applies its stated default
silently and reports the assumption. `cf:plan`'s own interview is a special
case: it refuses to start at all while away is on, since guessing its
judgment calls defeats the point of running it.

## Ending it

Run `/cf:active` to end away mode and resume asking normally.
