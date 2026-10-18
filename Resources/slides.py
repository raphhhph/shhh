"""Joe's slides tool: read a PowerPoint deck, then apply a plan of edits to a copy of it.

    slides.py inspect <deck.pptx>
    slides.py apply <deck.pptx> <plan.json>

Edits go into the deck's own boxes, keeping their fonts, colours and layout: a box's first
paragraph is the template for every new line in it. The original is never changed; the result
is saved next to it as "<name> (Joe).pptx".

A plan:
{
  "slides": [
    {"slide": 2, "title": "Research question", "bullets": ["To what extent…", "Case: …"],
     "notes": "What to say on this slide…"},
    {"slide": 4, "shape": 7, "text": ["Replaces the text of box 7 (ids from inspect)"]}
  ],
  "add": [{"after": 5, "title": "…", "bullets": ["…"], "notes": "…"}],
  "delete": [9]
}
"""
import copy
import json
import os
import sys

from pptx import Presentation
from pptx.util import Pt

MAX_BULLETS, MAX_WORDS = 5, 12


def placeholders(slide):
    title = slide.shapes.title
    body = None
    for shape in slide.placeholders:
        if title is not None and shape.shape_id == title.shape_id or not shape.has_text_frame:
            continue
        kind = str(shape.placeholder_format.type)
        if "BODY" in kind or "OBJECT" in kind or "SUBTITLE" in kind:
            body = shape
            break
    if body is None:  # a text box that isn't the title: the biggest one
        boxes = [s for s in slide.shapes if s.has_text_frame and (title is None or s.shape_id != title.shape_id)]
        body = max(boxes, key=lambda s: (s.width or 0) * (s.height or 0), default=None)
    return title, body


def inspect(path):
    deck = Presentation(path)
    print(f"{os.path.basename(path)}: {len(deck.slides)} slides, {deck.slide_width / 914400:.1f}×{deck.slide_height / 914400:.1f} in")
    for number, slide in enumerate(deck.slides, 1):
        print(f"\n=== Slide {number} · layout “{slide.slide_layout.name}”")
        title, body = placeholders(slide)
        for shape in slide.shapes:
            role = "TITLE" if title is not None and shape.shape_id == title.shape_id else \
                "BODY" if body is not None and shape.shape_id == body.shape_id else ""
            if shape.has_text_frame:
                lines = [p.text for p in shape.text_frame.paragraphs if p.text.strip()]
                words = sum(len(l.split()) for l in lines)
                flag = "  ⚠ too long for a slide" if len(lines) > MAX_BULLETS or any(len(l.split()) > MAX_WORDS for l in lines) else ""
                print(f"  box {shape.shape_id} {role or 'text'} “{shape.name}” ({words} words){flag}")
                for line in lines:
                    print(f"    • {line}")
            elif shape.shape_type is not None:
                print(f"  box {shape.shape_id} {str(shape.shape_type).split('.')[-1].split(' ')[0].lower()} “{shape.name}”")
        notes = slide.notes_slide.notes_text_frame.text.strip() if slide.has_notes_slide else ""
        print(f"  notes: {notes[:600] + ('…' if len(notes) > 600 else '') if notes else '(none)'}")


def set_lines(frame, lines):
    """Replaces a text frame's lines, each formatted like its first paragraph."""
    paragraphs = frame.paragraphs
    template = copy.deepcopy(paragraphs[0]._p)
    for paragraph in paragraphs[1:]:
        paragraph._p.getparent().remove(paragraph._p)
    first = frame.paragraphs[0]
    write(first, lines[0] if lines else "")
    for line in lines[1:]:
        element = copy.deepcopy(template)
        frame._txBody.append(element)
        write(frame.paragraphs[-1], line)


def write(paragraph, text):
    runs = paragraph.runs
    if runs:
        runs[0].text = text
        for run in runs[1:]:
            run._r.getparent().remove(run._r)
    else:
        paragraph.text = text


def has_notes_setup(deck):
    """Decks from PowerPoint have a notes master. One python-pptx has to invent breaks the file in
    Keynote, so notes are only written into decks that already have one."""
    return deck.part._element.find("{http://schemas.openxmlformats.org/presentationml/2006/main}notesMasterIdLst") is not None


def set_notes(slide, text):
    frame = slide.notes_slide.notes_text_frame
    frame.text = text


def apply(path, plan_path):
    deck = Presentation(path)
    with open(plan_path, encoding="utf-8") as f:
        plan = json.load(f)
    slides = list(deck.slides)
    warnings = []
    notes_ok = has_notes_setup(deck)
    for edit in plan.get("slides", []):
        number = edit["slide"]
        if not 1 <= number <= len(slides):
            warnings.append(f"slide {number} doesn't exist")
            continue
        slide = slides[number - 1]
        title, body = placeholders(slide)
        if "title" in edit and title is not None:
            set_lines(title.text_frame, [edit["title"]])
        if "bullets" in edit:
            bullets = edit["bullets"]
            if len(bullets) > MAX_BULLETS or any(len(b.split()) > MAX_WORDS for b in bullets):
                warnings.append(f"slide {number}: over {MAX_BULLETS} bullets or {MAX_WORDS} words a bullet — move detail to the notes")
            if body is None:
                warnings.append(f"slide {number}: no body box for bullets")
            else:
                set_lines(body.text_frame, bullets)
        if "shape" in edit:
            target = next((s for s in slide.shapes if s.shape_id == edit["shape"] and s.has_text_frame), None)
            if target is None:
                warnings.append(f"slide {number}: no text box {edit['shape']}")
            else:
                set_lines(target.text_frame, edit.get("text", []))
        if "notes" in edit:
            if notes_ok:
                set_notes(slide, edit["notes"])
            else:
                warnings.append(f"slide {number}: notes skipped (this deck has no speaker-notes setup)")
    for addition in sorted(plan.get("add", []), key=lambda a: a.get("after", 0), reverse=True):
        # The layout of the slide it follows (or "Title and Content"), so it matches the deck.
        after = addition.get("after", len(deck.slides))
        layout = deck.slides[after - 1].slide_layout if 1 <= after <= len(deck.slides) else deck.slide_layouts[1]
        slide = deck.slides.add_slide(layout)
        title, body = placeholders(slide)
        if title is not None and "title" in addition:
            title.text = addition["title"]
        if body is not None and addition.get("bullets"):
            body.text_frame.text = addition["bullets"][0]
            for line in addition["bullets"][1:]:
                body.text_frame.add_paragraph().text = line
        if addition.get("notes") and notes_ok:
            set_notes(slide, addition["notes"])
        # Move it to just after `after`.
        ids = deck.slides._sldIdLst
        element = ids[-1]
        ids.remove(element)
        ids.insert(min(after, len(ids)), element)
    for number in sorted(plan.get("delete", []), reverse=True):
        ids = deck.slides._sldIdLst
        if 1 <= number <= len(ids):
            ids.remove(ids[number - 1])
    base, _ = os.path.splitext(path)
    out = base.replace(" (Joe)", "") + " (Joe).pptx"
    deck.save(out)
    print(f"Saved {out} ({len(deck.slides)} slides). The original is unchanged.")
    for warning in warnings:
        print("⚠", warning)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "inspect":
        inspect(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "apply":
        apply(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
