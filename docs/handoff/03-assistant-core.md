# 03 · Assistant core: Claude sessions, prompt, models, cost

Read `00-common.md` first.

## Scope
How a request reaches Claude and comes back: the Claude Code session, the system prompt, model routing, permissions, background tasks, usage and cost, other providers.

## Files
- `Assistant.swift`: `Assistant` (per conversation; `prepare`, `ask`, `useStrongModel`, `tutorPrompt` mode), `Session` (spawns `claude -p --input-format stream-json --output-format stream-json`, parses stream events, `finishTurn`, `environment()`), `systemPrompt(…)` (the long instruction text), `ToolPolicy` (what needs approval), `needsStrongModel`.
- `AIAccount.swift`: Claude plan / Anthropic API key / OpenRouter or custom Anthropic-compatible endpoint (`openRouterEnvironment` uses its own `CLAUDE_CONFIG_DIR` so the plan's sign-in is untouched); `usesChatGPT` (UserDefaults `aiProvider` = `claude`/`chatgpt`), `chatGPTModel`.
- `CodexSession.swift`: the ChatGPT engine. One `codex app-server` process (JSON-RPC lines on stdio): `initialize` → `thread/start` (Joe's prompt as `developerInstructions`, vault as cwd, `approvalPolicy: untrusted`, `sandbox: danger-full-access`, `ephemeral`, live web search) → `turn/start` per request. Maps `item/agentMessage/delta`, `item/started`, `turn/plan/updated`, `turn/completed`, `error` to `Assistant.Event`; `item/commandExecution/requestApproval` and `item/fileChange/requestApproval` go through `ToolPolicy` as Bash / Edit. `CodexAccount`: status (`codex login status`), install (OpenAI's Apple Silicon build from GitHub releases into `~/.local/bin`, no Node), sign-in (`codex login`).
- `Engine` protocol (in `Assistant.swift`): what `Assistant` needs from a conversation (`isRunning`, `launchError`, `send`, `stop`). `Session` and `CodexSession` adopt it; `Assistant.makeEngine()` picks one. Not tied to a subprocess, so the planned `CloudSession` (Joe accounts, our key through a Joe server, see 11) plugs in the same way.
- `UsageLog.swift` (Usage.jsonl from `total_cost_usd`), `TaskShelf.swift` (`AssistantTask`, background tasks at the side notch), `Activity.swift` (History), `StudyBuddy.swift` (quiz rules in the prompt), `ClaudeSetup.swift` (install/sign in, see 06).

## How it works (decisions)
- Default model **Haiku** (the code default was Opus until 21 Oct, which made routing pointless for new users; fixed). **Opus only when the user asks Joe to do a piece of work** at the start of the request ("can you do my ESS formative", "help me write my TOK essay intro", "redesign my slides"), at **medium** effort; Settings → Advanced → "Opus for big jobs" turns it off. Test with `Joe --route`.
- Prompt caching: volatile context ("What they asked you lately") goes with the **first request**, not the system prompt, so the prompt is identical across requests; `CLAUDE_CODE_PROMPT_CACHE_TTL=1h`. A repeat question dropped from $0.0038 to $0.0013.
- Replies start with "Subject: …" (the card title); Markdown is rendered (tables/headings only when asked or clearly clearest; never "the card can't show").
- Quiz marks arrive as a hidden `<mark …/>` tag that the app writes to the quiz log (saves a tool call).
- The study whiteboard uses a **tutor session**: short quiz-only prompt, tools Read/Grep/Glob/Bash only, `--strict-mcp-config` (no connectors) — first question ~6 s, marking ~5 s.
- Today's Opus requests from 20 Oct were moved out of the totals into `Usage excluded (Opus 2026-10-20).jsonl`.

## Known issues / to-do
- **ChatGPT subscription**: phase 1 built (21 Oct, `CodexSession`): Settings → Advanced → AI (Claude / ChatGPT, sign-in, optional model) and an "I have ChatGPT, not Claude" path in onboarding. Untested on a Mac yet. Test: switch to ChatGPT, `Joe --ask "what's due this week"` plus a follow-up, an action that needs approval (a file change outside the vault), a screenshot question, a quiz on the whiteboard.
  - Gaps in ChatGPT mode: no Chrome control and no clicking/typing (Joe declines commands it would have to remap); Claude's MCP connectors aren't in `~/.codex/config.toml` (phase 2: copy them); Codex runs commands it knows are read-only (ls, cat, grep…) without asking, so `ToolPolicy`'s secret-file block doesn't see those; MCP elicitations are declined; `NoteSaver`/`PromptPolish` still need `claude` (phase 2: `codex exec` fallback). Codex picks the model; Joe's Haiku choice means effort low.
  - Terms: the student's own Codex login is fine for the beta; "Sign in with ChatGPT" for apps is partner-only, so a paid Joe needs OpenAI's approval first (see 11).
- **OpenAI-compatible endpoints**: Claude Code only speaks Anthropic's protocol; route through OpenRouter/LiteLLM (works today via the custom endpoint) or via Codex CLI's custom providers.
- OpenRouter mode untested (needs a key); costs on the Usage page assume Claude prices.
- Paid product plan: Joe accounts with our own API key server-side (decided 20 Oct), see 11.
