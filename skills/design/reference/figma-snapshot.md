# Figma variables snapshot

Ruby scripts never call Figma. The agent reads Figma variables through the Figma MCP (`get_variable_defs`) and writes this file; `scripts/design_tokens.rb drift` only diffs it offline against `tokens.css`, which stays the sole canon. Default path: `design/figma-variables.json`, overridable by `change_config.design.figma.variables_snapshot` in CHANGE.md or `--figma-snapshot`.

```json
{ "figma_url": "https://www.figma.com/design/AbCdEf123/Example-App",
  "file_key": "AbCdEf123", "captured_by": "get_variable_defs",
  "variables": [ { "name": "color/primary", "token": "--color-primary", "value": "#1a5fff", "node": "1:2" } ] }
```

| Field | Meaning |
|---|---|
| `figma_url` | The Figma URL the snapshot was read from. |
| `file_key` | File key parsed from the URL (the branch key for a branch URL). |
| `captured_by` | The MCP tool that produced the values. |
| `variables[].name` | The Figma variable name. |
| `variables[].token` | The `tokens.css` custom property it maps to. Omit when unmapped. |
| `variables[].value` | The resolved value, compared after whitespace and case folding. |
| `variables[].node` | Optional node id the variable was read on. |
| `variables[].area` | Optional parity area (route, component, or label); defaults to `name`. |

Drift results: a mapped variable whose value differs, or whose token is absent from `tokens.css`, is a finding whose severity follows that area's parity: `must_match` is a mismatch (exit 1), `intentional` is info with its reason, `unreviewed` (the default) is a warning. An unmapped variable is an info line. A missing or unreadable snapshot is skipped with an info line. A stale snapshot is refreshed by re-running the cf:design Figma read step.
