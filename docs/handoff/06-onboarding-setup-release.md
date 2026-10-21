# 06 · Onboarding, setup and release

Read `00-common.md` first.

## Scope
First run for a new user (a friend with the DMG), getting Claude, models and accounts connected, the installer.

## Files
- `Onboarding.swift`: steps **hello, name, models ("Get Joe ready"), tour, school, notes, permissions, claude, connect, tryIt, done**. The tour is narrated by Joe (`narrate`); `ModelsStep` (downloads with progress/Retry), `ClaudeStep` (uses `ClaudeSetup`), `ConnectStep` (ManageBac/Google calendar link, Mac Calendar, Spotify), `SchoolStep` (programme incl. MYP years, subjects by IB group). `Onboarding.snapshot` for `--onboarding-snapshot`.
- `ClaudeSetup.swift`: one button installs Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`, idea from Plip), runs `claude auth login --claudeai`, opens the link, accepts a pasted code, polls `claude auth status`.
- `ModelGuard.swift`: model folders, sizes, status (ready/downloading %/failed), and the **crash guard** (a model loading when Joe died is deleted at the next launch and downloaded again).
- `Profile.swift`, `scripts/build.sh`, `scripts/release.sh`, `Resources/Info.plist`, `Resources/Joe.entitlements`.
- Installer notes: `~/Desktop/Joe Installer/How to install Joe.txt`.

## Decisions
- The voice no longer downloads silently when onboarding opens; the user starts downloads on "Get Joe ready" (beta feedback: a cut-off download crashed Joe).
- Spotify uses PKCE; the app's client ID is copied into the bundle at build time (`SpotifyClientID.txt`) from the developer's Spotify.json. The Spotify app is in development mode: **each tester's Spotify email must be added in the Spotify developer dashboard** (max 25).
- Calendar links (iCal) are read by Joe himself every 30 min; no Claude sync needed.
- `build.sh --install` waits for the old Joe to quit and retries `open` (error -600 left Joe not running).

## Known issues / to-do
- Claude sign-in from scratch is untested (needs a fresh Mac; testing would log Raph out).
- Downloads: resume isn't implemented (a broken download restarts); FluidAudio has partial-download checks for some models only.
- Not signed/notarised: needs an Apple Developer account ($99/yr); `release.sh` supports `JOE_IDENTITY` once there is one.
- Error handling everywhere the network is used: short message + retry (partly done: Spotify, calendar links, models).
