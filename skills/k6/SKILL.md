---
name: pst:k6
description: Runs just the k6 load/burst lane of the change-fabric platform against a project's config. Boots the target app, runs the digest-pinned grafana/k6 image as an ephemeral container, grades each threshold, and writes a CSV and Markdown report (with the scenario-driven load narrative) to the Desktop. Invocable directly for a standalone load check.
---

# PST k6

The standalone k6 load/burst lane of the change-fabric platform. Runs only the
load audit; for the full four-lane release sweep use `pst:change`.

Trigger: `/pst:k6 [<target>]`.

Question: does the target sustain its expected peak load with margin, and how
does it behave when deliberately pushed past its ceiling?

## Run it

From the target repo root (a repo carrying `CHANGE.md`):

```
ruby ~/.claude/pst/bin/change_run.rb k6
```

This boots the app per `boot`, waits for its health signal, runs the k6
container against the configured target with the lane's env and thresholds,
tears the app down, writes the report pair to `~/Desktop`, and records a `k6`
scope gate under the head SHA. A `k6`-scope record never satisfies the
comprehensive merge gate; only a full `pst:change` run does.

The k6 image, digest-pinned and `--rm` per pst:docker, runs the project's own
script (`lanes.k6.script`) or the platform's built-in light-load default when
the project ships none.

## The load narrative

When `lanes.k6.scenario` is set, the Markdown report opens with a narrative
built for a non-engineer go/no-go reader, not a raw metrics dump:

- The expected real-world peak, derived from the project's stated funnel with
  deliberately pessimistic-in-its-favor assumptions.
- What the app was actually tested to.
- The result as a safety-margin multiple over the expected peak.
- Behavior under a deliberate over-the-ceiling burst (graceful degradation, not
  just pass or fail).
- One relatable comparison for the scale.

Every input is the project's own, supplied in the config; nothing is hardcoded.
The CSV stays purely tabular. See `pst:change`'s `reference/CHANGE.template.md`
and `reference/CHANGE-frontmatter-spec.md` for the `scenario` shape.

## Read the output

Each k6 threshold becomes one finding, pass or fail. The lane passes when every
threshold passes (k6's own exit code). Fix the app or the load profile, never
weaken the threshold to make it pass.

## Failure modes

- Docker unavailable, or the k6 image cannot be pulled: exits 2 and names the
  cause; report and stop.
- No `CHANGE.md` with a `change_config:` block: the repo is not change-fabric-integrated. Say so.
- No k6 script and no default-usable `BASE_URL`: the default script errors; set
  `lanes.k6.env.BASE_URL` or `boot.target_url`.
