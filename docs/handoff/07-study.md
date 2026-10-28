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

- **Student life** (Oct 2026, branch `claude/study-buddy-life`), all local (no Claude):
  - `CASLog.swift`: "log CAS: beach clean-up, 2 hours, service" / "CAS: played volleyball match 1.5h" adds a row under `## Log` in `School/Projects/CAS.md` (made from the CAS template when missing): `| Date | Experience | Strand | Hours | Learning outcomes | Evidence |`. Strand said or guessed from the words; outcomes said ("LO5") kept, else at most two light guesses written `LO5?`; a link or file path becomes the evidence; "yesterday" or "25 oct" dates it. "How's my CAS" → one card: hours per strand, experiences, CAS project yes/no (a row naming "CAS project" or that milestone ticked), LO1–LO7 covered and which are still to show.
  - Uni applications: `IBProjects.Kind.uni` ("Applications", also its task label, subject `UCAS` / `Common App` / `UCAS and Common App`). Milestones counted back from the final date (UCAS main 29 Jan: statement draft/final, reference, Oxbridge/medicine 15 Oct; Common App Regular 1 Jan: essay, recommendations, Early 1 Nov), not squeezed; a step already past is dated today and a past deadline is left out. No date: the next 29 Jan (1 Jan for Common App only), a year later when the profile says DP1/grade 11. "Start my uni applications (UCAS | Common App | both)" uses the project-new path; Projects card menu has the three.
  - `Wellbeing.swift`: `Daybook/Wellbeing.md` table (date, sleep, stress, note). Sunday's week-plan card (and "how am I doing" / "wellbeing check") asks sleep and stress 1–5; "stress 4, slept 6 hours" or "wellbeing: 3, 7h, mocks" records it (taken locally even as a follow-up). When the latest check-in (last 14 days) has stress ≥4 or sleep <6.5, `WeekPlan.text` writes a "Lighter week: …" line under the title and plans at most one after-school/evening block on weekdays and nothing past 21:00 Sun–Thu; the re-plan keeps both rules while that line is there.

## Decisions
- Real IB past papers are copyrighted and can't ship; Joe uses papers the student saves in `_files/School/<subject>/Past papers/` (with markschemes) and otherwise writes questions in each paper's style. ibo.org blocks automated access.
- Tutor session runs Haiku: first question ~6 s, marking ~5 s; accuracy via the hidden markscheme.
- MYP students (programme contains "MYP") are marked on criteria A–D out of 8.
- Voice answers go to the whiteboard only when it's the key window.

## Test (projects)
- `Joe --projects [<vault or School folder>]` prints each project's progress, next milestone, days left, words, and the tasks it adds to today's Daybook (writes nothing).
- `Joe --project-new <ee|ia|tok-essay|tok-exhibition|io|cas> ["<subject>"] [yyyy-mm-dd] ["<supervisor>"]` makes the note (or finds it) and prints it.

## Test (student life)
- `Joe --route "log CAS: beach clean-up, 2 hours, service" "how's my CAS" "start my uni applications UCAS" "stress 4, slept 6 hours" "wellbeing check"` → `local (cas log)`, `local (cas status)`, `local (project new)`, `local (wellbeing)` ×2.
- On a vault copy: `Joe --local "log CAS: beach clean-up, 2 hours, service" <copy>`, `Joe --local "how's my CAS" <copy>`, `Joe --local "start my uni applications both" <copy>`, `Joe --local "stress 4, slept 6 hours" <copy>`, then `Joe --local "plan my week" <copy>` (Week.md says "Lighter week"), `Joe --prompt sunday <copy>` (card ends with the check-in question).

## Known issues / to-do
- Packs for more subjects (Physics, Chemistry, Biology, History, Psychology, Math AA, English B, Spanish…), and MYP subject detail.
- A past-paper importer (index PDFs, split questions/markschemes) and spaced repetition from the quiz log.
- Maths rendering on the whiteboard (KaTeX like `mathdoc.js`) instead of plain text.
- Projects: not yet compiled on a Mac when written. Student life (CAS log, uni, wellbeing) likewise. Onboarding doesn't create projects yet (only `create` looks up a matching ManageBac deadline for the final date).
