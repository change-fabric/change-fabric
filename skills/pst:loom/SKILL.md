---
name: pst:loom
description: Paste a Loom transcript and get an exec-level summary (320 chars max) plus 3-5 minimal chapter markers, copied to clipboard via pbcopy.
argument-hint: "[transcript]"
allowed-tools: Agent, Bash
---

# /pst:loom

Turn a Loom transcript into a tidy summary and chapter markers, ready to paste.

## Input

<transcript>
#$ARGUMENTS
</transcript>

## Steps

1. Spawn a Haiku background agent (`model: haiku`) with the transcript above and the instruction below. Use a structured output schema.

   Agent instruction:

   ```
   You are summarizing a screen-recording transcript for a technical audience.

   Return JSON with two fields:

   "summary": a single exec-level description of what the recording shows. Max
   320 characters. Past tense. No filler, no hedging. Dense signal.

   "chapters": an array of 3-5 objects with "ts" (timestamp string, copy
   verbatim from the nearest transcript line, format mm:ss or m:ss) and
   "label" (1-5 words, lowercase, no punctuation, minimal -- less is more).
   Chapters must cover the arc of the recording from start to finish.

   Transcript:
   {{transcript}}
   ```

   Schema:

   ```json
   {
     "type": "object",
     "required": ["summary", "chapters"],
     "properties": {
       "summary": { "type": "string" },
       "chapters": {
         "type": "array",
         "items": {
           "type": "object",
           "required": ["ts", "label"],
           "properties": {
             "ts": { "type": "string" },
             "label": { "type": "string" }
           }
         }
       }
     }
   }
   ```

2. Format the output as:

   ```
   <summary>

   <ts> <label>
   <ts> <label>
   ...
   ```

   Example:

   ```
   Demonstrates SAML SSO login flow via Microsoft Entra ID for CAS360, replacing personal credentials with domain auth. Provisioned users sign in with Microsoft and land directly in chat.

   0:00 fresh session setup
   0:21 saml sso intro
   0:47 entra id sign in
   0:57 viewer role access
   1:06 recap and start chatting
   ```

3. Pipe the formatted output to `pbcopy` via Bash. Then print it to the conversation as well so the user can see what was copied.
