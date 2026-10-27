# 07 · Study (IB DP and MYP)

Read `00-common.md` first.

## Scope
Quizzing, marking and revision: syllabus knowledge, the whiteboard, the quiz log, the Study page, the points calculator, MYP.

## Files
- `Resources/Syllabus/*.md`: our own subtopic-level maps for **Mathematics AI, Economics, Business Management, Environmental Systems and Societies, English A Language and Literature, Chinese B, Theory of Knowledge**, plus `Command terms.md` (depth and IB marking) and `MYP.md` (criteria A–D per subject group, bands, 1–7 boundaries, Personal Project, eAssessment). Copied into the app by `build.sh`. Written in our words (IB guides are copyrighted); ESS HL weights unverified.
- `StudyBuddy.swift`: pack lookup (`pack(for:)` aliases), quiz log (`logURL`, `results()`), notch-quiz rules in the prompt, hidden `<mark>` tag recording.
- `StudyBoard.swift`: the **whiteboard** window. `StudyBoardModel` (tutor session, tags `<question n marks topic source>`, `<ms>` hidden markscheme, `<feedback score total>`, `<model>`, `<summary>`), `StudyBoardView` (cards, composer, hint/skip/end, read aloud), `SketchPad` (drawn diagrams sent as JPEG; Claude marks the drawing). `tutorPrompt` builds the session prompt (pack, command terms, recent results, past papers found in `_files/School/<subject>/`).
- `Dashboard.swift`: `StudyPage` (subject cards with score and weakest topic, Quiz me / Exam question / Revise weakest, recent answers, past-papers note), `PointsCalculator` (/45 with the TOK×EE core matrix and failing conditions).
- `AppDelegate.openStudy`: "quiz me…", "let's start/do a quiz", "study session", "open/pull up the whiteboard" open it; subject from the request, the card's conversation, or the last studied (`lastStudySubject`).

- `IBProjects.swift` (Oct 2026, branch `claude/study-buddy-followthrough`): the **IB project tracker**. One note per project in `School/Projects/` (`Extended Essay.md`, `<Subject> IA.md`, `TOK Essay.md`, `TOK Exhibition.md`, `Individual Oral.md`, `CAS.md`): frontmatter `kind` (ee, ia, tok-essay, tok-exhibition, io, cas), `subject`, `supervisor`, `final`, `doc`, `words`; then `## Milestones` (`- [ ] 2026-11-10 · Full first draft to supervisor`), `## Meetings`, `## Next action`. `create` writes the note from a per-kind template with the IB's usual milestones dated back from the final date (squeezed when there's less time; with no date, a matching ManageBac deadline, else a guess marked `# a guess`). `dailyTasks` gives the Daybook each project's next milestone when it's overdue or due within 7 days (`- [ ] EE: Outline — due Mon 10 Nov · project`); `nearestMilestone` gets a block in the Plan. Word count of a local `doc:` (.docx/.pages/.rtf via `textutil -convert txt -stdout`, .md/.txt read directly); a Google Doc is left to Claude. `instructions` (in the system prompt after the Daybook's) cover "start my EE" (runs `--project-new`), logging supervisor meetings, ticking milestones.
- Study page: a **Projects** card (`ProjectsCard` in Dashboard.swift): progress bar (milestones done/total), next milestone and days left, words/limit, Open note (Obsidian), and a Start a project menu (each kind, and an IA per subject).

## Decisions
- Real IB past papers are copyrighted and can't ship; Joe uses papers the student saves in `_files/School/<subject>/Past papers/` (with markschemes) and otherwise writes questions in each paper's style. ibo.org blocks automated access.
- Tutor session runs Haiku: first question ~6 s, marking ~5 s; accuracy via the hidden markscheme.
- MYP students (programme contains "MYP") are marked on criteria A–D out of 8.
- Voice answers go to the whiteboard only when it's the key window.

## Test (projects)
- `Joe --projects [<vault or School folder>]` prints each project's progress, next milestone, days left, words, and the tasks it adds to today's Daybook (writes nothing).
- `Joe --project-new <ee|ia|tok-essay|tok-exhibition|io|cas> ["<subject>"] [yyyy-mm-dd] ["<supervisor>"]` makes the note (or finds it) and prints it.

## Known issues / to-do
- Packs for more subjects (Physics, Chemistry, Biology, History, Psychology, Math AA, English B, Spanish…), and MYP subject detail.
- A past-paper importer (index PDFs, split questions/markschemes) and spaced repetition from the quiz log.
- Maths rendering on the whiteboard (KaTeX like `mathdoc.js`) instead of plain text.
- Projects: not yet compiled on a Mac when written. Onboarding doesn't create projects yet (only `create` looks up a matching ManageBac deadline for the final date).
