---
name: plan-my-day
description: Build and write Matthew's day plan to the Claude Google Calendar. Use when he says "plan my day", "plan today", "re-plan", "push everything back", or otherwise asks for the day's blocks to be made or changed. Also use when asked what he is supposed to be doing now and the calendar has no plan on it yet.
---

# plan-my-day

Matthew's laptop and phone both read one calendar to decide what he should be
doing, and the laptop keeps YouTube, Twitch, Reddit and Steam closed until that
calendar says the day has been planned. This skill is what writes it.

The gate opens on one thing: an event on the **Claude** calendar whose title
starts with `✅ Plan approved`, running from the moment of approval to 23:59.
**Never create that event before he has approved the plan.** It is the only
thing standing between "a plan exists" and an afternoon of YouTube.

## Fixed references

Time zone is **America/Phoenix** — no DST, so the offset is always -07:00.

| Thing | Value |
| --- | --- |
| Claude calendar (write here) | `d4d3457c1699083d464ecbfc9817359e17534ad8c8056a346aed1d35db5f6633@group.calendar.google.com` |
| Canvas deadlines (read) | `r497ohu0o70rfrvoo08vopoj5ponb22a@import.calendar.google.com` |
| ASU (read) | `jvdgah79316uka7cch13r9clc5f1hngo@import.calendar.google.com` |
| Hiring events (read) | `65ed76ed86a5ea5052335dd62c823423b72520233d7e70e09050fdc52e66a26f@group.calendar.google.com` |
| Primary (read) | `matthewjurenka@gmail.com` |
| Goals & Tasks | the Claude Doc titled "Goals & Tasks" — read it with the docs tools |

## Which tools you have

Two situations, same procedure:

- **claude.ai (phone or laptop browser)** — use the Google Calendar connector
  to read and write, and the docs tools for the Goals doc. This is the normal
  path, and the only one available from the phone.
- **Claude Code on the laptop** — there is no calendar connector, so use the
  `dayplan` CLI: `dayplan events` and `dayplan events -1` for today and
  yesterday, and `dayplan apply` to write. It needs the Calendar API backend
  (`dayplan auth` once); if `dayplan apply` says otherwise, say so and plan in
  the browser instead. The Goals doc still needs the docs tools.

## Procedure

### 1. Gather, in parallel

- The current time in America/Phoenix.
- The **Goals & Tasks** doc: the backlogs and the schedule constraints.
- Today's events on *all five* calendars above.
- Yesterday's events on the Claude calendar.
- Canvas deadlines for the next three days, and any hiring events today.

### 2. Ask what got done

Once, in one short message, list yesterday's work blocks and ask which
happened. Skip this entirely on a mid-day re-plan — he has already told you
today.

Anything unfinished goes first in today's plan.

### 3. Build the blocks

Start from **now**, rounded up to the next 15 minutes. Do not plan a morning
that has already gone; a late start loses work hours, not sleep or social time.

In order of what gets placed first:

1. **Non-negotiables.** Class Tue/Thu 4:30–5:45pm. Anything already on the ASU
   or primary calendars. Hiring events. Shower and PT exercises immediately
   after waking, if he is only just up.
2. **Gym**, if today is one of the three olympic weightlifting days. The gym is
   open Mon–Fri 4–8pm and Sat 8am–noon, so on a weekday it competes with class
   and with the evening — place it deliberately rather than last.
3. **~6 hours of focused work**, in 60–90 minute blocks with 10–15 minute
   breaks between them. Rotate between the Telegram bot (team project, pons
   launchpad integration) and the job search rather than doing six hours of one
   — alternating is what keeps both moving. Pull the actual items from the
   doc's backlogs.
4. **Side projects** (YouTube videos, the Valheim server) only after the main
   work, and only if the day has room.
5. **2+ hours social**, and keeping the room clean.
6. **One 30-minute buffer** in the afternoon. It will get used.
7. **Wind-down** before bed — asleep between 11pm and midnight.

Fold in anything due on Canvas in the next three days as its own work block,
not as a note.

### 4. Title and describe each block

Title: a goal prefix, then a concrete action.

    Bot: wire the pons launchpad deposit call
    Jobs: five applications off the shortlist
    Gym: olympic lifting — snatch + front squat
    People: call home
    School: CS 560 reading, chapters 4-5
    Side: cut the Valheim footage
    Break: walk
    Buffer:
    Life: shower and PT

Prefixes are `Bot`, `Jobs`, `Gym`, `People`, `School`, `Side`, `Break`,
`Buffer`, `Life`. "Work on the bot" is not a title; "wire the deposit call" is.

Description: **the first physical step** and nothing else — "open
packages/bot and run the test suite", "open the shortlist spreadsheet, take the
top row". This is what the laptop's notification and the bar tooltip show, so it
is the sentence that has to get him started.

### 5. Show it and ask

A compact list — time, title, one line each. Then: **"Approve, or what should
change?"**

Do not write anything to the calendar yet.

### 6. On approval, write it

In this order, which matters:

1. Delete every event on the Claude calendar from now to the end of today,
   including any older `✅ Plan approved` marker. Earlier blocks from this
   morning stay — they are the record of what the day was planned as.
2. Create each block, with `reminders: {useDefault: false, overrides:
   [{method: "popup", minutes: 0}]}` so the phone buzzes at the start of it.
3. **Last**, create `✅ Plan approved` from now to 23:59 today,
   `transparency: transparent`, no reminders. If any block failed to write, do
   not create this.

From Claude Code, steps 1-3 are one call — pipe JSON to `dayplan apply`:

```json
{
  "blocks": [
    { "title": "Bot: wire the deposit call",
      "desc": "Open packages/bot and run the test suite",
      "start": "2026-10-19T09:00", "end": "2026-10-19T10:30" }
  ],
  "approve": true
}
```

Then confirm in one line: the gate opens within two minutes and the first block
notifies.

### 7. Tidy the doc

Remove from the Goals doc's backlogs anything he said was done.

## Mid-day re-plans

"Push everything back an hour", "the gym is closed", "that took way longer than
I thought" — rewrite only the blocks from now on. Keep the existing approval
marker if there is one; the gate is already open and does not need re-opening.

## Tone

Brief. No guilt about a late start, a skipped block or a day that fell apart —
he is already aware, and the plan is the thing that helps. Don't pad the list
with encouragement.
