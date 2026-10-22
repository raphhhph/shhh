# 06 · Onboarding, setup and release

Read `00-common.md` first.

## Scope
First run for a new user (a friend with the DMG), getting Claude, models and accounts connected, the installer.

## Files
- `Onboarding.swift`: steps **hello, name, models ("Get Joe ready"), tour, connect, school, notes, morning, permissions, claude, tryIt, done**. The step reached is saved (`OnboardingModel.savedStep`, key `onboardingStep`), so a first setup that's quit or crashes reopens there; a replay from Settings starts at Hello. The tour is narrated by Joe (`narrate`); `ModelsStep` (downloads with progress/Retry, a "stuck" warning after 45 s without progress, a free-space warning, and it switches to the China mirror by itself when Hugging Face is unreachable and the mirror isn't, unless the user already chose); `ConnectStep` (ManageBac/Google calendar link first; reads it at once, shows what it found and prefills subjects; Mac Calendar is only offered when there's no link); `SchoolStep` (programme incl. MYP years, subjects by IB group, prefilled from ManageBac); `ClaudeStep` (uses `ClaudeSetup`; once connected, a card links to claude.ai connectors for Gmail/Google Calendar/Drive, and a `BrowserCard` sets up Joe's hidden browser: Get Chrome if none, then `JoeBrowser.prepare()` (downloads its own Node, no Terminal), then `openSignIn()` with a quit-with-⌘Q note; optional, needs PR #14); `PermissionsStep` asks for Microphone and Accessibility (required), Automation of System Events (so alarms and slides don't prompt mid-use), and optional Reminders and Screen Recording, with Settings links when denied; `TryStep` waits for speech recognition (starts it if it never started) instead of letting the key silently do nothing. `Onboarding.snapshot` for `--onboarding-snapshot`.
- `OnboardingSchool.swift`: `CalendarFeed.subjectGuesses()` (subjects from ManageBac task titles, word-boundary matching against the School step's names) and `upcomingDeadlines()`. Once School data's `Item.subject` lands, switch to that.
- `ClaudeSetup.swift`: one button installs Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`, idea from Plip), runs `claude auth login --claudeai`, opens the link, accepts a pasted code, polls `claude auth status`.
- `ModelGuard.swift`: model folders, sizes, status (ready/downloading %/failed), and the **crash guard** (a model loading when Joe died is deleted at the next launch and downloaded again).
- `Profile.swift`, `scripts/build.sh`, `scripts/release.sh`, `Resources/Info.plist`, `Resources/Joe.entitlements`.
- Installer notes: `~/Desktop/Joe Installer/How to install Joe.txt`.

## Decisions
- **Set up once** (Raph, 21 Oct): onboarding asks for each thing once and uses it everywhere; after Done the student has nothing else to set up. One source per kind of data, defaults over questions, show what was found and ask only for corrections. Optional extras (Spotify, messages) are not in onboarding; they connect from the dashboard.
- The voice no longer downloads silently when onboarding opens; the user starts downloads on "Get Joe ready" (beta feedback: a cut-off download crashed Joe).
- Spotify uses PKCE; the app's client ID is copied into the bundle at build time (`SpotifyClientID.txt`) from the developer's Spotify.json. The Spotify app is in development mode: **each tester's Spotify email must be added in the Spotify developer dashboard** (max 25).
- Calendar links (iCal) are read by Joe himself every 30 min; no Claude sync needed.
- `build.sh --install` waits for the old Joe to quit and retries `open` (error -600 left Joe not running).

## Known issues / to-do
- Claude sign-in from scratch is untested (needs a fresh Mac; testing would log Raph out).
- Downloads resume: FluidAudio 0.17.7 streams each file into `<file>.partial` (+ `.partial.etag`) and continues it with a Range request, also across launches; finished files are checked before being moved into place. The crash guard used to delete the whole model folder (and so the partials); now it keeps everything when a `.partial` is there (stopped mid-download) and only deletes when the download had finished (crashed while loading). A hung download can't be restarted from the app (`loadSpeechModel` ignores a second start while one is loading); the stuck warning tells the user to relaunch, which resumes it.
- `MorningStep`: wake-up time and days (school days or every day); on the way forward it adds a repeating "Wake up" alarm (first ring on one of its days, via `Alarm.next(after:)`), unless a repeating "wake" alarm exists. The challenge and morning briefing then work from the first morning.
- `ConnectStep` also takes a timetable photo/screenshot/PDF (plus an optional "today is Day N" for rotating timetables) and calls `Daybook.importTimetable(from:dayToday:)` from School data (PR #10, must merge first).
- Fewer questions: the name is prefilled from the Mac's account name, the school from the ManageBac address (`swis.managebac.cn` → SWIS), and Get Joe ready has an "I speak Chinese too" switch (on by default when the Mac's languages include Chinese and nothing was chosen) that sets `Transcriber.languages` and adds the Chinese downloads.
- `NotesStep` no longer blocks: continuing without a choice makes the Joe folder. `DoneStep` shows what's working (speech, voice, ManageBac, subjects, timetable, wake-up alarm, notes, Gmail) with ticks.
- `ClaudeConnectors.swift`: the connected claude.ai connectors, saved from each `claude -p` session's `system`/`init` message (`mcp_servers`, hooked in `Session.handle`); the Claude step shows "Gmail connected" instead of the button when Gmail is there. Field names unverified on a real Mac.
- Not signed/notarised: needs an Apple Developer account ($99/yr); `release.sh` supports `JOE_IDENTITY` once there is one.
- Error handling everywhere the network is used: short message + retry (partly done: Spotify, calendar links, models).
