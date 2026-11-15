"""Unit tests for ops/cron/lib/annie_export.py: python3 -m pytest ops/cron/tests/test_annie_export.py"""

from __future__ import annotations

import copy
import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "ops/cron/lib"))
import annie_export as ae

HALL_SKETCH = b"sketch of the hall"
HALL_MOOD = b"mood of the hall"
STORAGE = {"p/hall-sketch/full.webp": HALL_SKETCH, "p/hall-mood/full.webp": HALL_MOOD}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


BIBLE = {
    "objects": [
        {"id": "hall", "type": "LOCATION", "name": "The Hall", "description": "A long hall.", "notes": "", "role": None, "tags": ""},
        {"id": "yard", "type": "LOCATION", "name": "The Yard", "description": "Grass.", "notes": "", "role": None, "tags": ""},
        {"id": "cat", "type": "CHARACTER", "name": "The Cat", "description": "A cat.", "notes": "", "role": None, "tags": ""},
    ],
    "relationships": [],
    "nodes": [],
    "images": [
        {"id": "img2", "storyObjectId": "hall", "kind": "mood", "caption": "At night", "orderIndex": 1,
         "isCover": False, "storagePath": "p/hall-mood/full.webp", "sha256": sha(HALL_MOOD)},
        {"id": "img1", "storyObjectId": "hall", "kind": "sketch", "caption": "", "orderIndex": 0,
         "isCover": True, "storagePath": "p/hall-sketch/full.webp", "sha256": sha(HALL_SKETCH)},
    ],
    "maps": [
        {"storyObjectId": "hall", "widthM": 12, "heightM": 4, "backgroundImageId": "img1", "items": [
            {"id": "i2", "kind": "exit", "label": "Door", "description": "", "x": 11.5, "y": 2, "w": 1, "h": 1,
             "rotation": 0, "targetLocationId": "yard"},
            {"id": "i1", "kind": "character", "label": "", "description": "Sleeps here", "x": 3, "y": 2, "w": 1,
             "h": 1, "rotation": 90, "storyObjectId": "cat"},
            {"id": "i3", "kind": "object", "label": "Lamp", "description": "", "x": 1, "y": 1, "w": 1, "h": 1,
             "rotation": 0, "storyObjectId": "gone"},
        ]},
    ],
    "annotations": [
        {"id": "a2", "locationId": "hall", "kind": "description", "thingKey": None, "thingName": None,
         "region": None, "text": "The hall should be shorter.", "storyObjectId": None, "build": None,
         "snapshotSha256": None, "createdAt": "2026-11-14T10:00:00"},
        {"id": "a1", "locationId": "hall", "kind": "note", "thingKey": "lamp-1", "thingName": "Lamp",
         "region": {"type": "rect", "x": 10, "y": 20, "w": 30.5, "h": 40}, "text": "Too bright.",
         "storyObjectId": "cat", "build": "v1.2", "snapshotSha256": "abc123", "createdAt": "2026-11-13T10:00:00"},
    ],
}


class ExportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.cache = self.tmp / "cache"
        self.downloads: list[str] = []
        self.storage = dict(STORAGE)

    def export(self, bible: dict, out: str = "out") -> Path:
        def download(path: str) -> bytes:
            self.downloads.append(path)
            return self.storage[path]

        target = self.tmp / out
        with mock.patch.object(ae, "download", download), \
                mock.patch.object(sys, "argv", ["annie_export.py", str(target), str(self.cache)]), \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(bible))):
            ae.main()
        return target

    def files(self, out: Path) -> dict[str, bytes]:
        return {p.relative_to(out).as_posix(): p.read_bytes() for p in sorted(out.rglob("*")) if p.is_file()}

    def test_a_location_exports_its_images_in_order_with_captions(self) -> None:
        out = self.export(BIBLE)
        self.assertEqual((out / "location/the-hall/01-sketch.webp").read_bytes(), HALL_SKETCH)
        self.assertEqual((out / "location/the-hall/02-mood.webp").read_bytes(), HALL_MOOD)
        md = (out / "location/the-hall.md").read_text()
        self.assertIn("- `the-hall/01-sketch.webp` (cover)\n", md)
        self.assertIn("- `the-hall/02-mood.webp`: At night\n", md)
        self.assertIn("## Map\n\n`the-hall.map.json`\n", md)

    def test_the_map_links_by_name_and_slug_sorted_without_ids(self) -> None:
        out = self.export(BIBLE)
        doc = json.loads((out / "location/the-hall.map.json").read_text())
        self.assertEqual(doc["widthM"], 12)
        self.assertEqual(doc["background"], "location/the-hall/01-sketch.webp")
        self.assertEqual([i["kind"] for i in doc["items"]], ["character", "exit", "object"])
        self.assertEqual(doc["items"][0]["link"], {"name": "The Cat", "slug": "character/the-cat"})
        self.assertEqual(doc["items"][1]["link"], {"name": "The Yard", "slug": "location/the-yard"})
        self.assertIsNone(doc["items"][2]["link"])
        self.assertNotIn('"id"', (out / "location/the-hall.map.json").read_text())

    def test_review_lists_annotations_oldest_first_with_region_and_build(self) -> None:
        out = self.export(BIBLE)
        review = (out / "location/the-hall.review.md").read_text()
        self.assertLess(review.index("Too bright."), review.index("The hall should be shorter."))
        self.assertIn("- **Thing:** `lamp-1` (Lamp)\n", review)
        self.assertIn("- **Region:** rect at (10, 20), 30.5 × 40 (screenshot pixels)\n", review)
        self.assertIn("- **About:** The Cat (`character/the-cat`)\n", review)
        self.assertIn("- **Snapshot:** build `v1.2`, sha256 `abc123`\n", review)
        self.assertIn("- **Snapshot:** pruned\n", review)

    def test_a_path_region_lists_its_points(self) -> None:
        drawn = copy.deepcopy(BIBLE)
        drawn["annotations"][1]["region"] = {"type": "path", "points": [[1, 2], [3.5, 4]]}
        review = (self.export(drawn) / "location/the-hall.review.md").read_text()
        self.assertIn("- **Region:** path (1, 2) → (3.5, 4) (screenshot pixels)\n", review)

    def test_a_second_export_is_identical_and_downloads_nothing(self) -> None:
        first = self.files(self.export(BIBLE, "one"))
        self.assertEqual(sorted(self.downloads), sorted(STORAGE))
        self.downloads.clear()
        second = self.files(self.export(BIBLE, "two"))
        self.assertEqual(first, second)
        self.assertEqual(self.downloads, [])

    def test_a_changed_image_changes_only_its_location_and_downloads_only_it(self) -> None:
        first = self.files(self.export(BIBLE, "one"))
        self.downloads.clear()
        changed = copy.deepcopy(BIBLE)
        self.storage["p/hall-mood-2/full.webp"] = b"new mood"
        changed["images"][0].update(storagePath="p/hall-mood-2/full.webp", sha256=sha(b"new mood"))
        second = self.files(self.export(changed, "two"))
        self.assertEqual(self.downloads, ["p/hall-mood-2/full.webp"])
        self.assertEqual({k for k in first.keys() | second.keys() if first.get(k) != second.get(k)},
                         {"location/the-hall/02-mood.webp"})
        self.assertFalse((self.cache / f"{sha(HALL_MOOD)}.webp").exists())

    def test_a_changed_map_changes_only_its_map_file(self) -> None:
        first = self.files(self.export(BIBLE, "one"))
        changed = copy.deepcopy(BIBLE)
        changed["maps"][0]["items"][0]["x"] = 10
        second = self.files(self.export(changed, "two"))
        self.assertEqual({k for k in first.keys() | second.keys() if first.get(k) != second.get(k)},
                         {"location/the-hall.map.json"})

    def test_a_location_with_neither_is_unchanged_from_the_plain_export(self) -> None:
        plain = {k: BIBLE[k] for k in ("objects", "relationships", "nodes")}
        before = self.files(self.export(plain, "plain"))
        after = self.files(self.export(BIBLE, "full"))
        self.assertEqual(after["location/the-yard.md"], before["location/the-yard.md"])
        self.assertEqual(after["character/the-cat.md"], before["character/the-cat.md"])
        self.assertFalse(any(k.startswith("location/the-yard.") and not k.endswith(".md") for k in after))

    def test_an_image_whose_bytes_do_not_match_its_sha256_fails_the_export(self) -> None:
        bad = copy.deepcopy(BIBLE)
        bad["images"][0]["sha256"] = sha(b"something else")
        with self.assertRaises(SystemExit):
            self.export(bad)
        self.assertFalse((self.cache / f"{sha(b'something else')}.webp").exists())

    def test_a_download_without_storage_credentials_fails_the_export(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True), self.assertRaises(SystemExit) as raised, \
                mock.patch.object(sys, "argv", ["annie_export.py", str(self.tmp / "out"), str(self.cache)]), \
                mock.patch.object(sys, "stdin", io.StringIO(json.dumps(BIBLE))):
            ae.main()
        self.assertIn("ANNIE_SUPABASE_URL", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
