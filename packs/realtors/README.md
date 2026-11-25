# Change Fabric for realtors

Five plain-text skills for real estate agents. No code, no Docker, no hooks:
each skill is one `SKILL.md` that a chat app reads as instructions.

| Skill | Does |
| --- | --- |
| listing-roast | Scores listing photos and remarks, fixes, photo order, rewrite |
| fair-housing-guard | PASS or FAIL on outbound copy with neutral rewrites (not legal advice) |
| lead-reply | Drafts a lead reply, sends only after you say "send", logs it |
| buyer-consult | 4-question rounds with a recommended answer, one-page brief |
| seller-update | Weekly seller email from showing feedback, plain English |

## Claude (and Claude Duet)

Claude Duet carries over skills from your Claude account, so install them in
Claude first. Requires "Code execution and file creation" turned on.

1. Download a skill zip from `dist/` (one zip per skill).
2. In Claude: Customize, Skills, +, Create skill, Upload a skill.
3. Upload each zip and switch it on.

## ChatGPT

Skills upload is listed for Business, Enterprise, Healthcare, and Edu plans.

1. Sidebar: Plugins, then the Skills tab.
2. Create, Upload from your computer, pick a zip from `dist/`.
3. Wait for the scan, then repeat for each skill.

On a plan without Skills, use a Project: paste `chatgpt/instructions.txt` into
the project instructions and add the five `SKILL.md` files as project files.

## Build the zips

From this directory: `cd skills && for s in *; do zip -qr ../dist/$s.zip $s; done`.
Each zip holds one folder named like the skill, with its `SKILL.md`.

`install.html` is the one-screen page for the QR code.
