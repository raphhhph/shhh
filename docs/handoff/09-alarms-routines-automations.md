# 09 · Alarms, the wake-up challenge, routines and automations

Read `00-common.md` first.

## Scope
Alarms, timers and reminders, the wake-up challenge, routines (spoken phrases that run steps), scheduled automations, the iPhone bridge.

## Files
- `Alarms.swift`: `Alarm`, `AlarmStore` (Alarms.json; `cancel`, `isLocked`), `AlarmRequest.parse` (spoken alarm commands, handled on the Mac), `AlarmClock` (ring, beep, snooze, `quiet` while answering, `answer` for the challenge, `onWokeUp`), the alarm card (`AlarmView`, sized to content), `AlarmClock.preview`.
- `WakeChallenge.swift`: kinds verse / fact / question rotating daily; 22 KJV verses (public domain); exam-useful facts per subject with their topic (dated real-world examples, case studies, technique, Chinese B phrases, TOK RLS); quick questions with accepted answers; checking (reading ≥60% of words; numbers from words). A different challenge per alarm on the same morning (`nextRing`). Subjects with facts and questions: Raph's seven (via `StudyBuddy.pack`) plus Biology, Chemistry, Physics, History, Psychology, Mathematics AA and Geography (`otherSubject`, so testers taking those get their own).
- `ReminderMirror.swift` (alarms copied to a "Joe" Reminders list for the iPhone; "Ask Joe" list = PhoneRemote), Routines in the vault (`Brain/Daybook/Routines.md`).
- `Daybook.addDefaultRoutines()`: writes Evening check, Night shutdown and Study session into Routines.md when missing (at launch, when the notes folder is chosen, and before each automation runs). Each default is added once; one the student deletes stays deleted (`defaultRoutinesAdded` in UserDefaults).

## Decisions
- Challenge applies to alarms between 4:00 and 11:00 and to any alarm with "wake" in its title. No Stop button; one snooze; rings up to 20 min.
- A wake-up alarm **can't be cancelled in its last hour** (a spoken "cancel my alarm" at 7:27 deleted the 7:30 one). Spoken alarm commands are logged in History.
- After passing: the morning briefing (if not already given today).
- An alarm more than 30 min late (the Mac slept through it) doesn't ring: a "Missed while the Mac was asleep" toast instead (`AlarmClock.tooLate`). The iPhone copy in Reminders is what covers a closed laptop.
- A snoozed alarm is a one-off copy, even when the original repeats.
- Wake-up streak (`AlarmClock.countWakeUp`, `wakeStreak`/`wakeStreakDay` in UserDefaults): mornings in a row the challenge was passed without a snooze; a toast from 2 on. A snooze or a challenge left to ring out resets it; a day with no alarm (weekend) doesn't.
- After a snooze, the challenge is always a question (answering beats reading half asleep).
- Reading check: Chinese characters count one by one, and only when the recogniser wrote Chinese; otherwise only the English words of a fact are checked.
- Night shutdown's default routine checks there's a wake-up alarm for tomorrow and offers one about an hour before the first class.

## Known issues / to-do
- Raph's daily 7:30 "Wake up" alarm was deleted on 21 Oct; he may need to set it again.
- Fixed 21 Oct (branch `claude/project-thread-odumu1`, needs a Mac build): snoozing a repeating alarm left a new repeating alarm behind each time; cancelling a repeating alarm after it had rung kept it ringing on the iPhone (completing a recurring reminder only moves it on); stale alarms rang hours late after sleep; Chinese B facts were nearly impossible to pass; new students had no routines, so the 19:30 and 21:30 automations had nothing to run.
- Ideas: photo/QR challenge (scan something in the bathroom).
