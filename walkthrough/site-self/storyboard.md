<!-- Generated from storyboard.json; do not edit -->

# change fabric in 45 seconds

## Hypotheses

- H-01 (role): An engineer can say what the toolkit gates and where its rules live after one viewing.
- H-02 (look_and_feel): Watching the flow assemble makes the parallel lanes and the single gate easier to follow than prose.

## 1. What it is (`intro`)

- Duration: 6500 ms
- Screen: screens/intro.html
- User goal: Know what the toolkit is
- Action: Read the title card
- Hypotheses: H-01
- Heuristics shown: H2, H8
- Requirement: brief.md#toolkit

> Change fabric is a set of skills and hooks for Claude Code. It decides when a change is ready to land, and it records why.

## 2. One file per repo (`change-md`)

- Duration: 7000 ms
- Screen: screens/change-md.html
- User goal: Know where the rules live
- Action: Read the CHANGE.md frontmatter
- Hypotheses: H-01
- Heuristics shown: H2, H6
- Requirement: brief.md#changemd
- Assumption A-01: The CHANGE.md on screen is an abridged example for an unnamed app, not a copy of any real repo's file.

> Each repo carries one CHANGE.md. Its frontmatter names what to test, and which branches and release tags are protected.

## 3. How a change is gated (`gate-flow`)

- Duration: 17000 ms
- Screen: screens/gate-flow.html
- User goal: See a change pass through the lanes and the gate
- Action: Watch the flow assemble
- Hypotheses: H-02
- Heuristics shown: H1, H2
- Requirement: brief.md#lanes
- Requirement: brief.md#gate
- Node `pr`: Pull request
- Node `k6`: Load (k6)
- Node `a11y`: Accessibility (axe)
- Node `zap`: Pentest (ZAP)
- Node `ux`: Responsive UX
- Node `cases`: Test cases
- Node `report`: One report
- Node `gate`: Gate
- Node `merge`: Merge to main
- Node `tag`: Release tag
- Edge `e-pr-k6`: pr -> k6
- Edge `e-pr-a11y`: pr -> a11y
- Edge `e-pr-zap`: pr -> zap
- Edge `e-pr-ux`: pr -> ux
- Edge `e-pr-cases`: pr -> cases
- Edge `e-k6-report`: k6 -> report
- Edge `e-a11y-report`: a11y -> report
- Edge `e-zap-report`: zap -> report
- Edge `e-ux-report`: ux -> report
- Edge `e-cases-report`: cases -> report
- Edge `e-report-gate`: report -> gate (findings)
- Edge `e-gate-merge`: gate -> merge
- Edge `e-gate-tag`: gate -> tag
- Initial: pr

| t_ms | op | target |
| --- | --- | --- |
| 400 | add_node | k6, a11y, zap, ux, cases, e-pr-k6, e-pr-a11y, e-pr-zap, e-pr-ux, e-pr-cases |
| 600 | fit_view |  |
| 1500 | pulse_edge | e-pr-k6, e-pr-a11y, e-pr-zap, e-pr-ux, e-pr-cases |
| 2400 | fit_view | k6, a11y, zap, ux, cases |
| 3300 | highlight | k6 |
| 4100 | highlight | a11y |
| 5000 | highlight | zap |
| 5800 | highlight | ux |
| 6700 | highlight | cases |
| 7600 | unhighlight | k6, a11y, zap, ux, cases |
| 7700 | add_node | report, e-k6-report, e-a11y-report, e-zap-report, e-ux-report, e-cases-report |
| 7800 | fit_view |  |
| 8500 | pulse_edge | e-k6-report, e-a11y-report, e-zap-report, e-ux-report, e-cases-report |
| 9600 | add_node | gate, e-report-gate |
| 9700 | fit_view |  |
| 10500 | focus | gate |
| 11200 | highlight | gate, e-report-gate |
| 11500 | label | gate |
| 13000 | add_node | merge, tag, e-gate-merge, e-gate-tag |
| 13100 | fit_view |  |
| 14000 | pulse_edge | e-gate-merge, e-gate-tag |
| 14300 | highlight | merge, tag, e-gate-merge, e-gate-tag |
| 15600 | fit_view |  |

> A pull request fans out to five audit lanes, each in its own container: load, accessibility, pentest, responsive layout, and test cases. Every finding lands in one report, and the gate records a pass for the head commit. Only then does the merge or the release tag go through.

## 4. Made by the walkthrough skill (`made-by`)

- Duration: 8000 ms
- Screen: screens/made-by.html
- User goal: Know how this clip was made
- Action: Read the source list
- Hypotheses: H-01
- Heuristics shown: H6, H10
- Requirement: brief.md#self-made

> The walkthrough skill makes this clip from one storyboard, including the diagram you just watched. Voice, frames, and captions rebuild from committed sources.
