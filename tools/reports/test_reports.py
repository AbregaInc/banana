#!/usr/bin/env python3
"""python3 tools/reports/test_reports.py: the anonymiser keeps markup and drops what is the sender's."""
import argparse
import json
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import reports  # noqa: E402

SAMPLE = """<html><head><style>.card{background:url(https://tracker.example/x.png);width:600px}</style>
<script>track()</script></head><body><!-- sender note -->
<table class="card gmail_quote" cellpadding="12" data-user="abc123"><tr><td style="font-weight:bold;background:url('https://brand.example/bg.png')">Invoice 48213 for Rosalind Pike</td>
<td><a href="https://shop.example/orders/48213?u=rosalind">View order</a> or write to rosalind.pike@mailbox.example</td></tr></table>
<img src="https://cdn.example/logo.png" alt="Pike &amp; Sons"><img src="cid:logo@part">&nbsp;</body></html>"""


class ReviewedAIFixtureTests(unittest.TestCase):
    def setUp(self):
        self.templates = {"cases": [{"id": "identity", "request": {
            "instructions": "Use the available tools or reply.",
            "messages": [{"role": "user", "text": "Template prompt"}],
            "tools": [{"name": "day_plan", "parameters": {"properties": {"date": {}}}}],
        }}]}
        self.review = {
            "id": "calendar-tomorrow", "approved": True, "domain": "calendar", "template": "identity",
            "reason": "Check the requested day.",
            "messages": [{"role": "user", "text": "What is on my calendar tomorrow?"}],
            "expected": {"tool": "day_plan", "arguments": {"date": "tomorrow"}},
        }

    def test_approved_correction_replaces_template_history_and_uses_its_tools(self):
        fixture = reports.reviewed_ai_fixture([self.review], self.templates)
        case = fixture["cases"][0]
        self.assertEqual(case["request"]["messages"], self.review["messages"])
        self.assertEqual(case["expected"], self.review["expected"])
        self.assertEqual(case["request"]["tools"], self.templates["cases"][0]["request"]["tools"])

    def test_unreviewed_or_unobservable_cases_cannot_be_exported(self):
        with self.assertRaisesRegex(ValueError, "No approved"):
            reports.reviewed_ai_fixture([dict(self.review, approved=False)], self.templates)
        with self.assertRaisesRegex(ValueError, "observable"):
            reports.reviewed_ai_fixture([dict(self.review, expected={"tool": None})], self.templates)
        with self.assertRaisesRegex(ValueError, "must exist"):
            reports.reviewed_ai_fixture([dict(self.review, expected={"tool": "invented"})], self.templates)

    def test_export_creates_a_private_file_without_overwriting_existing_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evaluation = root / "tools/pi-evaluation"
            evaluation.mkdir(parents=True)
            (evaluation / "cases.json").write_text(json.dumps(self.templates))
            reviews = root / "review.json"
            reviews.write_text(json.dumps([self.review]))
            args = argparse.Namespace(name="calendar-case", review=reviews)
            with patch.multiple(reports, ROOT=root, EVALS=root / "private/ai-evals"):
                reports.cmd_ai_fixture(args)
                with self.assertRaises(FileExistsError):
                    reports.cmd_ai_fixture(args)
            fixture = root / "private/ai-evals/reviewed/calendar-case.json"
            self.assertEqual(stat.S_IMODE(fixture.stat().st_mode), 0o600)
            self.assertEqual(json.loads(fixture.read_text())["cases"][0]["id"], self.review["id"])

    def test_a_reviewed_mail_limitation_can_reject_a_false_action_claim(self):
        self.review["domain"] = "mail"
        self.review["expected"] = {"tool": None, "textIncludes": "can’t send", "textExcludes": ["sent the message"]}
        case = reports.reviewed_ai_fixture([self.review], self.templates)["cases"][0]
        self.assertEqual(case["expected"]["textExcludes"], ["sent the message"])


class AnonymiseTests(unittest.TestCase):
    def setUp(self):
        parser = reports.Anonymiser()
        parser.feed(SAMPLE)
        parser.close()
        self.out = "".join(parser.out)

    def test_the_senders_words_links_and_addresses_go(self):
        for private in ("Rosalind", "Pike", "48213", "shop.example", "rosalind.pike", "mailbox.example",
                        "tracker.example", "cdn.example", "brand.example", "track()", "sender note", "abc123", "Invoice", "View order"):
            self.assertNotIn(private, self.out, private)

    def test_the_markup_stays(self):
        card = reports.class_stand_in("card")
        for kept in (f'class="{card} gmail_quote"', f".{card}{{", 'cellpadding="12"', "font-weight:bold", "<table", "</td>", "width:600px",
                     "&nbsp;", 'src="cid:picture-2"', 'href="https://plan.example/link-1"', "noor@plan.example"):
            self.assertIn(kept, self.out, kept)

    def test_a_word_always_becomes_the_same_stand_in(self):
        self.assertEqual(reports.anonymise_text("View order"), reports.anonymise_text("View order"))
        self.assertIn(reports.anonymise_text("View order"), reports.anonymise_text("Please View order now"))
        self.assertEqual(len(reports.anonymise_text("48213")), 5)


class MailSourceRecoveryTests(unittest.TestCase):
    def test_viewer_image_urls_become_cid_sources_without_changing_other_markup(self):
        source = '<p>keep</p><img src="banana-mail-image://message/picture%40part" width="320">'
        self.assertEqual(reports.restore_inline_image_sources(source),
                         '<p>keep</p><img src="cid:picture@part" width="320">')

    def test_remote_images_and_text_are_not_rewritten(self):
        source = '<img src="https://plan.example/picture"><p>banana-mail-image://message/text</p>'
        self.assertEqual(reports.restore_inline_image_sources(source), source)

    def test_similar_attributes_and_quoted_example_text_are_untouched(self):
        source = '<img data-src="banana-mail-image://message/data" alt="example src=\'banana-mail-image://message/text\'" src="banana-mail-image://message/actual">'
        expected = source.replace('src="banana-mail-image://message/actual"', 'src="cid:actual"')
        self.assertEqual(reports.restore_inline_image_sources(source), expected)

    def test_encoded_quotes_remain_attribute_data(self):
        source = "<IMG SRC='banana-mail-image://message/a%27b%22c'>"
        self.assertEqual(reports.restore_inline_image_sources(source),
                         "<IMG SRC='cid:a&#x27;b&quot;c'>")


if __name__ == "__main__":
    unittest.main()
