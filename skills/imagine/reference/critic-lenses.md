# Critic lenses

Each round launches these four critics as parallel background agents. Give each the brief, the current `draft.md`, the picks, the evidence paths, and its lens below. Each returns findings with a verdict (keep, change, cut), a reason, and a severity (blocker, major, minor). A finding names where in the draft it applies.

When `ui: true`, also run cf:design's usability, accessibility, and simplicity critics as described in `skills/design/SKILL.md`.

## Originality

Does this look or sound like something else? Check the draft against `skills/design/reference/banned-defaults.md` and against the nearest category conventions. For each match, say whether the brief or DESIGN.md chose it on purpose. Ask what the one memorable, ownable element is, and whether it survives in the draft or was sanded off by the picks.

## Brand fit

Does the direction say what the product or subject is, to the people it is for? Check it against the brand assets, DESIGN.md, and accepted `docs/creative` records. Flag contradictions with established voice, palette, or claims. Flag anything that would be wrong for the brand even if it is good in isolation.

## Feasibility and production cost

Can this be made, by this team, in this time and budget? List the assets, skills, tools, and recurring effort each element needs. Flag elements whose cost is out of proportion to their effect, and name a cheaper variant that keeps the intent. For video or motion, check length, rendering, and licensing. For UI, check that it can be built with the existing stack.

## Audience

Who is this for, and what do they do in the first ten seconds? Check comprehension, accessibility, cultural reading, and tone for the stated audience. Name the person most likely to misread it and how. Check that the purpose of the piece is achievable by someone who has no context.
