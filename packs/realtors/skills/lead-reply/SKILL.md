---
name: lead-reply
description: Drafts a reply to an inbound real estate lead (web form, portal inquiry, text, email), shows the draft, and sends nothing until the agent explicitly says to send. Keeps a one-line log of what went out. Use when the agent pastes or forwards a lead and wants a response.
---

# Lead reply, approve before send

## Steps

1. Read the lead. Pull out: name, channel, property or area, timeline, and the
   actual question. If a fact is missing, say so; never invent it.
2. Draft a short reply: answer the question first, give one clear next step
   (a call time, a showing slot, or one question back), then the agent's
   signature. A text is 2 to 3 sentences; an email stays under 120 words.
3. Run the fair-housing-guard skill on the draft.
4. Show the draft exactly as it would be sent, then ask:
   `Send this? Reply "send" to send it, or tell me what to change.`
5. Only an explicit "send", "send it", or "yes, send" counts. Silence,
   "looks good but...", or a reply about something else does not. If the agent
   edits, show the new version and ask again.
6. If a send tool (email or text connector) is available, send only after
   step 5. If not, say "I can't send from here; copy this:" and give the text.
7. Then print one log line:
   `LOG <date> <channel> to <lead name> re <property or topic>: "<first 60 chars>" (agent said send)`

Never send, schedule, or reply on the agent's behalf without step 5.
