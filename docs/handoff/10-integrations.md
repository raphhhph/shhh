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
- `BrowserTabs.swift`: `Joe --tab open|list|find|show`: pages open in the default browser in the background (`activates = false`), tabs read and switched by Chrome-style AppleScript (Vivaldi, Chrome, Brave, Edge, Arc; not Safari). The prompt sends "open my ManageBac" and the like here instead of the Chrome tools or clicks. First use asks once for Automation permission per browser. `--tab read|fill|click` works inside a page the user has open: JavaScript through AppleScript (`execute tab … javascript`), which needs the browser's "Allow JavaScript from Apple Events" (Vivaldi: Tools menu; Chrome: View > Developer); Chrome-family browsers get it ticked through System Events the first time it's refused; Vivaldi has no menu item, so `--tab allow-js Vivaldi` (always asks) quits it, sets `browser.allow_javascript_apple_events` in its Preferences (backup `Preferences.joe-backup`), reopens it and reopens any tabs that didn't come back. `read` tags elements with `data-joe` uids (`uid=t12 button "Add Entry"`), quotes the page text with "| "; ToolPolicy.tabAction judges fill/click by the remembered label (money blocked, submit/send/add/save buttons ask).
- `JoeBrowser.swift`: Joe's hidden browser. Chrome DevTools MCP (`chrome-devtools-mcp`, installed by `Joe --browser setup` or onboarding's `JoeBrowser.prepare()` into `~/Library/Application Support/Shhh/browser`; with no Homebrew Node it first downloads Node v22.20.0 from nodejs.org into `browser/node`, checked against a pinned SHA-256) runs headless Chrome on its own profile (`.../Shhh/Joe browser profile`). Not Vivaldi: driven hidden it never loads a page (28 Oct test, 40 s, nothing). Without Chrome, Brave or Edge, setup downloads Chrome for Testing with @puppeteer/browsers into `.../Shhh/browser/chrome` and trashes the old Vivaldi-made `Browser profile`. In Hands-off, submit/add/save on ManageBac CAS pages (`JoeBrowser.isUngraded`) goes ahead without the card; graded pages still ask, passed to each Session with `--mcp-config` (not the tutor). `Joe --browser signin` opens that profile in a normal window to sign in once; it has to be quit after, since a profile can't be open twice. ToolPolicy's `joeBrowser` allows reading and navigating; clicks and typing are judged by the element label from the last snapshot (`uid=… button "Submit"`, remembered in `noteCreations`): money is blocked, submit/send asks, unnamed clicks ask, careful mode always asks. `upload_file` and `evaluate_script` always ask.
- `Slides.swift` + `Resources/slides.py` (python/node tooling in App Support), `MathDoc.swift` + `Resources/mathdoc.js` (typeset worked solutions), `Textbook.swift` (PDF index/find/text).

## Decisions
- Sending, deleting, submitting, inviting pause for the user's OK; Joe never reads secrets.
- Spotify button never disabled; a second click reopens sign-in; port conflicts named.

## Known issues / to-do
- Spotify for other users: add their emails in the Spotify developer dashboard (dev mode, 25 users) or apply for extended quota.
- Plip-style guided walkthroughs ("show me how to submit on ManageBac" with pointers step by step).
- Undo for desktop tidy-ups everywhere; confirm before risky actions consistently.
