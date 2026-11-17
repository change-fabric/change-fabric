# Brief: change fabric, the hero's journey

## Audience

Newcomers moving into engineering: someone from marketing technology, say, who
already asks an AI tool for code and wants to know whether this toolkit is for
them. Engineers deciding from the site are a second audience.

## Story

About 68 s on a 120 BPM bar grid. The clip follows a four-part arc (a call, a
mentor, a trial, a return) kept behind the scenes only: no chapter numbers,
timestamps or arc labels appear on screen. It opens on the problem, then each
part carries the homepage section heading instead: "Is it for me?", "What is
it?", "Before it merges", "Start building". It closes on the homepage call to
action, "Start Building", and the install line.

## Problem

Your agent writes code faster than you can judge it, and you can't yet tell
whether it is good or safe to ship.

## Fundamentals

Your coding agent is the harness: the program that runs an AI model on your
computer, reads your files, runs commands and asks before it changes anything.
Change Fabric extends it with skills and hooks the agent loads on its own:
rubrics applied per edit, commands asked for by name, and hooks the agent
cannot skip, such as a review before a push.

## For you

If you already ask an agent to write code, it is for you. It does not replace
your agent or need a new account. New to engineering: the habits a senior
reviewer would push for. Side projects: a review before every push. A team
repo: a gate later. It runs inside Claude Code, Codex CLI, Copilot CLI,
OpenCode and Pi, named as the homepage names them.

## Provenance

Some rubrics are drawn from published work and credit it as a source, not as
an endorsement: cf:ruby from Sandi Metz's Practical Object-Oriented Design in
Ruby, cf:refactoring from Martin Fowler's Refactoring, cf:usability from Jakob
Nielsen's ten usability heuristics, cf:prototyping from Houde and Hill's
prototype roles.

## Gate

When you are ready, one root `CHANGE.md` says how to boot your app. Five checks
(load with k6, accessibility with axe-core, security with OWASP ZAP, responsive
layout with browserless, your committed test cases) each run in their own
container against the running app, and any failure blocks the merge. You do
not need this on day one.

## Start

`brew tap change-fabric/cf`, then `brew install change-fabric` and
`change-fabric-install`. Open your agent in any project; the skills load on
their own. Ask for a small change, and on the next edit the agent names the
rubric it follows, for example cf:refactoring.

## Self-made

This clip is made by `cf:walkthrough` from a committed storyboard and rebuilds
from those sources. The "What is it?" and "Before it merges" scenes are
diagram scenes drawn under the capture clock, with no paid stills.
