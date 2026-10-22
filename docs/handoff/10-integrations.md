# 10 · Integrations: music, messages, notes, Mac control, documents

Read `00-common.md` first.

## Scope
Joe acting on other apps and services.

## Files
- `Spotify.swift`: playback via AppleScript, search via the Web API, account login with PKCE (`Account.login`, local callback on port 8888), liked songs. Commands parsed on the Mac (`Spotify.command(in:)`).
- `Messaging.swift`, `WhatsAppLog.swift`: WhatsApp/WeChat reading and sending (always with the approval card).
- Gmail, Google Calendar, Drive and others come from the user's **Claude connectors** (claude.ai) through Claude Code; not available in OpenRouter mode.
- `NoteSaver.swift`, `Notepad.swift`: notes into the Obsidian vault (lecture/meeting/notes folders).
- `ScreenControl.swift`, `ScreenCapture.swift`, `ScreenContext.swift`, `ScreenPointer.swift`, `FileCommands.swift`, `UndoJournal.swift`, `Workspace.swift` (Vivaldi workspaces): clicking/typing/moving files with undo; blocked apps (password managers, System Settings security panes).
- `BrowserTabs.swift`: `Joe --tab open|list|find|show`: pages open in the default browser in the background (`activates = false`), tabs read and switched by Chrome-style AppleScript (Vivaldi, Chrome, Brave, Edge, Arc; not Safari). The prompt sends "open my ManageBac" and the like here instead of the Chrome tools or clicks. First use asks once for Automation permission per browser.
- `JoeBrowser.swift`: Joe's hidden browser. Chrome DevTools MCP (`chrome-devtools-mcp`, installed by `Joe --browser setup` into `~/Library/Application Support/Shhh/browser`) runs headless Chrome on its own profile (`.../Shhh/Browser profile`), passed to each Session with `--mcp-config` (not the tutor). `Joe --browser signin` opens that profile in a normal window to sign in once; it has to be quit after, since a profile can't be open twice. ToolPolicy's `joeBrowser` allows reading and navigating; clicks and typing are judged by the element label from the last snapshot (`uid=… button "Submit"`, remembered in `noteCreations`): money is blocked, submit/send asks, unnamed clicks ask, careful mode always asks. `upload_file` and `evaluate_script` always ask.
- `Slides.swift` + `Resources/slides.py` (python/node tooling in App Support), `MathDoc.swift` + `Resources/mathdoc.js` (typeset worked solutions), `Textbook.swift` (PDF index/find/text).

## Decisions
- Sending, deleting, submitting, inviting pause for the user's OK; Joe never reads secrets.
- Spotify button never disabled; a second click reopens sign-in; port conflicts named.

## Known issues / to-do
- Spotify for other users: add their emails in the Spotify developer dashboard (dev mode, 25 users) or apply for extended quota.
- Plip-style guided walkthroughs ("show me how to submit on ManageBac" with pointers step by step).
- Undo for desktop tidy-ups everywhere; confirm before risky actions consistently.
