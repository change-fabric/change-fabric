---
name: cf:active
description: Ends away mode for this session, so the agent asks questions normally again instead of taking silent defaults.
---

# CF Active

Trigger: `/cf:active`.

Running this command turns away mode off for this session. `scripts/mode_command.rb`
has already written the session's away store to `active` before this skill body is
read, so there is nothing further to persist here.

With away mode off, the agent goes back to asking normally: every `AskUserQuestion`
call proceeds as usual, with no floor allowlist involved and no silent default
substituted in place of a real question. This reverses the behavior `/cf:away`
turned on, where the agent suppressed ordinary questions and took the recommended
or safe default instead.

State this back to the user in one line: away mode is off, questions resume as
normal. If away mode was already off when this command ran, say so; there is
nothing to change.

Run `/cf:away` again at any point to step away and return to non-interactive,
full-auto behavior.
