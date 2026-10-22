# 05 · Dashboard UI and design system

Read `00-common.md` first.

## Scope
The dashboard window: pages Home, Calendar, Study, History, Routines, Alarms, Notes, Dictionary, Spotify, Usage, Settings (General, Personality, Automations, Privacy, Advanced); the look.

## Files
- `Dashboard.swift`: `Dashboard` (window), `DashboardModel` (data, `reload()` every 2 s; History.json decoded only when it changes), `DashboardView` (sidebar groups + page), each page struct, `Card`, `PageTitle`, `PillButton`, `ChipButton`, `Choice`, `SubjectGroup` (IB group colours), `Look` (tokens), `Theme`, `AppAppearance`, `PointsCalculator`, snapshot code (`Dashboard.snapshot`).

## Design system (keep it consistent)
- Tokens in `Look`: accent, sidebar, card, page, line, deadline, personal, `titleDesign`. Four **themes** (Settings → General → Style): Classic (orange), Midnight (navy + gold, forces dark), Paper (warm, serif titles), Ocean (blue, rounded). `.id(theme)` on the root redraws on change.
- Controls: `Choice` (pill menu), `PillButton`, `JoeSwitch` (on/off, accent capsule with a springy knob; every Settings switch), `Segmented` (soft tray with the current option raised; Settings tabs, History, Usage, Alarms, Notes, points calculator; no stock `.pickerStyle(.segmented)` left), `SettingsRow` (hover highlight). Use these rather than stock controls.
- Pages start 20 pt from the top, so the page title sits in the title-bar row beside the window buttons (the sidebar keeps its 46 pt).
- Cards: 16 pt continuous corners, 1 pt line, 18 pt padding; side-by-side cards use `stretch: true` + `.fixedSize(horizontal: false, vertical: true)` to end level.
- IB subject colours (`SubjectGroup`): language blue, acquisition teal, societies gold, sciences green, maths violet, arts pink, core slate; personal events orange; deadlines red.
- Calendar: tinted blocks with a coloured edge, weekends hidden when empty, alarms as a small line, right rail (details, Due soon, subject key) when wide.
- Verify with `Joe --snapshot <page> file.png 1280 820 [dark]` and look at the image; a tiling script (Swift, AppKit) makes contact sheets.

## Known issues / to-do
- "Less default SwiftUI": switches and segmented pickers are now Joe's own (Oct 2026). The alarm time is a `TimeDial` (big hours and minutes with steps; minutes by five) and the timeline colour a `SwatchPicker` (a popover of eight colours). Still to do: History, Dictionary, Spotify pages beyond their pickers.
- Home's top (Oct 2026, Raph: "cramped, use all the space"): starters wrap onto a second line (`ChipFlow`) instead of scrolling off the edge; Now/Next put the countdown beside the label so the class name and room get the full tile (two lines if needed); the sidebar's Joe sits just under the window buttons; timeline blocks shrink their label before cutting a word.
- Declutter: Home's Recent is three lines with "All history" (Oct 2026); the sidebar footer is the other candidate.
- Due soon rows show a Start button on hover (Home and Calendar): Joe breaks the deadline into steps and plans the first one tonight (`CalendarFeed.Item.startRequest`). In the notch overview, tapping a deadline does the same.
- Empty states should offer the fix, not just say what's missing: Due soon shows "Link ManageBac" (opens Settings → General via `DashboardModel.openSettings`) until the calendar has synced.
