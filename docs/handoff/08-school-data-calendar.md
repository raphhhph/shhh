# 08 · School data: Daybook, timetable, calendar, ManageBac

Read `00-common.md` first.

## Scope
Where Joe's knowledge of the student's day comes from and how it's shown: the Daybook, the timetable, calendar sources, deadlines, the morning briefing and evening check.

## Files
- `Daybook.swift`: `Daybook` (vault `Brain/Daybook.md`: focus, today's five, classes; `timeline(date)` from `_files/School/timetable.json`; `instructions` for the prompt; `recentRequests`; routines file path). **Local build**: `localText()` / `buildLocally()` write today's Daybook without Claude; `finishRules` tells Claude to fill only the parts marked `pendingMark`; `classNames` lists the timetable's classes.
- `CalendarFeed.swift`: `items(from:days:)` merges timetable lessons, alarms, `calendar.json` (Claude sync), **calendar links** (`links`, `refreshLinks()`, `parseICS`, `occurrences(of:rule:from:to:)`, `linkItems()`, ManageBac → deadlines), and the Mac's Calendar (EventKit). Duplicate deadlines from two sources are merged (`sameThing`, same day + ≥60% shared words). `Item.subject` is the class a deadline is for (`subject(of:notes:category:)`).
- `AppDelegate`: `greetIfMorning` (morning briefing on first wake, or after the wake-up challenge), evening check, night shutdown, calendar links timer (30 min).
- Dashboard: `CalendarPage`, `TodayTimeline`, `NowNext`, `DueSoon`.

## Decisions
- ManageBac and Google come in by their **iCal links** (pasted once in onboarding or Settings → Calendar links); Joe reads them himself. The Claude-based sync (`syncInstructions`) remains as a fallback when there are no links.
- Raph's ManageBac link is added (17 items read in testing).

- **The Daybook is built locally** (Oct 2026, branch `claude/school-data`). On the morning briefing or the first request of a day, Joe writes Classes (table from the timetable), Rest of today (link and Mac Calendar events), Deadlines (next three weeks), Today's five (what's due today or tomorrow, then the last day's unticked tasks with "carried N×" raised; 3× or more asks for a decision), Backlog and Inbox carried over, and a Focus line. Claude then fills only Needs you (Gmail), acts on Inbox, adds the weekday's regular meetings from Patterns and Post today. With no calendar link and no Mac Calendar access, Rest of today and Deadlines are also left to Claude (with the old calendar.json sync). `buildRules` (the full Claude build) is only the fallback when the local build can't write.
- With calendar links, the morning build no longer asks Claude to sync calendar.json (it duplicated the links).
- Calendar links: a link that fails this time keeps its last items (each saved item has `source`); an HTTP error says the link may have been reset. Repeating events (RRULE: daily, weekly with BYDAY, monthly, yearly; INTERVAL, COUNT, UNTIL, EXDATE, moved occurrences) are expanded for 90 days, so weekly Google events show every week. TZID times are converted to UTC; cancelled events are left out. On Google links, titles with test, quiz, exam, due, summative or formative count as deadlines (that check was dead code before).
- Deadline subject (`CalendarFeed.subject(of:notes:category:at:)`): Raph's real ManageBac feed (checked Oct 21) has only SUMMARY, DTSTART (`TZID=Asia/Shanghai`), DTEND, UID and a cut-off DESCRIPTION, with no class field, and many titles don't name the class ("Taxes", "Quiz: Markets 2"). So it tries, in order: a class named in the title (full name, initials such as BM or TOK, or a distinctive first word); then a class named in the notes; then typical subject words (`typicalWords`: taxes and markets for Economics, exhibition for TOK, and so on); Chinese characters for the Chinese class; the class on the timetable at the due time; and finally CATEGORIES. Due soon and the calendar card show the result.

- **Timetable from a photo or PDF** (for new students with no timetable.json): `Daybook.importTimetable(from:dayToday:) async -> String`. Claude (Sonnet, Read tool only) returns periods and days as JSON; `timetableJSON` turns that into timetable.json with dates for the next 183 days. A weekly timetable maps weekdays; a rotation (Day 1–N) moves on one day per weekday from `dayToday`, or Day 1 today. An earlier timetable goes to the Trash. Onboarding calls it from the School step. Weekly and cycle-less timetables have no "Day N · Cycle X" label.

- **Holidays**: `CalendarFeed.holidays` holds the days covered by whole-day events on the links or calendar.json named a holiday, break, vacation, half term, recess, National Day and the like. `Daybook.schoolDay(on:in:)` treats them as no school, so classes, the Daybook and "tomorrow" skip them for any timetable.

- **New ManageBac tasks during the day**: after each link refresh (every 30 min), deadlines whose title wasn't there before go into today's Daybook (`Daybook.addNewDeadlines`): under Deadlines, and as a task marked "new" in Today's five when due within two days and there's room, else Backlog.

- **Plan** section in the local Daybook (`studyPlan`): today's free periods (a "—" in the grid), 90 minutes starting 30 minutes after the last class, and 19:30–21:00 (10:00–12:00 instead on a day off), each given to the most pressing deadline of the next two weeks. The soonest gets two blocks; tests and summatives come first on the same day. These are suggestions, not calendar events, so the timeline doesn't show them.

## Test
- `Joe --daybook-preview` prints the Daybook Joe would build now (writes nothing). `Joe --daybook` prints the instructions (and builds today's if missing).
- `Joe --calendar-link parse <file.ics>` prints parsed items, repeats expanded.
- `Joe --timetable-import <photo or pdf> ["Day 3"]` reads a timetable and saves timetable.json (the old one goes to the Trash).

## Known issues / to-do
- Not yet compiled on a Mac when written (the cloud box has no Swift): build, then check `--daybook-preview` against a real day.
- Some titles still get no subject or a guessed one ("Paper 2 Assessment Reflection", "Approval Panel Presentation"). Grow `typicalWords` from real misses.
- The evening check still runs through Claude (Routines.md). New tasks now reach the Daybook on their own, so the routine could drop that part.
- Monthly "second Tuesday" style repeats only show their first date.
- Onboarding (`claude/onboarding-set-up-once`) prefills subjects from ManageBac titles with its own `subjectGuesses()`; once both branches are merged it can use `linkItems().compactMap(\.subject)`.
- No week/day toggle on the calendar; no drag to create events (UI thread).
