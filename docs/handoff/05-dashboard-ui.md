# 05 · Dashboard UI and design system

Read `00-common.md` first.

## Scope
The dashboard window: pages Home, Calendar, Study, History, Routines, Alarms, Notes, Dictionary, Spotify, Usage, Settings (General, Personality, Automations, Privacy, Advanced); the look.

## Files
- `Dashboard.swift`: `Dashboard` (window), `DashboardModel` (data, `reload()` every 2 s; History.json decoded only when it changes), `DashboardView` (sidebar groups + page), each page struct, `Card`, `PageTitle`, `PillButton`, `ChipButton`, `Choice`, `SubjectGroup` (IB group colours), `Look` (tokens), `Theme`, `AppAppearance`, `PointsCalculator`, snapshot code (`Dashboard.snapshot`).

## Design system (keep it consistent)
- Tokens in `Look`: accent, sidebar, card, page, line, deadline, personal, `titleDesign`. Four **themes** (Settings → General → Style): Classic (orange), Midnight (navy + gold, forces dark), Paper (warm, serif titles), Ocean (blue, rounded). `.id(theme)` on the root redraws on change.
- Cards: 16 pt continuous corners, 1 pt line, 18 pt padding; side-by-side cards use `stretch: true` + `.fixedSize(horizontal: false, vertical: true)` to end level.
- IB subject colours (`SubjectGroup`): language blue, acquisition teal, societies gold, sciences green, maths violet, arts pink, core slate; personal events orange; deadlines red.
- Calendar: tinted blocks with a coloured edge, weekends hidden when empty, alarms as a small line, right rail (details, Due soon, subject key) when wide.
- Verify with `Joe --snapshot <page> file.png 1280 820 [dark]` and look at the image; a tiling script (Swift, AppKit) makes contact sheets.

## Known issues / to-do
- Raph wants it "less default SwiftUI": Settings still uses stock toggles/segmented pickers; History, Alarms, Dictionary, Spotify only lightly restyled.
- "Declutter" (from notes): ask Raph which screen; candidates: Home's Recent, the sidebar footer.
- The window title bar area is empty space at the top of each page.
