# 08 · School data: Daybook, timetable, calendar, ManageBac

Read `00-common.md` first.

## Scope
Where Joe's knowledge of the student's day comes from and how it's shown: the Daybook, the timetable, calendar sources, deadlines, the morning briefing and evening check.

## Files
- `Daybook.swift`: `Daybook` (vault `Brain/Daybook.md`: focus, today's five, classes; `timeline(date)` from `_files/School/timetable.json`; `instructions` for the prompt; `recentRequests`; routines file path).
- `CalendarFeed.swift`: `items(from:days:)` merges timetable lessons, alarms, `calendar.json` (Claude sync), **calendar links** (`links`, `refreshLinks()`, `parseICS`, `linkItems()`, ManageBac → deadlines), and the Mac's Calendar (EventKit). Duplicate deadlines from two sources are merged (`sameThing`, same day + ≥60% shared words).
- `AppDelegate`: `greetIfMorning` (morning briefing on first wake, or after the wake-up challenge), evening check, night shutdown, calendar links timer (30 min).
- Dashboard: `CalendarPage`, `TodayTimeline`, `NowNext`, `DueSoon`.

## Decisions
- ManageBac and Google come in by their **iCal links** (pasted once in onboarding or Settings → Calendar links); Joe reads them himself. The Claude-based sync (`syncInstructions`) remains as a fallback when there are no links.
- Raph's ManageBac link is added (17 items read in testing).

## Known issues / to-do
- The Daybook is built by Claude each morning (slow, uses tokens); a local build from calendar + tasks would be faster.
- ManageBac link deadlines have no subject field; subject is guessed from the title.
- No week/day toggle on the calendar; no drag to create events.
