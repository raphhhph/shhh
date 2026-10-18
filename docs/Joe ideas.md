# Joe: ideas worth building

Ranked by how much they'd change your day, with a rough size for each (S = an hour or two, M = an evening, L = a weekend). Tell Joe or me the numbers you want.

**Status, Monday 19 October:** everything except 15, 16 and 17 is built. How to use each:

| # | What | Try it |
|---|---|---|
| 1 | Ask from iPhone | "Hey Siri, add *what's due tomorrow* to Ask Joe". The answer arrives as a "Joe: …" reminder (Mac must be awake). |
| 2 | ManageBac watch | Automatic at 19:30 (Settings → Evening check). |
| 3 | Lecture recorder | "Joe, record this lecture", then close the notepad at the end. |
| 4 | Study plan | "Plan my study" routine. |
| 5 | Email replies | "Reply to Ms Marquardt saying Tuesday works": approval card first. |
| 6 | Focus mode | "Lock in for 50 minutes": wrap-up when the timer rings. |
| 7 | "Hey Joe" | Settings → "Hey Joe" (off by default). |
| 8 | People | Brain/People/People.md, updated as you mention people. |
| 9 | Mood picks | "Play something for studying" uses your own playlists. |
| 10 | Alarms on iPhone | Automatic: a "Joe" list in Reminders (Settings → Alarms on iPhone). |
| 11 | Weekend brief | Automatic on non-school mornings. |
| 12 | Daybook ticks | Automatic when Joe finishes a Daybook task. |
| 13 | Undo | "Joe, undo that." |
| 14 | Today timeline | Dashboard home page. |
| 18 | Backup | Pushed to GitHub; the Weekly review routine pushes every week. |
| 19 | Personality | Settings → Answers / Tone / Hype. |
| 20 | Daily recap | Night shutdown routine ends with today's recap. |

## Big wins

1. **Ask Joe from your iPhone (L).** A tiny iOS Shortcut or Telegram bot that forwards to Joe on your Mac: "add this to my daybook", "what's due tomorrow" from anywhere. Your Mac does the work; the phone is just a remote.
2. **Watch ManageBac for you (M).** Every evening Joe checks ManageBac's calendar feed and email for new tasks, grades and teacher posts, and puts anything new in tomorrow's Daybook, so nothing surprises you.
3. **Meeting and lecture recorder (M).** "Joe, record this lecture": he listens for the whole class, then writes structured notes, key terms and 5 recall questions into Obsidian. The notepad already does half of this.
4. **Daily study plan from deadlines (M).** From the Daybook deadlines and your free periods, Joe blocks study time in Google Calendar ("EE slides 16:00–17:00") and moves it when things change.
5. **Smart replies to email (S).** "Joe, reply to Ms Marquardt saying yes, Tuesday works." He drafts it in your voice (from your Voice Vault note) and shows the approval card before sending. Most of the plumbing exists.
6. **Focus mode (S).** "Joe, lock in for 50 minutes": he switches Vivaldi to School Workspace, mutes notifications (Do Not Disturb), plays your focus playlist, sets a timer, and gives you a 2-line summary of what you got done when it rings.

## Make what exists better

7. **Wake word "Hey Joe" (M).** Talk without holding a key. On-device, so it stays private; costs some battery.
8. **Joe remembers people (S).** A People note per person (teachers, WellPrepped creators, friends) that Joe updates when you mention them, so "email Giorgos" knows who that is.
9. **Spotify mood picks (S).** "Play something for studying" picks from your own playlists and liked songs instead of random search results.
10. **Alarms on your iPhone too (S).** Mirror Joe's alarms into Apple Reminders so they still ring when the laptop is closed.
11. **Weekend morning brief (S).** You said you'd tell me what you want on weekends: it's still the school-day version.
12. **Smarter Daybook ticks (S).** When you submit something on ManageBac or send an email Joe was tracking, he ticks the task himself.
13. **Undo for everything (M).** "Joe, undo that" for any action: file moves (works), calendar events, notes edits, Spotify likes.
14. **Dashboard: a Today timeline (S).** Classes, calendar and alarms on one visual line for the day, like a mini calendar.

## Quality and trust

15. **A test suite that runs every night (M).** Joe tests his own features (dictation phrases, alarms, Spotify parsing, permissions, file rules, slides) and tells you in the morning brief if anything broke.
16. **Usage meter (S).** Show roughly how much Claude usage Joe used today, and switch to Haiku automatically when you're near your limit.
17. **Proxy health (S).** When answers fail with connection drops, Joe checks your Clash proxy and suggests switching nodes.
18. **Commit and back up (S).** Save all of Joe's code to GitHub regularly so a broken Mac doesn't lose him. Nothing since early October is committed yet.

## Fun

19. **Joe's personality settings (S).** How chatty, how blunt, how much he hypes you up.
20. **Daily recap video or card (M).** End of day: a one-screen recap of what you did, music you played, tasks finished, posted to your Obsidian journal.
