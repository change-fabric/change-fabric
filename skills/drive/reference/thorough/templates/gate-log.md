# {{title}} gate log

Writer: the workflow's ledger agent, and nobody else.

Every gate run lands here, oldest first: integration-tip gates from the `gate`
segment and fix-branch gates from `fix` mode `apply`. A fix-branch gate is
recorded too, because that is where a new flake first shows.

## Run <n>: <integration tip | fix branch <branch>> at <sha>

- Worktree: fresh, detached, removed afterwards
- Toolchain: versions as printed

| # | Command | Result | Retried | Time |
| - | ------- | ------ | ------- | ---- |

Verdict: <all green | red: which rows> at <sha>. cf:change gate recorded: <yes | no | not in scope>.
