# 01 · Voice input: keys, recording, speech recognition

Read `00-common.md` first.

## Scope
Everything from a key press to text: hotkeys, double-tap lock, "Hey Joe" hands-free, recording, noise filter, voiceprint, speech recognition (English/Chinese/European), live words, dictation styles and the dictionary, "make it a prompt".

## Files
- `HotkeyMonitor.swift`: right ⌘ (dictate) and right ⌥ (ask) via global/local NSEvent monitors; a missed-release watchdog.
- `AppDelegate.swift`: `startRecording`, `finishRecording`, `cancelRecording`, double-tap lock (`locked`, `lastTap`, `unlock`), `startHandsFree` (Hey Joe), live words (`startLiveWords`), the routing after transcription (alarms, study, pen, Spotify, dismiss, then Claude).
- `AudioRecorder.swift`, `AudioDevices.swift`: capture at 16 kHz; `tail(recording, seconds:)` for partial audio.
- `Transcriber.swift`: `Transcriber` actor. Languages (Settings): english (Parakeet v2), european (Parakeet Redux), chinese (English + Chinese). `NoiseFilter` (LocalVQE), `ModelDownloads` (China mirror).
- `WakeWord.swift` (Hey Joe + `EndListener`), `VoicePrint.swift` (CampPlus; keeps only the user's voice in hands-free).
- `LiveCaption.swift`: words under the pill while talking. `PromptPolish.swift`: "…make it a prompt". `WritingStyle.swift`, `TextCleaner.swift` (local llama cleanup, optional), `Vocabulary.swift` (the user's dictionary), `TextInserter.swift`.

## How it works (decisions)
- Speech models run on the **GPU** (`.cpuAndGPU`), not the Neural Engine: after each new build macOS recompiled ANE models for minutes and the keys were dead. Parakeet on the GPU costs ~1.3 GB, so with **English + Chinese** on, **SenseVoice hears everything** once loaded and **Parakeet is unloaded** (SenseVoice was about as accurate on English in tests). Parakeet only covers the first ~10 s after launch. English-only users keep Parakeet.
- SenseVoice input is padded to **5-second blocks** (the GPU prepares each new length once, ~1 s). Audio over 100 s goes in 90 s pieces.
- While Chinese is still loading, a request waits for it (up to 25 s) rather than Parakeet turning Chinese into made-up English. The transcription timeout is 40 s + length.
- A speech timeout reloads the model **in the background**; the keys keep working (`reloadSpeechModel`).
- Double-tap (tap then press within 0.45 s) locks recording on until the next tap, max 5 min; shortcuts typed meanwhile are ignored.
- Live words: every 0.9 s the recording so far is transcribed (one at a time) and shown; the final text still comes from the whole recording.
- Spoken alarm commands, study, pen and Spotify are handled on the Mac without Claude (fast, free).

- **IB words are built in** (`Vocabulary.builtInSwaps`, `builtInTerms`): ManageBac by sound, and exact swaps for TOK, CAS, IA, EE, HL/SL, DP1/DP2, MYP, ATL, ESS, Math AA/AI. Applied after the user's own dictionary, and an exact swap the user wrote for the same words wins. Off with the European languages ("cas", "ee" are ordinary words there). Fuzzy matching is kept to ManageBac on purpose: "Turnitin" by sound swallowed "turning in".
- Live words go through the dictionary too, so the caption already reads "ManageBac", like the final text.

## Audit (21 Oct 2026) and plan
Goal: a student talks and gets the right words with nothing to set up.
- Done: built-in IB words; live words spelled like the final text; the Dictionary page says IB words are built in.
- Dropped: **streaming words to Claude while talking**. Claude Code takes a user message as a whole turn, so sending half a sentence would start an answer to the wrong question. Joe already starts the Claude session the moment right ⌥ goes down, which is the part that saves time.
- Next: add the student's teachers' and classmates' names from the timetable / ManageBac feed to the dictionary automatically (needs `08-school-data-calendar`); measure the ManageBac fix with `--transcribe` on recordings of "ManageBac".

## Known issues / to-do
- Built-in IB words are not compiled or tested yet (written in a cloud thread). Check on the Mac: `swift build -c release`, then Dashboard → Dictionary → Try it with "check manage back for my tok and cas deadlines, hl math ai".
- Live words haven't been tested by speaking (no mic access for the agent).
- Option: let users pick Parakeet for English even with Chinese on (accuracy vs 1.2 GB).
