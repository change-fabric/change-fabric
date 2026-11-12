# Brief: change fabric in 45 seconds

## Audience

Engineers deciding whether to adopt the toolkit from its site.

## Toolkit

Change fabric is a set of skills and hooks for coding agents. It decides when a
change is ready to land and records why.

## CHANGE.md

Each governed repo carries one root `CHANGE.md`. Its frontmatter holds
`change_config` (routes, boot, lanes) and `change_policy` (protected branches,
release tags, admin bypass).

## Lanes

`cf:change` runs five dockerized audit lanes against the config: Load (k6),
Accessibility (axe-core), Security (OWASP ZAP passive baseline scan), Responsive UX (browserless), and
Test cases (committed suites). Findings aggregate into one CSV and Markdown report, and
the run records a pass or fail for the head commit.

## Gate

`change_merge_guard.rb` denies a `gh pr merge` into a protected branch until a
passing run is recorded for the PR's head SHA. `change_tag_guard.rb` gates a
protected release tag the same way at publication.

## Self-made

This clip is made by `cf:walkthrough` from a committed storyboard, including
its own diagram scene, and rebuilds from those sources.
