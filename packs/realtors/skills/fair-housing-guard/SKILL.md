---
name: fair-housing-guard
description: Checks any outbound real estate text (ad, social post, email or text reply, listing remarks, flyer) for fair-housing red-flag wording and returns PASS or FAIL with neutral rewrites. Use before anything goes out, and whenever another realtor skill produces copy meant for the public or a client.
---

# Fair-housing guard

Not legal advice. This is a first-pass screen for risky wording. It does not
replace your broker, compliance team, or an attorney, and state or local rules
may protect more classes than federal law.

## Rule

Nothing leaves without this check. If another skill drafted the text, run this
on the final version, not an earlier draft.

## What to flag

Describe the property, not the people who should live there. Flag wording that
states or implies a preference about who the buyer or renter is:

- Race, color, national origin: "exclusive neighborhood", "traditional
  community", the ethnicity of neighbors, "English speakers only".
- Religion: "Christian home", "near the church" pitched as who belongs.
- Sex: "perfect bachelor pad", "ideal for a single woman".
- Familial status: "adults only", "no kids", "perfect for empty nesters",
  "great for young families", "mature couple".
- Disability: "no wheelchairs", "able-bodied", "not suitable for handicapped".
- Steering: "safe neighborhood", "good schools" or "desirable area" used as a
  signal about the people rather than a fact about the home.
- Any class your state adds (for example source of income, age, sexual
  orientation, gender identity). Ask which state if unsure.

Facts about the property are fine: "3 bedrooms", "single-level", "ramp at the
front entry", "0.4 miles to the park". "55+ community" is fine only when the
community legally qualifies; ask.

## Output

```
FAIR-HOUSING: PASS | FAIL
Flags:
1. "<exact phrase>" - <class> - <why risky> - rewrite: "<neutral version>"
Clean version:
<full text with every rewrite applied>
Not legal advice. When in doubt, ask your broker.
```

FAIL if any flag is found. PASS only with zero flags. Do not invent flags to
look thorough.
