# Host compatibility

CF generates skills for five hosts and shares mode decisions through a native
adapter. The same workflow name does not imply the same command parser, hooks,
permissions, or surface support.

| Host / surface | Invoke roast | Native adapter | Current verification |
|---|---|---|---|
| Claude CLI | `/cf:roast` | Native hooks; existing rubric/review hooks retained | Deterministic adapter tests |
| Codex CLI | `$cf-roast` or `/skills` | Native `hooks.json`; host trust/config required | Adapter tests; 0.166.0 live local-only smoke |
| Copilot CLI | Select/request `cf-roast` in its skill interface | User-level hook file | Deterministic adapter tests; no live host test |
| OpenCode CLI | Select/request `cf-roast` in its skill interface | Plugin with system/compaction context | Actual plugin handlers against Ruby; no live host test |
| Pi CLI | `/skill:cf-roast` | Extension; `/cf MODE` changes mode directly | Actual extension handlers against Ruby; no live host test |
| Desktop, cloud, editor, RPC variants | Consult that surface's skill interface | Not assumed from CLI support | Instructions only until independently verified |

The executable registry is `config/host_capabilities.json`. Reference versions
are observed binaries, not live evidence. Unknown versions are explicitly
unverified. The Codex live test covers explicit `$cf-local-only` activation,
model acknowledgement, and hook persistence; it does not establish all skill
behavior or slash aliases. Pi's review follow-up is best effort. OpenCode's
experimental context APIs are version-sensitive. Shell guards are advisory and
do not cover arbitrary indirect commands, hosted tools, or every external API.

## Diagnose an installation

```
cf doctor --host codex
cf doctor --host claude --json
```

If `cf` is not on PATH or belongs to another tool, use
`ruby scripts/cf_cli.rb doctor --host codex` from this checkout. Doctor reads
configuration and probes `--version` with a time limit. It never runs a model.
It reports file presence separately from actual host discovery, and configured
hooks separately from active/trusted hooks. Codex's `/hooks` is the authority
for its trust review. Hook sandbox access also remains host-controlled.

For the screenshot failure `Unrecognized command '/cf:roast'`, enter
`$cf-roast` or select it in `/skills`. That rejection occurs in Codex's command
parser; a lifecycle hook cannot rescue a rejected input. CF does not install
deprecated prompt aliases or claim Claude's namespace works in Codex.

## Refresh, migrate, and remove

Run `ruby install.rb` after updating the checkout. Generated mode contracts and
Markdown command references refresh for all hosts; native hook entries update
without replacing unrelated hooks. Pi's old CF-added Claude skill search path
is removed in favor of its own generated copies. Exact exclusions prevent Pi from
also loading CF-owned Codex copies through shared discovery; uninstall removes
those exclusions. Unmarked skill collisions
are preserved. Claude's old merge-mode files remain a read-only fallback until
neutral state exists. Old state and other subsystem stores are retained.

Mode state is keyed by host, canonical project root, and stable native session
ID. Subdirectories share the repository identity; worktrees are independent.
Children inherit explicitly and may override without changing parents. Separate
sessionless Pi instances do not share cwd-derived state. Resume requires the
host to supply the same native session identity.

`cf uninstall` prints a dry-run file plan. `cf uninstall --apply` removes CF's
native and legacy hook entries and only unchanged files/symlinks recorded in
the installation manifest. Modified files, user-owned collisions, configuration
backups, state, and the manifest itself remain. It never recursively deletes a
directory. Files in externally redirected directories are intentionally omitted
from the home-scoped removal manifest; clean those up explicitly after review.
Search-path settings may remain where the shared directory also holds user
skills. A foreign `~/.local/bin/cf` is never replaced or removed.

## Repeat behavioral checks

```
bundle exec ruby -Itest test/agent_contract_test.rb
npm run test:adapters
bundle exec ruby test/support/agent_smoke.rb --host codex --output /tmp/cf-smoke.json
```

The first two are deterministic contracts. The third makes an opt-in model
request in an isolated temporary HOME and records its precise scope. Missing
binaries or unsupported isolated authentication produce `not-run`, not success.
A fixture pass is never recorded as a live model pass.
