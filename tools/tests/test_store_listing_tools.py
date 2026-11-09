"""The store tools work on one listing at a time: the calendar-only flavour's text, images and
platforms, and a whole-listing run clears the draft groups that listing has no images for."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "app-store"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, TOOL / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


listing = load("listing", "listing.py")
upload = load("upload_assets", "upload-assets.py")
draft = load("update_draft", "update-draft.py")


class ListingTests(unittest.TestCase):
    def test_full_listing_has_every_platform(self):
        full = listing.load(None)
        self.assertEqual(full["platforms"], ["iphone", "ipad", "watch", "mac"])
        self.assertEqual(full["package"], listing.ROOT / "AppStore/Generated")

    def test_calendar_only_has_no_watch_and_its_own_folders(self):
        calendar = listing.load("calendar-only")
        self.assertEqual(calendar["platforms"], ["iphone", "ipad", "mac"])
        self.assertEqual(calendar["package"], listing.ROOT / "AppStore/Generated/calendar-only")
        self.assertEqual(calendar["metadata"], TOOL / "metadata/calendar-only/en-US")
        self.assertTrue((calendar["metadata"] / "review_notes.txt").exists())


class UploadPlanTests(unittest.TestCase):
    def test_platforms_follow_the_listing(self):
        self.assertEqual(upload.listing_platforms("all", ["iphone", "ipad", "mac"]), ["iphone", "ipad", "mac"])
        with self.assertRaises(SystemExit):
            upload.listing_platforms("watch", ["iphone", "ipad", "mac"])

    def test_capture_evidence_needs_only_the_listing_platforms(self):
        self.assertEqual(upload.required_captures(["iphone"], ["iphone", "ipad", "mac"], False), {"iphone", "mac"})
        self.assertEqual(upload.required_captures(["iphone"], ["iphone", "ipad", "watch", "mac"], False), {"iphone", "mac", "watch"})

    def test_whole_listing_run_clears_groups_it_has_no_images_for(self):
        desired = {("ios", "APP_SCREENSHOT", "IPHONE"): ["01-plan.png"]}
        existing = {("ios", "APP_SCREENSHOT", "IPHONE"): ["old-plan"],
                    ("ios", "APP_SCREENSHOT", "WATCH"): ["01-workout"],
                    ("ios", "PRODUCT_PAGE_HEADER_ASSET", "DEFAULT"): ["header"]}
        rows = {r["group"]: r["action"] for r in upload.draft_diff(desired, existing, True, {"APP_SCREENSHOT"})}
        self.assertEqual(rows, {"IPHONE": "replace", "WATCH": "clear"})  # the header is another kind: untouched

    def test_one_platform_run_clears_nothing_else(self):
        desired = {("ios", "APP_SCREENSHOT", "IPHONE"): ["01-plan.png"]}
        existing = {("ios", "APP_SCREENSHOT", "WATCH"): ["01-workout"]}
        self.assertEqual([r["group"] for r in upload.draft_diff(desired, existing, False, {"APP_SCREENSHOT"})], ["IPHONE"])


class DraftTextTests(unittest.TestCase):
    def test_only_present_files_are_sent(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "description.txt").write_text("Plan the day.\n")
            self.assertEqual(draft.attributes(folder, draft.VERSION_FIELDS), {"description": "Plan the day."})

    def test_diff_lists_only_changed_fields(self):
        before = [{"type": "appStoreReviewDetails", "id": "r", "attributes": {"notes": "old"}},
                  {"type": "appInfoLocalizations", "id": "i", "attributes": {"name": "Banana", "subtitle": "x"}}]
        patches = [{"path": "/v1/appStoreReviewDetails/r", "data": {"attributes": {"notes": "new"}}},
                   {"path": "/v1/appInfoLocalizations/i", "data": {"attributes": {"name": "Banana", "subtitle": "y"}}}]
        self.assertEqual([(c["field"], c["old"], c["new"]) for c in draft.changes(before, patches)],
                         [("notes", "old", "new"), ("subtitle", "x", "y")])

    def test_calendar_only_review_notes_fit_apples_limit(self):
        notes = (listing.load("calendar-only")["metadata"] / "review_notes.txt").read_text().strip()
        self.assertLessEqual(len(notes), draft.NOTES_LIMIT)


if __name__ == "__main__":
    unittest.main()
