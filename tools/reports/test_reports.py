#!/usr/bin/env python3
"""python3 tools/reports/test_reports.py: the anonymiser keeps markup and drops what is the sender's."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import reports  # noqa: E402

SAMPLE = """<html><head><style>.card{background:url(https://tracker.example/x.png);width:600px}</style>
<script>track()</script></head><body><!-- sender note -->
<table class="card gmail_quote" cellpadding="12" data-user="abc123"><tr><td style="font-weight:bold;background:url('https://brand.example/bg.png')">Invoice 48213 for Rosalind Pike</td>
<td><a href="https://shop.example/orders/48213?u=rosalind">View order</a> or write to rosalind.pike@mailbox.example</td></tr></table>
<img src="https://cdn.example/logo.png" alt="Pike &amp; Sons"><img src="cid:logo@part">&nbsp;</body></html>"""


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


if __name__ == "__main__":
    unittest.main()
