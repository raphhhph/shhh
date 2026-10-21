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
- Tables, code blocks and heading marks are dropped from speech (`speakable`).
- Voices unload after **10 quiet minutes** (~800 MB) and reload with the next sentence. If a voice fails or isn't downloaded, that sentence is said by the Mac's voice.
- After 2.5 s of silence from Claude on a spoken request, Joe says the status ("Checking your calendar.") or "One sec." once (`acknowledgeIfSlow`).

## Known issues / to-do
- First sentence after an idle unload takes 1–2 s longer (reload).
- Speaking before the answer exists: done as the acknowledgement; true early speech needs input streaming (see 01).
- Plan items: pre-rendered instant acknowledgements (no synthesis delay), speak the first clause at the first comma.
