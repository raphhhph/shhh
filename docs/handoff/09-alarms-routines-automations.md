# 09 · Alarms, the wake-up challenge, routines and automations

Read `00-common.md` first.

## Scope
Alarms, timers and reminders, the wake-up challenge, routines (spoken phrases that run steps), scheduled automations, the iPhone bridge.

## Files
- `Alarms.swift`: `Alarm`, `AlarmStore` (Alarms.json; `cancel`, `isLocked`), `AlarmRequest.parse` (spoken alarm commands, handled on the Mac), `AlarmClock` (ring, beep, snooze, `quiet` while answering, `answer` for the challenge, `onWokeUp`), the alarm card (`AlarmView`, sized to content), `AlarmClock.preview`.
- `WakeChallenge.swift`: kinds verse / fact / question rotating daily; 22 KJV verses (public domain); exam-useful facts per subject with their topic (dated real-world examples, case studies, technique, Chinese B phrases, TOK RLS); quick questions with accepted answers; checking (reading ≥60% of words; numbers from words). A different challenge per alarm on the same morning (`nextRing`).
- `FocusSession.swift`: focus mode. `FocusSession` (one block at a time; `start(title:minutes:)`, `startPlannedBlock()`, `stop/pause/resume`, `chip`, `remaining`; an ObservableObject for the notch), `FocusRequest.parse` (spoken requests), `FocusPlan` (today's Plan blocks, `resolve`, `tickWeek`, `preview`), `FocusShortcuts` (the student's "Joe Focus On"/"Joe Focus Off" shortcuts).
- `ReminderMirror.swift` (alarms copied to a "Joe" Reminders list for the iPhone; "Ask Joe" list = PhoneRemote), Routines in the vault (`Brain/Daybook/Routines.md`).

## Decisions
- Challenge applies to alarms between 4:00 and 11:00 and to any alarm with "wake" in its title. No Stop button; one snooze; rings up to 20 min.
- A wake-up alarm **can't be cancelled in its last hour** (a spoken "cancel my alarm" at 7:27 deleted the 7:30 one). Spoken alarm commands are logged in History.
- After passing: the morning briefing (if not already given today).
- The morning brief and the 21:30 night shutdown carry the study loop (see 08, "Study loop in the routines"): the brief says one overdue item with its action, today's study blocks and this week's milestone; the shutdown ticks what got done, re-plans slipped blocks into Week.md, says tomorrow's first block and offers one email draft for an overdue item. Sunday from 17:00 the week plan is built once and announced. Preview with `Joe --prompt brief|shutdown|sunday`.

- **Focus mode** (round 2, priority 6): "start my block" / "start a study block" takes the Plan's current block (until its end) or next one (its length) from today's Daybook (Week.md's day when the Daybook isn't today's); "focus on Paper 2 for 50 min", "focus for 25 minutes" (a block starting within 30 min, else "Study block"), "stop / pause / resume focus". Handled on the Mac, before Spotify and the study intents. While it runs: its countdown in the side-notch capsule (as a timer item; × stops it), a macOS Focus via `shortcuts run "Joe Focus On"` when that shortcut exists (`shortcuts list` read once; missing = skipped silently; "Joe Focus Off" at the end), and the `focusPlaylist` setting's Spotify playlist if set (no UI yet: `defaults write <domain> focusPlaylist "Deep Focus"`). At the end: the Hero chime, "Block done" spoken (even with the voice off), today's matching Week.md block ticked, and a card offering a 3-question check; "yes" within 15 min opens the whiteboard with "Quick 3-question check on <title>". Stopping early ticks nothing. The notch's Next study block widget and block chip (UI, #3) should call `FocusSession.startPlannedBlock()` / `FocusSession.start(title:minutes:)` and read `FocusSession.shared.chip`. Test: `Joe --route "start my block" "stop focus"`, `Joe --focus-preview "<request>" [<vault>]` (what would start, and whether the shortcut exists; starts nothing).

## Known issues / to-do
- Raph's daily 7:30 "Wake up" alarm was deleted on 21 Oct; he may need to set it again.
- Chinese B facts read aloud are harder to recognise.
- Focus mode: setting up the two shortcuts belongs in onboarding (not built); a focus playlist picker in Settings; the old Claude-set "Focus …" timers still ask what got done when they ring.
- Ideas: photo/QR challenge (scan something in the bathroom), streaks, a harder challenge after a snooze.
