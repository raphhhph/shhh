# 09 · Alarms, the wake-up challenge, routines and automations

Read `00-common.md` first.

## Scope
Alarms, timers and reminders, the wake-up challenge, routines (spoken phrases that run steps), scheduled automations, the iPhone bridge.

## Files
- `Alarms.swift`: `Alarm`, `AlarmStore` (Alarms.json; `cancel`, `isLocked`), `AlarmRequest.parse` (spoken alarm commands, handled on the Mac), `AlarmClock` (ring, beep, snooze, `quiet` while answering, `answer` for the challenge, `onWokeUp`), the alarm card (`AlarmView`, sized to content), `AlarmClock.preview`.
- `WakeChallenge.swift`: kinds verse / fact / question rotating daily; 22 KJV verses (public domain); exam-useful facts per subject with their topic (dated real-world examples, case studies, technique, Chinese B phrases, TOK RLS); quick questions with accepted answers; checking (reading ≥60% of words; numbers from words). A different challenge per alarm on the same morning (`nextRing`).
- `ReminderMirror.swift` (alarms copied to a "Joe" Reminders list for the iPhone; "Ask Joe" list = PhoneRemote), Routines in the vault (`Brain/Daybook/Routines.md`).

## Decisions
- Challenge applies to alarms between 4:00 and 11:00 and to any alarm with "wake" in its title. No Stop button; one snooze; rings up to 20 min.
- A wake-up alarm **can't be cancelled in its last hour** (a spoken "cancel my alarm" at 7:27 deleted the 7:30 one). Spoken alarm commands are logged in History.
- After passing: the morning briefing (if not already given today).

## Known issues / to-do
- Raph's daily 7:30 "Wake up" alarm was deleted on 21 Oct; he may need to set it again.
- Chinese B facts read aloud are harder to recognise.
- Ideas: photo/QR challenge (scan something in the bathroom), streaks, a harder challenge after a snooze.
