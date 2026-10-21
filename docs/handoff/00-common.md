# Joe — shared context for every chat (read this first)

Joe is a voice assistant for the Mac, built for IB Diploma (and MYP) students. It lives at the notch: hold **right ⌘** to dictate anywhere, hold **right ⌥** to ask Joe (Claude) anything, and Joe acts on the Mac, the student's notes, calendar, ManageBac, Spotify, messages. A dashboard window holds Home, Calendar, Study, History, Routines, Alarms, Notes, Dictionary, Spotify, Usage and Settings.

Owner: **Raph** (Raphael Pasaribu), IB DP1 student at SWIS Shenzhen, building Joe as a product (see `11-business-and-roadmap.md`).

## Repo, build, ship
- Repo: `~/Desktop/Code/shhh`, branch **`ask-claude`**. Push to remote **`fork`** (github.com/raphhhph/shhh, public). **Never push to `origin`** (the upstream "Shhh" project by Tibophlp; Joe is a fork).
- Swift package, macOS 14+, Apple Silicon. Product/executable name `Shhh` (the app's old name); the app bundle is **Joe.app**, bundle id `io.github.tibophlp.shhh`. Settings live in `UserDefaults` for that bundle id (the dev binary `.build/release/Shhh` uses the domain `Shhh` instead).
- Build: `swift build -c release` (≈45–100 s). App bundle: `./scripts/build.sh` → `build/Joe.app`. Install and relaunch: `./scripts/build.sh --install`.
- **Before installing, check Joe is idle**: `pgrep -f 'claude -p --input-format stream-json'` then `ps -o %cpu= -p <pid>`; a busy Claude session (CPU > ~1%) is a request in progress, which an install kills.
- Installer for testers: `./scripts/release.sh` → `build/Joe.dmg` (unsigned; testers use Privacy & Security → Open Anyway), copied to `~/Desktop/Joe Installer/Joe.dmg` with `How to install Joe.txt` beside it. Rebuild it when shipping to testers.
- Commit messages: a one-line summary, a blank line, what and why in plain words; end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit and push after each shipped change.
- After every install, macOS recompiles Neural Engine models for the new build (the TTS voices, noise filter, voiceprint); speech recognition uses the GPU so the keys work ~15 s after launch. Don't install repeatedly while Raph is using Joe.

## Raph's preferences and standing rules
- Plain, short replies; say what was done and how to test it. No emojis anywhere (app or chat).
- He's impatient with long silences: give a one-line status when a step will take a while.
- Polished, non-generic UI. Verify visually with the snapshot commands before saying a UI is done.
- **Never delete permanently**: move to the Trash (`mv … ~/.Trash/`). Caches the app regenerates are the exception.
- Never print or commit secrets: Spotify keys (`~/Library/Application Support/Shhh/Spotify.json`, 0600), API keys (`API.json`, 0600). The Spotify client ID is copied into the app at build time, never into git.
- Never send messages/emails without the approval card; never type passwords; never spend money.
- Usage is limited (Claude plan): keep tool output small, batch edits, avoid re-reading big files.

## Architecture (where to look)
- `AppDelegate.swift` (≈2000 lines): the hub. Hotkey → recording → transcription → dictation or ask; alarms, routines, the notch, background tasks, the morning briefing, wiring of every feature. Search for the feature's name.
- `Assistant.swift`: Claude Code sessions (`Session` runs `claude -p --input-format stream-json`), the system prompt (`systemPrompt`), model routing (`needsStrongModel`), tool permissions (`ToolPolicy`).
- `Dashboard.swift` (≈3100 lines): every dashboard page, the design tokens (`Look`, `Theme`), Settings.
- `Onboarding.swift`, `AnswerPanel.swift` (the card at the notch), `Notch.swift`, `SpeechOutput.swift`, `Transcriber.swift`, `StudyBoard.swift`, `Alarms.swift`, `CalendarFeed.swift`, `Daybook.swift`, `Spotify.swift`, `CommandLineTool.swift` (test commands).
- Models: FluidAudio 0.17.7 (Parakeet and SenseVoice speech recognition, PocketTTS and Kokoro voices, LocalVQE noise filter, CampPlus voiceprint). `ModelGuard.swift` tracks downloads.
- The brain is the user's own **Claude Code** CLI signed in to their Claude plan (or an API key, or OpenRouter / a custom Anthropic-compatible endpoint). Joe never calls the Anthropic API directly except through `claude`.

## Data on disk
- `~/Library/Application Support/Shhh/`: History.json, Usage.jsonl, Alarms.json, Dictionary.txt, Assistant instructions.md, Spotify.json, API.json, Calendar links.json, Look.json, Undo/, node/ and python/ (slide tooling), Quiz log (or in the notes vault).
- Models: `~/Library/Application Support/FluidAudio/Models/` (Parakeet, SenseVoice, LocalVQE, CampPlus) and `~/.cache/fluidaudio/Models/` (PocketTTS, Kokoro).
- Raph's notes vault: `~/Desktop/Second-Brain` (Obsidian; `Brain/` is Claude's memory of him, `Brain/School/`, `Brain/Daybook.md`, `Brain/_files/School/<subject>/` for PDFs, calendar.json, timetable.json). Joe's product notes: `Brain/Ventures/Joe/`.

## Test without the screen (CLI on the app binary)
Run `build/Joe.app/Contents/MacOS/Joe <command>` (uses the app's settings):
- `--ask "<request>" ["<follow-up>"…]` a real request, timed. `--study "<subject>" "<request>" "<answer or @image>"…` a whiteboard session.
- `--snapshot <page> <file.png> [w h] [dark]`, `--onboarding-snapshot <step> <file.png>`, `--board-preview <file.png> [sketch]`, `--overview-preview <file.png>`, `--alarm-preview <file.png> [missed]`: draw UI off screen (Raph declined screen control; use these).
- `--route "<request>"…` which model/feature handles it. `--transcribe <wav>…` speech timing. `--speech-parts "<text>"` which voice reads what. `--challenge [seed] ["answer"]` wake-up challenge check. `--prompt "<…make it a prompt>"`. `--calendar-link add|refresh|parse`. `--memory-test`. `--system-prompt`. `--alarm at +1 "Wake up (test)"` sets a real alarm.
- Make test audio with `say -o file.wav --data-format=LEI16@16000 "…"` (`-v Tingting` for Chinese).

## Handoff files
`01-voice-input` · `02-voice-output` · `03-assistant-core` · `04-notch-and-card` · `05-dashboard-ui` · `06-onboarding-setup-release` · `07-study` · `08-school-data-calendar` · `09-alarms-routines-automations` · `10-integrations` · `11-business-and-roadmap`. Each lists its files, how it works, decisions already made, known issues and the to-do. Update your area's file when you change something.
