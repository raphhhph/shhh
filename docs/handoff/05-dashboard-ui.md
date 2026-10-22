# 05 · Dashboard UI and design system

Read `00-common.md` first.

## Scope
The dashboard window: pages Home, Calendar, Study, History, Routines, Alarms, Notes, Dictionary, Spotify, Usage, Settings (General, Personality, Automations, Privacy, Advanced); the look.

## Files
- `Dashboard.swift`: `Dashboard` (window), `DashboardModel` (data, `reload()` every 2 s; History.json decoded only when it changes), `DashboardView` (sidebar groups + page), each page struct, `Card`, `PageTitle`, `PillButton`, `ChipButton`, `Choice`, `SubjectGroup` (IB group colours), `Look` (tokens), `Theme`, `AppAppearance`, `PointsCalculator`, snapshot code (`Dashboard.snapshot`).

## Design system (keep it consistent)
- Tokens in `Look`: accent, sidebar, card, page, line, deadline, personal, `titleDesign`. Four **themes** (Settings → General → Style): Classic (orange), Midnight (navy + gold, forces dark), Paper (warm, serif titles), Ocean (blue, rounded). `.id(theme)` on the root redraws on change.
- Controls: `Choice` (pill menu), `PillButton`, `JoeSwitch` (on/off, accent capsule with a springy knob; every Settings switch), `Segmented` (soft tray with the current option raised; Settings tabs, History, Usage, Alarms, Notes, points calculator; no stock `.pickerStyle(.segmented)` left), `SettingsRow` (hover highlight). Use these rather than stock controls.
- Pages start 56 pt from the top, clear of the window buttons and level with Joe in the sidebar (46 pt plus the title bar).
- Cards: 16 pt continuous corners, 1 pt line, 18 pt padding; side-by-side cards use `stretch: true` + `.fixedSize(horizontal: false, vertical: true)` to end level.
- IB subject colours (`SubjectGroup`): language blue, acquisition teal, societies gold, sciences green, maths violet, arts pink, core slate; personal events orange; deadlines red.
- Calendar: tinted blocks with a coloured edge, weekends hidden when empty, alarms as a small line, right rail (details, Due soon, subject key) when wide.
- Verify with `Joe --snapshot <page> file.png 1280 820 [dark]` and look at the image; a tiling script (Swift, AppKit) makes contact sheets.

## Known issues / to-do
- "Less default SwiftUI": switches and segmented pickers are now Joe's own (Oct 2026). The alarm time is a `TimeDial` (big hours and minutes with steps; minutes by five) and the timeline colour a `SwatchPicker` (a popover of eight colours). Still to do: History, Dictionary, Spotify pages beyond their pickers.
- Settings (Oct 2026, Raph: "easier to use and more streamlined"): six tabs grouped the way a student looks for things: You (profile, school calendar, look, Joe on this Mac), Joe (how Joe talks, voice, notch), Listening (dictation, hands-free), Daily (every day, iPhone), Privacy, Advanced (brain first, then control, account, other models, downloads, memory). Tab ids stay `general`/`personality`/`automations`/`privacy`/`advanced` plus new `listening`. "Find a setting" searches `SettingsPage.index` (label + words people might type); a result opens its tab and lights the row (`settingsHighlight`). Add new rows to the index. Other models' endpoint/key/model only show once it's on. Row details wrap to two lines instead of cutting off.
- Home's top (Oct 2026, Raph: "cramped, use all the space"): starters wrap onto a second line (`ChipFlow`) instead of scrolling off the edge; Now/Next put the countdown beside the label so the class name and room get the full tile (two lines if needed); page titles sit 56 pt down, clear of the window buttons and level with Joe in the sidebar (Raph found them too close to the top at 20); timeline blocks shrink their label before cutting a word.
- Declutter: Home's Recent is three lines with "All history" (Oct 2026); the sidebar footer is the other candidate.
- Due soon rows show a Start button on hover (Home and Calendar): Joe breaks the deadline into steps and plans the first one tonight (`CalendarFeed.Item.startRequest`). In the notch overview, tapping a deadline does the same.
- Empty states should offer the fix, not just say what's missing: Due soon shows "Link ManageBac" (opens Settings → General via `DashboardModel.openSettings`) until the calendar has synced.
