# 04 · The notch, the answer card and on-screen overlays

Read `00-common.md` first.

## Scope
Everything Joe draws over other apps: the resting notch band, the recording pill, the answer card, the side-notch task shelf, the hover overview, toasts, the greeting, live words, the screen pen, the screen pointer.

## Files
- `Notch.swift`: `Notch` (geometry, `screenUnderMouse`), `NotchPanel`, `NotchSpace` (pins panels to every Space via a private CGS API), `RestingNotch` (the black band with the sparkle, `ignoresMouseEvents`), `NotchGreeting`.
- `NotchOverview.swift`: hover overview (NotchNook-style). Polls the pointer every 0.15 s; opens after 0.35 s on the notch while Joe is idle; widgets clock, next class (tomorrow's first in the evening), due soon, today's five, Joe's tasks, next alarm, now playing; order/selection in Settings (`notchWidgets`). Data from `DashboardModel`.
- `AnswerPanel.swift`: the card (status steps, plan checklist, approval cards, reply). `MarkdownText` renders headings, lists, numbered lists, checklists, quotes, code, tables, rules.
- `RecordingPanel.swift` (pill), `LiveCaption.swift`, `TaskShelf.swift` (background tasks capsule), `Toast.swift`, `ScreenPen.swift` (draw over the screen; "Ask Joe about this" sends a screenshot), `ScreenPointer.swift` (point tags on screen from Claude's replies).

## Decisions
- Panels are recreated each time (a reused window could stay hidden behind full-screen apps) and pinned with `NotchSpace`.
- Two monitors: the alarm card measures its content (`fittingSize` before `sizingOptions = []`), or it grew onto the monitor above.
- The overview never opens while recording, with the answer card up, an alarm ringing, or the pen open.

## Known issues / to-do
- Overview widgets: reorder is "Move left" in a menu; a drag-to-arrange editor (iPhone home-screen style) is the next step; more widgets (quick ask, weather, focus timer, study streak).
- The overview and pen haven't been tried by hand (no screen access for the agent); check on Raph's built-in display + ultrawide setup.
- `Joe --overview-preview`, `--alarm-preview` draw them off screen.
