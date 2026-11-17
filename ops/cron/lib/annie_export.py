"""annie_export.py — write an Annie project's story bible as Markdown files.

Reads one JSON document on stdin (produced by story-sync.sh's read-only psql
query) and writes one file per story object, plus one per outline node, under
the output directory:

    <out>/README.md                     what this directory is
    <out>/<type>/<slug>.md              story objects (character, location, ...)
    <out>/<type>/<slug>/<NN>-<kind>.webp  a location's images, in Annie's order
    <out>/<type>/<slug>.map.json        a location's map
    <out>/<type>/<slug>.review.md       a location's open and sent snapshot annotations
    <out>/outline/<NNN>-<slug>.md       outline nodes in manuscript order

The output is deterministic: no timestamps or database ids in file names or
content, and only fields that carry story. Annie is the source of truth, so the
directory is rewritten from scratch every time, and a git diff of it is the
change.

Images live in Annie's private storage bucket. Each is kept in <image-cache>
under its sha256 and downloaded only when no cached copy has that sha256: the
Supabase egress quota is small and the export runs often. A download needs
ANNIE_SUPABASE_URL and ANNIE_SUPABASE_SERVICE_ROLE_KEY in the environment and
only ever GETs. Cached images no longer exported are deleted.

Usage: python3 -I annie_export.py <out-dir> <image-cache> < export.json
"""

import hashlib
import html
import json
import os
import re
import shutil
import sys
import urllib.parse
import urllib.request
from pathlib import Path

IMAGE_BUCKET = "location-images"

README = """# Annie mirror (generated: do not edit)

This directory is a read-only mirror of the game's story bible in Annie, written
by ops/cron/story-sync.sh. Every sync rewrites it from scratch, so a hand edit
is lost. Change the story in Annie.

`story/CANON.md` is the curated story the game implements. The story-sync
workflow promotes only settled material from here into it. Anything tentative,
hedged or tagged `open` goes to `story/PENDING.md` instead.

A location can also carry:

- `location/<slug>/<NN>-<kind>.webp`: its images (reference, mood or sketch), in
  Annie's order. The location's Markdown file lists them with their captions.
- `location/<slug>.map.json`: its top-down map. `widthM` × `heightM` metres;
  each item has a `kind` (object, character, exit, area, note), a `label`, a
  `description`, its centre `x`, `y` and size `w`, `h` in metres from the map's
  top-left corner (y down), `rotation` in degrees clockwise, an area's `points`
  relative to its centre, and an optional `link` to a story object by `name` and
  `slug` (the path of its file here, without `.md`; `null` when the linked
  object was deleted). `background` is the image the map is drawn over, `null`
  when the map has none.
- `location/<slug>.review.md`: notes and name or description changes the owner
  made on game snapshots of the location and that are not resolved yet. Regions
  are in the snapshot's screenshot pixels; the screenshot itself is not here,
  the block names its build and sha256, or says `pruned` when that snapshot is
  gone.
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


def object_file(obj: dict, related: list[str], images: list[tuple[str, dict]], map_file: str | None) -> str:
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
    if images:
        lines += ["## Images", ""]
        for path, image in images:
            cover = " (cover)" if image.get("isCover") else ""
            caption = f": {image['caption'].strip()}" if (image.get("caption") or "").strip() else ""
            lines.append(f"- `{path}`{cover}{caption}")
        lines.append("")
    if map_file:
        lines += ["## Map", "", f"`{map_file}`", ""]
    return "\n".join(lines)


def image_bytes(image: dict, cache: Path) -> bytes:
    """The image's bytes from the cache, downloading them only when the cache lacks its sha256."""
    cached = cache / f"{image['sha256']}.webp"
    if cached.exists():
        return cached.read_bytes()
    data = download(image["storagePath"])
    if hashlib.sha256(data).hexdigest() != image["sha256"]:
        raise SystemExit(f"image {image['storagePath']} does not match its sha256 in Annie")
    cache.mkdir(parents=True, exist_ok=True)
    partial = cached.with_suffix(".part")
    partial.write_bytes(data)
    partial.replace(cached)
    return data


