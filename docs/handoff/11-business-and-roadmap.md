# 11 · Business, beta and roadmap

Read `00-common.md` first.

## Where things stand (21 Oct 2026)
- Beta: Raph, his brother, and Landon (first outside tester, 21 Oct). DMG in `~/Desktop/Joe Installer`.
- Product notes in the vault, `Brain/Ventures/Joe/`: **Joe — Plan** (business plan, decided: the paid product signs in with a Joe account with AI built in, server-side key, metering), **Joe — My to-do**, **Joe — Beta feedback (Landon) 2026-10-21**, **Joe — Night session 2026-10-21** (what shipped, audit), China decision memo, Competitor map, IB-coded plan, Billing design, Hugging Face audit, Chinese speech options.
- Inspirations reviewed: **Plip** (open-source notch assistant: Claude install in onboarding, walkthroughs, confirm risky actions), **Vovy** (prompt rewriting → "make it a prompt"), **NotchNook** (hover overview → done), **OpenClaw** (subscription-powered agent).

## Beta feedback status (Landon, 21 Oct)
- Crash on a cut-off download → **done** (Get Joe ready step, crash guard, Mac-voice fallback).
- Notch overview with widgets → **done** (customising via menu; drag editor to do).
- Custom API endpoints → **Anthropic-compatible done**; OpenAI-compatible via OpenRouter/LiteLLM; native OpenAI needs the Codex engine.
- ChatGPT subscription → **to do** (Codex CLI engine; check OpenAI terms before charging).

## Platform rules (checked 21 Oct 2026, details in the audit doc)
- **Claude Code terms**: a product that runs Claude Code may not pay for, resell or intermediate its users' Claude usage; each user signs in with their own plan or key. Free tier (user's own `claude` login, unmodified binary) is fine. A paid tier that runs `claude -p` with our key is **not**. Never read or store the user's Claude token. Source: code.claude.com/docs/en/legal-and-compliance.
- **Age**: Claude consumer plans are 18+; most DP students are 16-17. ChatGPT allows 13+ with parental consent. A paid API product used by minors needs age check, moderation, AI disclosure, child-safety prompt, public privacy compliance (support.claude.com/en/articles/9307344).
- **Sign in with ChatGPT** (29 Sep 2026): Plus/Pro plans usable in *participating* partner apps only. Joe should apply before charging; until then ChatGPT mode = user's own Codex CLI login.
- **China**: neither Anthropic nor OpenAI serves mainland China; a Joe server can't route students there to Claude. Separate engine/market later.

## Business model (revised 21 Oct 2026)
- Free: your Claude plan (works today) · Free: your ChatGPT plan (Codex engine, planned) · **Joe Plus** (paid): `CloudSession` engine calling the Claude API through a Joe server with our key, per-account metering. This replaces "Joe account running claude with our key".
- `Engine` protocol in `Assistant.swift` must have room for three engines: `Session`, `CodexSession`, `CloudSession`. CloudSession runs the tool loop itself (Joe's tools locally, model call via server).
- Pricing hypothesis: ~$8/month or ~$60/school year with a weekly cap; decide after Beta 2 cost data (target cost < 40% of price). Later: school site licences.

## Roadmap (revised 21 Oct 2026; exam season is the deadline: mocks Jan-Feb, finals May)
1. **Beta 2 (to ~7 Nov)**: resumable downloads + network errors; zero-setup onboarding from one ManageBac link; local Daybook; Apple Developer ID + notarised DMG (needs Raph's OK, $99/yr); weekly cost-per-student report from Usage.jsonl; 5-10 IB testers, half outside China. Gate: 5 testers onboard unaided, use Joe 3+ days/week.
2. **Study + ChatGPT (Nov-Dec)**: Engine protocol + Codex engine; subject packs, past-paper importer, spaced repetition, maths rendering; ManageBac walkthrough. Gate: weekly Study use unprompted.
3. **Joe Cloud + charging (Dec-Feb)**: CloudSession, server, accounts (Sign in with Apple), minors safeguards, privacy policy; confirm with Anthropic sales; apply to Sign in with ChatGPT; pricing test. Gate: launch for mocks.
- Deferred: widget drag editor, more alarm challenges, China.

## Open decisions (Raph)
Developer ID now (recommended yes); Joe Cloud on the API (required by terms); beta age policy (Claude path 18+, younger via ChatGPT with parent OK); China deferred; partner applications in phase 3.
