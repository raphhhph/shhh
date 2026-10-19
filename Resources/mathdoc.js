// Joe's worked-solutions page: node mathdoc.js <spec.json> <out.html>. The spec:
// {"title", "subtitle"?, "footer"?, "questions": [{"n", "title"?, "marks"?, "given"? (LaTeX),
//   "parts": [{"label": "(a)", "title", "steps": [["<LaTeX>", "<why, in plain words>"]], "answer": "<LaTeX>"}]}]}
// Every step is typeset with KaTeX, its note beside it in a handwriting font, the answer boxed.
// KaTeX's styles and fonts are copied next to the page (links to "Application Support" break).
const katex = require('katex');
const fs = require('fs');
const path = require('path');
const [specPath, out] = process.argv.slice(2);
const doc = JSON.parse(fs.readFileSync(specPath, 'utf8'));
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const m = (tex, display = true) => katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'html' });
const dist = path.dirname(require.resolve('katex/dist/katex.min.css'));
const target = path.join(path.dirname(out), 'katex');
if (!fs.existsSync(path.join(target, 'katex.min.css'))) fs.cpSync(dist, target, { recursive: true });
const html = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(doc.title)}</title>
<link rel="stylesheet" href="katex/katex.min.css">
<style>
  @page { size: A4; margin: 16mm 14mm; }
  :root { --ink: #1d2433; --muted: #6b7385; --line: #e3e6ee; --accent: #2457c5; --pen: #1f4fa8; --ans: #0f7b4a; }
  * { box-sizing: border-box; }
  body { font: 11pt/1.45 "Avenir Next", "Helvetica Neue", sans-serif; color: var(--ink); margin: 0; }
  h1 { font-size: 22pt; margin: 0 0 2pt; letter-spacing: -0.3px; }
  .sub { color: var(--muted); margin-bottom: 14pt; }
  .key { display: flex; gap: 16pt; font-size: 9pt; color: var(--muted); margin-bottom: 16pt; }
  .key .pen { font-family: "Noteworthy", "Bradley Hand", cursive; color: var(--pen); font-size: 10.5pt; }
  .q { margin-bottom: 18pt; }
  .q + .q { break-before: page; }
  .qhead, .given, .ptitle { break-after: avoid; }
  .qhead { display: flex; align-items: baseline; justify-content: space-between; border-bottom: 2px solid var(--ink); padding-bottom: 3pt; }
  .qhead h2 { font-size: 15pt; margin: 0; }
  .qhead span { color: var(--muted); font-size: 10pt; }
  .given { background: #f4f6fb; border-radius: 8px; padding: 2pt 12pt; margin: 8pt 0 10pt; }
  .part { break-inside: avoid; margin: 0 0 12pt; }
  .ptitle { font-weight: 600; margin: 6pt 0 2pt; }
  .ptitle b { color: var(--accent); margin-right: 6pt; }
  .step { display: grid; grid-template-columns: 1fr 34%; gap: 12pt; align-items: center; border-left: 2px solid var(--line); padding-left: 10pt; margin-left: 4pt; }
  .step .math .katex-display { margin: 4pt 0; text-align: left; }
  .step .math .katex-display > .katex { text-align: left; }
  .note { font-family: "Noteworthy", "Bradley Hand", cursive; color: var(--pen); font-size: 10.5pt; line-height: 1.3; }
  .answer { display: inline-flex; align-items: center; gap: 8pt; margin: 6pt 0 0 4pt; padding: 3pt 12pt; border: 2px solid var(--ans); border-radius: 8px; color: var(--ans); }
  .answer .lbl { font-size: 8.5pt; font-weight: 700; letter-spacing: 0.6px; text-transform: uppercase; }
  .answer .katex { color: var(--ink); font-size: 1.12em; }
  .foot { color: var(--muted); font-size: 9pt; border-top: 1px solid var(--line); padding-top: 6pt; }
</style></head><body>
<h1>${esc(doc.title)}</h1>
${doc.subtitle ? `<div class="sub">${esc(doc.subtitle)}</div>` : ""}
<div class="key"><span>Left: the maths, one move per line.</span><span class="pen">Right: why that step works.</span><span style="color:var(--ans)">Boxed: the answer to write down.</span></div>
${doc.questions.map(q => `<section class="q">
  <div class="qhead"><h2>${esc(q.title || `Question ${q.n}`)}</h2><span>${q.marks ? `[${q.marks} marks]` : ""}</span></div>
  ${q.given ? `<div class="given">${m(q.given)}</div>` : ""}
  ${q.parts.map(p => `<div class="part">
    <div class="ptitle"><b>${esc(p.label || '')}</b>${esc(p.title || '')}</div>
    ${(p.steps || []).map(([tex, note]) => `<div class="step"><div class="math">${m(tex)}</div><div class="note">${esc(note || '')}</div></div>`).join('')}
    ${p.answer ? `<div class="answer"><span class="lbl">Answer</span>${m(p.answer, false)}</div>` : ""}
  </div>`).join('')}
</section>`).join('')}
${doc.footer ? `<div class="foot">${esc(doc.footer)}</div>` : ""}
</body></html>`;
fs.writeFileSync(out, html);
console.log(out);
