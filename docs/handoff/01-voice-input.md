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
- Letting go: only the iPhone's microphone (which delivers audio late, then catches up) is waited for until the audio covers the whole hold. Others that started late (AirPods) get 0.08 s more at most: what they missed at the start never arrives.
- Double-tap (tap then press within 0.45 s) locks recording on until the next tap, max 5 min; shortcuts typed meanwhile are ignored.
- Live words: every 0.9 s the recording so far is transcribed (one at a time) and shown; the final text still comes from the whole recording.
- Spoken alarm commands, study, pen and Spotify are handled on the Mac without Claude (fast, free).

## Known issues / to-do
- **Input streaming to Claude** (send words while still talking so Claude starts early) isn't built; live words are display only.
- ManageBac is misheard by both models ("Manage BO", "manageBok"); the dictionary fixes known spellings after transcription.
- Live words haven't been tested by speaking (no mic access for the agent).
- Option: let users pick Parakeet for English even with Chinese on (accuracy vs 1.2 GB).
