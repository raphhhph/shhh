# 03 · Assistant core: Claude sessions, prompt, models, cost

Read `00-common.md` first.

## Scope
How a request reaches Claude and comes back: the Claude Code session, the system prompt, model routing, permissions, background tasks, usage and cost, other providers.

## Files
- `Assistant.swift`: `Assistant` (per conversation; `prepare`, `ask`, `useStrongModel`, `tutorPrompt` mode), `Session` (spawns `claude -p --input-format stream-json --output-format stream-json`, parses stream events, `finishTurn`, `environment()`), `systemPrompt(…)` (the long instruction text), `ToolPolicy` (what needs approval), `needsStrongModel`.
- `AIAccount.swift`: Claude plan / Anthropic API key / OpenRouter or custom Anthropic-compatible endpoint (`openRouterEnvironment` uses its own `CLAUDE_CONFIG_DIR` so the plan's sign-in is untouched).
- `UsageLog.swift` (Usage.jsonl from `total_cost_usd`), `TaskShelf.swift` (`AssistantTask`, background tasks at the side notch), `Activity.swift` (History), `StudyBuddy.swift` (quiz rules in the prompt), `ClaudeSetup.swift` (install/sign in, see 06).

## How it works (decisions)
- Default model **Haiku**. **Opus only when the user asks Joe to do a piece of work** at the start of the request ("can you do my ESS formative", "help me write my TOK essay intro", "redesign my slides"), at **medium** effort; Settings → Advanced → "Opus for big jobs" turns it off. Test with `Joe --route`.
- Prompt caching: volatile context ("What they asked you lately") goes with the **first request**, not the system prompt, so the prompt is identical across requests; `CLAUDE_CODE_PROMPT_CACHE_TTL=1h`. A repeat question dropped from $0.0038 to $0.0013.
- Replies start with "Subject: …" (the card title); Markdown is rendered (tables/headings only when asked or clearly clearest; never "the card can't show").
- Quiz marks arrive as a hidden `<mark …/>` tag that the app writes to the quiz log (saves a tool call).
- **Haiku at Medium runs at Low** (`Assistant.sessionEffort`): ~2 s sooner to first words on a calendar question (A/B on the Mac, 22 Oct). Big jobs still get Opus at Medium.
- **Spare session** (`Spare` in Assistant.swift): one `claude -p` is always started ahead with the usual settings, so a new conversation (typed, pen, several tasks, or a short spoken one) doesn't wait for Claude Code to start; the next one starts 4 s after it's taken. It's thrown away if the settings changed (arguments or environment differ) or it's 2 h old. An unused session (the request went to Spotify, or to Opus) is kept as the spare. Off: `defaults write io.github.tibophlp.shhh spareSession -bool false`.
- **Connectors trimmed** (`Connectors` in QuickContext.swift): account connectors and plugins Joe doesn't use (finance, CRM, Miro, Make, Gamma…) are passed as `--disallowedTools mcp__<server>`, learned from each session's init. Raph had 19 connectors / 361 tools and turns took ~4.5 s to start. Keep more: `connectorsKept` (words); off: `trimConnectors -bool false`.
- **Calendar in the first request** (`QuickContext.calendar`): the next 3 days plus 2 weeks of deadlines from `CalendarFeed`, so schedule questions skip the Google Calendar connector (8 s on 22 Oct). Off: `quickContext -bool false`.
- **Latency log**: every request asked with right ⌥ (or typed) writes ms-after-press for each step to `Latency.jsonl` (Joe's folder): micLive, released, audioReady, denoised, transcribed, sent, firstEvent, firstText, firstAudio, done. `Joe --latency` prints medians; `Joe --bench-claude` times Claude Code cold vs started ahead.
- The study whiteboard uses a **tutor session**: short quiz-only prompt, tools Read/Grep/Glob/Bash only, `--strict-mcp-config` (no connectors) — first question ~6 s, marking ~5 s.
- Today's Opus requests from 20 Oct were moved out of the totals into `Usage excluded (Opus 2026-10-20).jsonl`.

## Known issues / to-do
- **ChatGPT subscription (beta feedback)**: needs a second engine, OpenAI's **Codex CLI** signed in with a ChatGPT plan (`codex login`, `codex exec --json`), with an adapter like `Session` mapping its JSON events to `Assistant.Event`. OpenAI allows subscription use in personal/open-source projects; paid apps need approval: check before charging.
- **OpenAI-compatible endpoints**: Claude Code only speaks Anthropic's protocol; route through OpenRouter/LiteLLM (works today via the custom endpoint) or via Codex CLI's custom providers.
- OpenRouter mode untested (needs a key); costs on the Usage page assume Claude prices.
- Paid product plan: Joe accounts with our own API key server-side (decided 20 Oct), see 11.
