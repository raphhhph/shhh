# 02 · Voice output: Joe's voices

Read `00-common.md` first.

## Scope
Text to speech: Alba (English), the Mandarin voice, the Mac's voices for other scripts, speaking replies as they stream, the morning briefing, the onboarding narration, the study board reading questions, memory use of the voices.

## Files
- `SpeechOutput.swift`: `SpeechOutput` (queue, sentence splitting, language routing, `update`/`finish` streaming API, `trimMemory`, `prepareMandarin`), `NeuralVoices` (PocketTTS "alba" and Kokoro Mandarin `zf_001`), `VoicePlayer`.
- Callers: `AppDelegate` (replies, greetings, narration, "one sec" acknowledgement, study board speak).

## How it works (decisions)
- Engine is On (Alba) / Off. Alba = PocketTTS (Kyutai), chosen by Raph; Kokoro English, Chatterbox, Apple options removed.
- Alba **streams** audio frames (~0.25 s chunks): first sound ~0.2 s after a sentence completes.
- Routing per sentence: any Han characters → split into runs: Chinese runs to Kokoro Mandarin with numbers converted (`chineseNumbers`: 08:30 → 八点三十, 2.5% → 百分之二点五; **match `[0-9]`, never `\d`**, which matches 八 and 零 and looped forever); Latin runs (AI HL, Paper 3) to Alba. Other scripts (Cyrillic, Korean…) → the Mac's voices. Latin text never goes to a Mac voice (that caused "Russian" readings).
- Tables, code blocks and heading marks are dropped from speech (`speakable`). "e.g.", "i.e.", "etc.", "vs." are said in full (their dots also cut sentences early).
- Maths, science and units are said the way a teacher would (`spokenMaths`, Alba's sentences only): x² → "x squared", 10⁻⁴ → "10 to the power of minus 4", dy/dx, f'(x), √, ≤ ≈ ± × ÷ →, LaTeX (`$…$`, `\frac`, `\sqrt`, `\int_a^b`), units after a number (m/s², mol dm⁻³, kJ/mol, °C, cm³; single-letter units like "5 m" only with a space), formulas symbol by symbol (6CO₂ → "6 C O 2"), $5 → "5 dollars". "6/7" outside maths → "6 out of 7" (a date like 21/10 is left alone); bare number fractions are "over" only in a maths sentence, and " - " is "minus" only there. Check with `Joe --speech-parts "<text>"`, which prints what Alba is given.
- Sentences already waiting when Alba is free are said together in one go (under 160 characters, English only), so intonation carries across them with no gap; the first sentence of a reply never waits for the next. Emoji are dropped from speech. Clock times are said naturally ("08:30" → "8:30", "9:00 AM" → "9 AM", "9:00" → "9 o'clock").
- Mac-voice lines (other languages, and the fallback when Alba fails) wait their turn in the same queue, so two voices never talk at once.
- At launch, Alba (and the "One sec." clip) loads only after SenseVoice's warm-up (polls `chineseReady`, at most 90 s), then the noise filter: several models starting on the GPU at once aborted in Metal after installs. Can switch to voice input's `Transcriber.waitUntilWarmedUp()` once that's merged.
- Holding the ask key (right ⌥) warms Alba up (`warmUp`), so the reload after an idle unload happens while the user talks. Concurrent loads share one load (`loadingEnglish`).
- Short lines (≤ 40 characters: "One sec.", "Checking your calendar.") are kept as audio after the first time (up to 40, `clips`, survives the idle unload), so they play instantly. "One sec." is made when the voice first loads (`prepare`), so even the first one is instant.
- The first sentence of a reply starts at its first comma when that comes after 6+ words, instead of waiting for the full stop.
- "Read this to me" / "read it out loud" (spoken to Joe, `readAloud` in AppDelegate): the selected text, or the front window's text when nothing is selected (not browsers), read in full by Alba with no Claude call. A key press stops it. If there's nothing to read, a toast says to select text.
- Speed (Voice menu: Normal / A bit faster / Fast = 1, 1.15, 1.3) via `AVAudioUnitTimePitch` (no pitch change) and the Mac voice's rate. Setting `voiceSpeed`.
- Voices unload after **10 quiet minutes** (~800 MB) and reload with the next sentence. If a voice fails or isn't downloaded, that sentence is said by the Mac's voice.
- After 2.5 s of silence from Claude on a spoken request, Joe says the status ("Checking your calendar.") or "One sec." once (`acknowledgeIfSlow`).
- Spoken progress while working (`narrate` in AppDelegate, `spokenStatus`, `announce`): on a spoken request, each new status Claude reports is said as a short line ("Opening Gmail.", "Clicking the Compose button.", "Writing a draft.") so long browser, email and routine tasks never go quiet. At most one every 5 s, none in the first second, never the same line twice, up to 6 per request, never over speech already playing, and only "…ing" steps (orders like "Click X" and Chrome's summaries like "Opens X" become "Clicking X", "Opening X"; "Working…", "Thinking…", "Using Chrome…", scrolling, waiting, screenshots and page reads stay quiet). A routine's plan step is said as it starts ("Checking ManageBac for anything due."), email addresses are said as the name in them ("to Pat Lee"), short site names in capitals ("Opening BBC"), underscores as spaces. Check lines with `Joe --status-line "<status>"`.

## Known issues / to-do
- The Oct 2026 audit changes (maths speech, queue order, warm-up, clips, first comma, speed) are written but were made off the Mac: build and listen before trusting them. Test lines: `Joe --say "Find dy/dx when y = 3x² + 2x − 5."`, `Joe --speech-parts "The speed is 3.2 × 10⁻⁴ m/s² after 5 s."`, then ask Joe something after 10 idle minutes and check the first sentence isn't late.
- How Alba says letters (HL, SL, IA, TOK, CO₂) is untested by ear; add spellings to `spokenMaths` if she gets them wrong.
- A Chinese sentence gets `spokenMaths` only when it has maths symbols (`mathsInChinese`), so the maths reaches Alba in English words; otherwise numbers, times and % stay with `chineseNumbers`. Saying the maths in Mandarin (等于, 的平方) is a possible next step.
- Speaking before the answer exists: done as the acknowledgement; true early speech needs input streaming (see 01).
- Branch `wip-voice-samples` (an uncompiled `--voice-samples` comparison) predates choosing Alba; it can be dropped.
- Ideas: a per-subject pronunciation list; "read the next paragraph" / pause and resume for long read-alouds.
