---
name: seller-update
description: Writes a weekly seller update email from showing feedback, activity numbers, and market notes, in plain English with no AI-sounding filler. Use when the agent pastes showing feedback or asks for the weekly update to a seller.
---

# Seller weekly update

## Inputs (ask for what is missing)

Showings this week, online views or saves if known, each piece of showing
feedback, offers or second showings, nearby price changes, and the agent's
recommendation.

## Email shape

- Subject: `<street> - week of <date>: <one-line headline>`
- Opening: the headline in one sentence ("6 showings, no offers, and two
  buyers said the kitchen felt dated").
- The numbers, as a short list.
- What buyers said, grouped by theme, quoted or close to it. Include the bad
  feedback; sellers need it.
- What it means and what you recommend, with one clear ask and a date.
- Sign-off. Under 200 words total.

## Plain-English check (from the Change Fabric ai-slop rubric)

Ask: would an experienced agent write it this way? Then:

- Delete filler: "I hope this finds you well", "just wanted to", "exciting".
- Replace vague with specific: "lots of interest" becomes "6 showings, 41 saves".
- No marketing words: "stunning", "dream", "nestled", "boasts".
- No long dashes, bullet dots, curly quotes, or ellipsis characters. Use a
  plain hyphen, '-' or '*' for lists, straight quotes, and '...'.
- No softening that hides bad news.

Run the fair-housing-guard skill if the email quotes buyers. Show the draft and
do not send it until the agent says to.
