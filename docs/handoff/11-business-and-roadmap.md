# 11 · Business, beta and roadmap

Read `00-common.md` first.

## Where things stand (22 Oct 2026)
- Beta: Raph, his brother, and Landon (first outside tester, 21 Oct). DMG in `~/Desktop/Joe Installer`.
- Product notes in the vault, `Brain/Ventures/Joe/`: **Joe — Plan** (business plan, decided: the paid product signs in with a Joe account with AI built in, server-side key, metering), **Joe — My to-do**, **Joe — Beta feedback (Landon) 2026-10-21**, **Joe — Night session 2026-10-21** (what shipped, audit), China decision memo, Competitor map, IB-coded plan, Billing design, Hugging Face audit, Chinese speech options.
- Inspirations reviewed: **Plip** (open-source notch assistant: Claude install in onboarding, walkthroughs, confirm risky actions), **Vovy** (prompt rewriting → "make it a prompt"), **NotchNook** (hover overview → done), **OpenClaw** (subscription-powered agent).

## Beta feedback status (Landon, 21 Oct)
- Crash on a cut-off download → **done** (Get Joe ready step, crash guard, Mac-voice fallback).
- Notch overview with widgets → **done** (customising via menu; drag editor to do).
- Custom API endpoints → **Anthropic-compatible done**; OpenAI-compatible via OpenRouter/LiteLLM; native OpenAI needs the Codex engine.
- ChatGPT subscription → **to do** (Codex CLI engine; check OpenAI terms before charging).

## Roadmap (suggested order)
1. Next beta DMG (1–2 weeks): resumable downloads, network error messages everywhere, ask Landon to retest offline.
2. Codex CLI engine (ChatGPT plan) behind a provider switch.
3. Widgets editor (drag to arrange), more widgets.
4. Study: more subject packs, past-paper importer, spaced repetition, maths rendering.
5. Joe accounts + server (sign in, our key, per-account limits) before charging; Apple Developer ID, notarised DMG.
6. Pricing after two weeks of Usage data (see Billing design).
