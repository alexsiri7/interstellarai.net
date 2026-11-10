"""annie_export.py — write an Annie project's story bible as Markdown files.

Reads one JSON document on stdin (produced by story-sync.sh's read-only psql
query) and writes one file per story object, plus one per outline node, under
the output directory:

    <out>/README.md                     what this directory is
    <out>/<type>/<slug>.md              story objects (character, location, ...)
    <out>/outline/<NNN>-<slug>.md       outline nodes in manuscript order

The output is deterministic: no timestamps or database ids in file names, and
only fields that carry story. Annie is the source of truth, so the directory is
rewritten from scratch every time, and a git diff of it is the change.

Usage: python3 -I annie_export.py <out-dir> < export.json
"""

import html
import json
import re
import shutil
import sys
from pathlib import Path

README = """# Annie mirror (generated: do not edit)

This directory is a read-only mirror of the game's story bible in Annie, written
by ops/cron/story-sync.sh. Every sync rewrites it from scratch, so a hand edit
is lost. Change the story in Annie.

`story/CANON.md` is the curated story the game implements. The story-sync
workflow promotes only settled material from here into it. Anything tentative,
hedged or tagged `open` goes to `story/PENDING.md` instead.
"""


def html_to_text(markup: str) -> str:
    """Scene text is stored as editor HTML; keep paragraphs, drop the markup.

    Annie stores a beat (one structured line of a scene, the unit of the story
    format spec) as an HTML comment, `<!-- beat: ... -->`. Each beat becomes its
    own paragraph, before any tag is stripped: a beat may itself contain `>`.
    """
    text = re.sub(r"(?s)<!--\s*beat:\s*(.*?)\s*-->", lambda m: "\n\n" + m.group(1) + "\n\n", markup)
    text = re.sub(r"(?s)<!--.*?-->", "", text)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)</(p|h[1-6]|li|blockquote)>", "\n\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "untitled"


def object_file(obj: dict, related: list[str]) -> str:
    lines = [f"# {obj['name']}", ""]
    meta = [f"- **Type:** {obj['type'].lower().replace('_', ' ')}"]
    if obj.get("role"):
        meta.append(f"- **Role:** {obj['role']}")
    if obj.get("tags"):
        meta.append(f"- **Tags:** {obj['tags']}")
    lines += meta + [""]
    if obj.get("description"):
        lines += [obj["description"].rstrip(), ""]
    if obj.get("notes"):
        lines += ["## Notes", "", obj["notes"].rstrip(), ""]
    if related:
        lines += ["## Relationships", ""] + [f"- {r}" for r in sorted(related)] + [""]
    return "\n".join(lines)


def main() -> None:
    out = Path(sys.argv[1])
    data = json.load(sys.stdin)
    objects = data.get("objects") or []
    nodes = data.get("nodes") or []
    rels = data.get("relationships") or []

    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    (out / "README.md").write_text(README)

    names = {o["id"]: o["name"] for o in objects}
    related: dict[str, list[str]] = {}
    for r in rels:
        a, b = names.get(r.get("fromObjectId")), names.get(r.get("toObjectId"))
        if not a or not b:
            continue
        label = (r.get("label") or r.get("type") or "related").strip()
        related.setdefault(r["fromObjectId"], []).append(f"{label} → {b}")
        related.setdefault(r["toObjectId"], []).append(f"{a} → {label} (this)")

    used: set[Path] = set()
    for obj in sorted(objects, key=lambda o: (o["type"], o["name"].lower(), o["id"])):
        path = out / slug(obj["type"]) / f"{slug(obj['name'])}.md"
        n = 2
        while path in used:
            path = out / slug(obj["type"]) / f"{slug(obj['name'])}-{n}.md"
            n += 1
        used.add(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(object_file(obj, related.get(obj["id"], [])))

    # Outline: depth-first in orderIndex order, numbered so `ls` shows manuscript order.
    children: dict[str | None, list[dict]] = {}
    for node in nodes:
        children.setdefault(node.get("parentId"), []).append(node)
    order: list[tuple[int, dict]] = []

    def walk(parent: str | None, depth: int) -> None:
        for node in sorted(children.get(parent, []), key=lambda n: (n["orderIndex"], n["id"])):
            order.append((depth, node))
            walk(node["id"], depth + 1)

    walk(None, 0)
    for i, (depth, node) in enumerate(order, 1):
        path = out / "outline" / f"{i:03d}-{slug(node['title'])}.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        body = [f"# {node['title']}", "", f"- **Kind:** {node['type'].lower()}",
                f"- **Depth:** {depth}", f"- **Status:** {node.get('status', '').lower()}", ""]
        if node.get("synopsis"):
            body += ["## Synopsis", "", node["synopsis"].rstrip(), ""]
        if node.get("content"):
            body += ["## Text", "", html_to_text(node["content"]), ""]
        path.write_text("\n".join(body))


if __name__ == "__main__":
    main()
