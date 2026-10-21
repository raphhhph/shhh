# 10 · Integrations: music, messages, notes, Mac control, documents

Read `00-common.md` first.

## Scope
Joe acting on other apps and services.

## Files
- `Spotify.swift`: playback via AppleScript, search via the Web API, account login with PKCE (`Account.login`, local callback on port 8888), liked songs. Commands parsed on the Mac (`Spotify.command(in:)`).
- `Messaging.swift`, `WhatsAppLog.swift`: WhatsApp/WeChat reading and sending, iMessage sending (always with the approval card). iMessage goes through Messages' AppleScript: the name is matched among Messages' participants (named from Contacts) and sent only on exactly one match; phone numbers and emails go straight through. Messages can't take a draft, so draft/open just opens the chat. Reading iMessage (chat.db, needs Full Disk Access) is not done yet.
- Gmail, Google Calendar, Drive and others come from the user's **Claude connectors** (claude.ai) through Claude Code; not available in OpenRouter mode.
- `NoteSaver.swift`, `Notepad.swift`: notes into the Obsidian vault (lecture/meeting/notes folders).
- `ScreenControl.swift`, `ScreenCapture.swift`, `ScreenContext.swift`, `ScreenPointer.swift`, `FileCommands.swift`, `UndoJournal.swift`, `Workspace.swift` (Vivaldi workspaces): clicking/typing/moving files with undo; blocked apps (password managers, System Settings security panes).
- `Slides.swift` + `Resources/slides.py` (python/node tooling in App Support), `MathDoc.swift` + `Resources/mathdoc.js` (typeset worked solutions), `Textbook.swift` (PDF index/find/text).

## Decisions
- Sending, deleting, submitting, inviting pause for the user's OK; Joe never reads secrets.
- Spotify button never disabled; a second click reopens sign-in; port conflicts named.
- Spotify for other users (21 Oct 2026): since Feb 2026 a development-mode Spotify app allows only 5 allow-listed users and needs a Premium owner; extended quota is for businesses only. So: "play X" without search (no app secret and no sign-in on that Mac) goes to Claude, which finds the open.spotify.com link with WebSearch and runs `--spotify "play <link>"` (`Spotify.quick`, `.playLink`). Liked songs and playlists stay for allow-listed testers (Spotify developer dashboard, User Management). A sign-in from an account not on the list gets a 403 on /me: Joe says so and keeps no token.
- Guided walkthroughs (21 Oct 2026): "show me how…", "walk me through…", "step by step" set `AssistantTask.walkthrough`. Claude gives one "Step N" per reply with one [POINT], never clicks; "next", "done", "what now" (`ScreenCapture.isNextStep`) send a fresh screenshot for the next step, and in a walkthrough "next" is never Spotify's next track.  Finished walkthroughs are saved as notes in the vault's `Walkthroughs/` (`Assistant.walkthroughNotes`) and read first next time.

## Known issues / to-do
- Spotify: test keyless play on a Mac with no Spotify.json (time from request to music); allow-list up to 5 testers.
- Guided walkthroughs: try "show me how to submit on ManageBac" then "next" by hand; a step card with Next/Stop at the notch would beat saying "next".
- Undo for desktop tidy-ups everywhere; confirm before risky actions consistently.
