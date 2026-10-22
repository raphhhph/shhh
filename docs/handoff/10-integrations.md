# 10 · Integrations: music, messages, notes, Mac control, documents

Read `00-common.md` first.

## Scope
Joe acting on other apps and services.

## Files
- `Spotify.swift`: playback via AppleScript, search via the Web API, account login with PKCE (`Account.login`, local callback on port 8888), liked songs. Commands parsed on the Mac (`Spotify.command(in:)`).
- `Messaging.swift`, `WhatsAppLog.swift`: WhatsApp/WeChat reading and sending (always with the approval card).
- Gmail, Google Calendar, Drive and others come from the user's **Claude connectors** (claude.ai) through Claude Code; not available in OpenRouter mode.
- `NoteSaver.swift`, `Notepad.swift`: notes into the Obsidian vault (lecture/meeting/notes folders), grouped in subfolders (lecture: subject; notes: topic; meeting: who, if recurring), picked by the titling call (`describe`, field `group`, reusing existing folders).
- After titling, `onTitled` (AppDelegate) tidies the note in the background: a recorded meeting (5+ speaker lines, 200+ words) keeps its transcript word for word under Summary/Decisions/Actions; everything else of 60+ words is condensed (grouped by topic, filler gone, every fact kept). Joe's Undo keeps the original for a week.
- Opening the notepad: `AppDelegate.isNotepadRequest` (also "open up a notebook" / "a note", what speech recognition heard on 20-21 Oct), voice and typed. Claude's fallback: `Joe --notepad "<words>"` posts a distributed notification the app opens it on.
- `ScreenControl.swift`, `ScreenCapture.swift`, `ScreenContext.swift`, `ScreenPointer.swift`, `FileCommands.swift`, `UndoJournal.swift`, `Workspace.swift` (Vivaldi workspaces): clicking/typing/moving files with undo; blocked apps (password managers, System Settings security panes).
- `Slides.swift` + `Resources/slides.py` (python/node tooling in App Support), `MathDoc.swift` + `Resources/mathdoc.js` (typeset worked solutions), `Textbook.swift` (PDF index/find/text).

## Decisions
- Sending, deleting, submitting, inviting pause for the user's OK; Joe never reads secrets.
- Spotify button never disabled; a second click reopens sign-in; port conflicts named.

## Known issues / to-do
- Spotify for other users: add their emails in the Spotify developer dashboard (dev mode, 25 users) or apply for extended quota.
- Plip-style guided walkthroughs ("show me how to submit on ManageBac" with pointers step by step).
- Undo for desktop tidy-ups everywhere; confirm before risky actions consistently.