def download(storage_path: str) -> bytes:
    base = os.environ.get("ANNIE_SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("ANNIE_SUPABASE_SERVICE_ROLE_KEY", "")
    if not base or not key:
        raise SystemExit("ANNIE_SUPABASE_URL and ANNIE_SUPABASE_SERVICE_ROLE_KEY are needed to download location images")
    if not base.startswith("https://"):
        raise SystemExit("ANNIE_SUPABASE_URL must be an https:// URL: the storage key is sent with every download")
    url = f"{base}/storage/v1/object/authenticated/{IMAGE_BUCKET}/{urllib.parse.quote(storage_path)}"
    request = urllib.request.Request(url, headers={"apikey": key, "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def map_json(m: dict, links: dict[str, tuple[str, str]], image_paths: dict[str, str]) -> str:
    items = []
    for item in m.get("items") or []:
        out = {k: item[k] for k in ("kind", "label", "description", "x", "y", "w", "h", "rotation", "points") if k in item}
        link_id = item.get("storyObjectId") or item.get("targetLocationId")
        if link_id:
            link = links.get(link_id)
            out["link"] = {"name": link[0], "slug": link[1]} if link else None
        items.append(out)
    items.sort(key=lambda i: (i["kind"], i.get("label", ""), i["x"], i["y"], json.dumps(i, sort_keys=True)))
    doc = {"widthM": m["widthM"], "heightM": m["heightM"],
           "background": image_paths.get(m.get("backgroundImageId") or ""), "items": items}
    return json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def number(v: float) -> str:
    return f"{v:g}"


def region_text(region: dict | None) -> str | None:
    if not region:
        return None
    if region["type"] == "point":
        return f"point ({number(region['x'])}, {number(region['y'])})"
    if region["type"] == "rect":
        return f"rect at ({number(region['x'])}, {number(region['y'])}), {number(region['w'])} × {number(region['h'])}"
    return "path " + " → ".join(f"({number(x)}, {number(y)})" for x, y in region["points"])


def review_file(name: str, annotations: list[dict], links: dict[str, tuple[str, str]]) -> str:
    lines = [f"# Review notes: {name}", "",
             "Open and sent annotations on game snapshots of this location, oldest first.", ""]
    for i, a in enumerate(annotations, 1):
        lines += [f"## {i}. {a['kind']}", ""]
        if a.get("thingKey"):
            thing = f"`{a['thingKey']}`" + (f" ({a['thingName']})" if a.get("thingName") else "")
            lines.append(f"- **Thing:** {thing}")
        region = region_text(a.get("region"))
        if region:
            lines.append(f"- **Region:** {region} (screenshot pixels)")
        if a.get("storyObjectId"):
            link = links.get(a["storyObjectId"])
            if link:
                lines.append(f"- **About:** {link[0]} (`{link[1]}`)")
        if a.get("build"):
            lines.append(f"- **Snapshot:** build `{a['build']}`, sha256 `{a['snapshotSha256']}`")
        else:
            lines.append("- **Snapshot:** pruned")
        lines += ["", a["text"].rstrip(), ""]
    return "\n".join(lines)


def main() -> None:
    out, cache = Path(sys.argv[1]), Path(sys.argv[2])
    data = json.load(sys.stdin)
    objects = data.get("objects") or []
    nodes = data.get("nodes") or []
    rels = data.get("relationships") or []
    images = data.get("images") or []
    maps = {m["storyObjectId"]: m for m in data.get("maps") or []}

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

    paths: dict[str, Path] = {}
    used: set[Path] = set()
    for obj in sorted(objects, key=lambda o: (o["type"], o["name"].lower(), o["id"])):
        path = out / slug(obj["type"]) / f"{slug(obj['name'])}.md"
        n = 2
        while path in used:
            path = out / slug(obj["type"]) / f"{slug(obj['name'])}-{n}.md"
            n += 1
        used.add(path)
        paths[obj["id"]] = path
    links = {oid: (names[oid], path.relative_to(out).with_suffix("").as_posix()) for oid, path in paths.items()}

    by_object: dict[str, list[dict]] = {}
    for image in sorted(images, key=lambda i: (i["orderIndex"], i["id"])):
        by_object.setdefault(image["storyObjectId"], []).append(image)
    image_paths: dict[str, str] = {}
    kept: set[str] = set()
    for oid, object_images in by_object.items():
        folder = paths[oid].with_suffix("")
        folder.mkdir(parents=True, exist_ok=True)
        for i, image in enumerate(object_images, 1):
            file = folder / f"{i:02d}-{slug(image['kind'])}.webp"
            file.write_bytes(image_bytes(image, cache))
            kept.add(f"{image['sha256']}.webp")
            image_paths[image["id"]] = file.relative_to(out).as_posix()
    if cache.exists():
        for stale in cache.iterdir():
            if stale.name not in kept:
                stale.unlink()

    annotations: dict[str, list[dict]] = {}
    for a in sorted(data.get("annotations") or [], key=lambda a: (a["createdAt"], a["id"])):
        annotations.setdefault(a["locationId"], []).append(a)

    for obj in objects:
        oid, path = obj["id"], paths[obj["id"]]
        path.parent.mkdir(parents=True, exist_ok=True)
        object_images = [((out / image_paths[i["id"]]).relative_to(path.parent).as_posix(), i)
                         for i in by_object.get(oid, [])]
        map_file = None
        if oid in maps:
            map_path = path.with_suffix(".map.json")
            map_path.write_text(map_json(maps[oid], links, image_paths))
            map_file = map_path.name
        if oid in annotations:
            path.with_suffix(".review.md").write_text(review_file(obj["name"], annotations[oid], links))
        path.write_text(object_file(obj, related.get(oid, []), object_images, map_file))

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
