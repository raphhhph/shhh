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
- SenseVoice input gets **0.5 s of silence after the speech**, then is padded to **5-second blocks**. This was added for "tonight" coming out as "To" in the nightly test, but it didn't fix that (final nightly ba9e373, 21 Oct). So it's probably SenseVoice mishearing the `say` voice rather than the end being clipped. The padding is harmless, so it stays. The blocks are there because the GPU prepares each new length once (~1 s). Audio over 100 s goes in 90 s pieces.
- While Chinese is still loading, a request waits for it (up to 25 s) rather than Parakeet turning Chinese into made-up English. The transcription timeout is 40 s + length.
- **Parakeet is freed only when nothing runs on it** (`parakeetRunning`). With English + Chinese, `loadChinese` used to call `parakeet.cleanup()` while a Parakeet transcription (the warm-up, live words or an early press) was awaiting on the same actor. That freed GPU buffers mid-prediction and aborted Joe about 6 s after launch (SIGABRT, an MTLReportFailure in MPSGraphTensorData on CoreML's DefaultAsyncPredictionQueue, no Joe frames; reports from 21 and 22 Oct). It now sets `manager = nil` first, waits up to 30 s for running transcriptions to finish, and only then cleans up.
- A speech timeout reloads the model **in the background**; the keys keep working (`reloadSpeechModel`).
- Letting go: only the iPhone's microphone (which delivers audio late, then catches up) is waited for until the audio covers the whole hold. Others that started late (AirPods) get 0.08 s more at most: what they missed at the start never arrives.
- Double-tap (tap then press within 0.45 s) locks recording on until the next tap, max 5 min; shortcuts typed meanwhile are ignored.
- Live words: every 0.9 s the recording so far is transcribed (one at a time) and shown; the final text still comes from the whole recording.
- Spoken alarm commands, study, pen and Spotify are handled on the Mac without Claude (fast, free).

- **IB words are built in** (`Vocabulary.builtInSwaps`, `builtInTerms`): ManageBac by sound, and exact swaps for TOK, CAS, IA, EE, HL/SL, DP1/DP2, MYP, ATL, ESS, Math AA/AI. Applied after the user's own dictionary, and an exact swap the user wrote for the same words wins. Off with the European languages ("cas", "ee" are ordinary words there). Fuzzy matching is kept to ManageBac on purpose: "Turnitin" by sound swallowed "turning in".
- **Spoken layout in dictation** (`SpokenCommands.swift`): "new line", "new paragraph", "new bullet" (or "next …") become a line break, a blank line, or "- ". SenseVoice puts commas around the words ("Friday, new paragraph, I…"), so a comma just before becomes a full stop for a paragraph, disappears for a bullet, and stays for a new line. Punctuation after the words goes. The next letter is capitalised unless the style is Very casual. Only for dictation and the notepad, not for asks or "make it a prompt". There's no setting: it's always on, like the IB words. A sentence that really says "a new line of …" gets broken, which is accepted for now. "Scratch that" / "delete that" takes back the sentence before it, within the same recording (it can't reach text typed earlier). It runs after the breaks are made and stops at a line break, so it can't eat an earlier paragraph. Before 22 Oct it ran first and could. A bullet keeps its "- ".
- **Stutter repair** (`Vocabulary.withoutStutters`, runs first in `apply`): SenseVoice sometimes writes the end of a word twice ("knowledgege", "internalnal"). If a word ends in a repeated piece of 2 to 4 letters, isn't a word, and becomes one without the repeat, the repeat goes. Likely cause, not yet confirmed: the encoder runs on the GPU in fp16, so a blank frame flickers between two frames of the same token and the CTC collapse keeps both. Worth comparing with `.cpuOnly` on the Mac.
- Live words go through the dictionary too, so the caption already reads "ManageBac", like the final text.

## Measuring dictation
- `Joe --dictation-test [say voice]`: ten IB sentences spoken by `say`, transcribed, put through dictation, and scored as the word error rate before and after Joe's fixes, plus whether the line breaks came out right. Temp audio is deleted. Run it before and after any change to speech, the dictionary or the spoken commands.
- `Joe --dictate "<heard>"`: what dictation would type for a transcript. `--transcribe` now also prints the dictated text when it differs from what was heard.
- Built-in swaps also cover letters spelled out one by one ("h l", "e e", "m y p", "math a a").

- First run on the installed nightly (21 Oct, English + Chinese, `say` voice), with raw SenseVoice output: ManageBac came through as "manage back" (the dictionary fixes it), and TOK, DP1, EE, HL/SL and Math AA were right. Misses: "essay" became "SA", "kass" became "CA", "MYP" became "MP", and "tonight" was cut to "To." at the end of one clip. - Nightly 12d1320 `--dictation-test`: word error rate 25.3% heard and 4.6% after Joe's fixes, with line breaks right 10 of 10. Then fixed: ManageBac fuzzy matching swallowed the next word ("manage back To" became "ManageBac"), because the longest span was tried first; now the fewest words are tried first and an exact match stays as it is. "CA" and "MP" are now fixed only when the next word gives them away ("CA hours", "MP coordinator"). "essay" heard as "SA" is still open.

## Audit (21 Oct 2026) and plan
Goal: a student talks and gets the right words with nothing to set up.
- Done: built-in IB words; live words spelled like the final text; the Dictionary page says IB words are built in; spoken "new line / new paragraph / new bullet" and "scratch that" in dictation (for essays and notes).
- Dropped: **streaming words to Claude while talking**. Claude Code takes a user message as a whole turn, so sending half a sentence would start an answer to the wrong question. Joe already starts the Claude session the moment right ⌥ goes down, which is the part that saves time.
- Looked at and skipped: names from the timetable (it holds subjects and rooms, not teachers); names from Contacts (a new permission prompt, which goes against "nothing to set up").
- Next: add the student's teachers' and classmates' names from the timetable / ManageBac feed to the dictionary automatically (needs `08-school-data-calendar`); measure the ManageBac fix with `--transcribe` on recordings of "ManageBac".

## Apple's speech service at 25 GB (22 Oct): not Joe
- Raph's Activity Monitor showed `com.apple.SpeechRecognitionCore.speechrecognitiond` at 25 GB. It was diagnosed on the Mac: the daemon had been up for **41 days**, its footprint was 21 GB of MALLOC_TINY plus 4 GB of MALLOC_NANO (a slow leak of small allocations), and its activity was "Activating Grammar" from `com.apple.speech.dictationservices`. That's macOS Dictation or Voice Control, not Joe. Hey Joe (`wakeWord`) was **off**, and Joe has no NSSpeechRecognizer. Fix: restart the Mac, or `killall com.apple.SpeechRecognitionCore.speechrecognitiond` (launchd starts it again on demand). If it grows again, check System Settings → Keyboard → Dictation and Accessibility → Voice Control.
- Hardening anyway (commit 7509346, not compiled yet): `WakeWord` used to keep an on-device recognition session going all day, restarting it every 50 s and right after any end. Now it keeps only the microphone tap and its level (about -40 dBFS). A session starts on sound, with 1.5 s of pre-roll, and ends after 3 s of quiet or 30 s. Failures back off from 5 s up to 5 min.

## Morning status (22 Oct, after the overnight rounds)
- Final nightly ba9e373 (all of PR #2): 5 clean launches with no new crash reports, so the Parakeet cleanup fix held. `--dictation-test`: 25.3% word errors heard, 2.3% after Joe's fixes, line breaks 10 of 10.
- Still wrong: "essay" heard as "SA" (line 1), and "tonight" heard as "To" (line 4). Both are SenseVoice on a machine voice. Next, try them with a real voice, and compare the encoder on `.cpuOnly` against the GPU for accuracy (stutters and dropped words).
- Nobody has spoken into it yet. Raph should test dictation by voice: IB words, "new paragraph", "new bullet", "scratch that".

## Known issues / to-do
- Built-in IB words built fine (240d3ec) but are not tested by speaking yet (written in a cloud thread). Check on the Mac: `swift build -c release`, then Dashboard → Dictionary → Try it with "check manage back for my tok and cas deadlines, hl math ai".
- Live words haven't been tested by speaking (no mic access for the agent).
- Option: let users pick Parakeet for English even with Chinese on (accuracy vs 1.2 GB).
