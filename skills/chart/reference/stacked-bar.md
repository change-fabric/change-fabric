# Stacked bar

Shows a total per category and how it splits into parts. Follow `grammar.md` for everything not stated here.

## When to use

- The total matters and the share of each part matters, for a few categories: findings per phase split by severity.

## When not to

- Comparing one part across categories precisely: only the bottom segment shares a baseline, so use grouped `bar.md`.
- More than about 4 parts: the middle segments become unreadable.

## Rules

- Values of one key stack in series order from 0; negative values stack downward from 0 separately [scale-zero].
- Put the part the reader cares about most first, so it sits on the baseline.
- `orientation` works as in `bar.md`.
