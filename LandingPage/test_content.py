"""Publishing failures must never silently become public pages."""
from datetime import date
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from build_content import build, read_post, MD

TODAY = date(2026, 10, 27)
SOURCE = '''+++
title = "Publishing test article"
description = "A test description for publication rules."
published = 2026-10-27
updated = 2026-10-27
author = "Banana team"
category = "Engineering"
draft = false
+++
A paragraph for the publishing fixture.
'''

class PublishingTests(unittest.TestCase):
    def test_drafts_and_future_posts_are_not_in_html_rss_or_sitemap(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); content = root / 'posts'; content.mkdir()
            (content/'visible.md').write_text(SOURCE)
            (content/'draft.md').write_text(SOURCE.replace('draft = false','draft = true').replace('Publishing test article','UNPUBLISHED DRAFT'))
            (content/'future.md').write_text(SOURCE.replace('2026-10-27','2027-10-27').replace('Publishing test article','FUTURE POST'))
            out = root/'site'; build(out, content, TODAY)
            self.assertTrue((out/'blog/visible/index.html').exists())
            self.assertFalse((out/'blog/draft/index.html').exists())
            self.assertFalse((out/'blog/future/index.html').exists())
            for p in out.rglob('*'):
                if p.is_file():
                    self.assertNotIn('UNPUBLISHED DRAFT',p.read_text()); self.assertNotIn('FUTURE POST',p.read_text())
    def test_unpublishing_removes_the_previously_generated_page(self):
        with TemporaryDirectory() as temp:
            root = Path(temp); content=root/'posts';content.mkdir(); p=content/'post.md';p.write_text(SOURCE)
            out=root/'site';build(out,content,TODAY)
            self.assertTrue((out/'blog/post/index.html').is_file())
            p.write_text(SOURCE.replace('draft = false','draft = true'));build(out,content,TODAY)
            self.assertFalse((out/'blog/post/index.html').exists())
            self.assertNotIn('/blog/post/',(out/'sitemap.xml').read_text())
    def test_preview_can_show_drafts_but_marks_pages_noindex(self):
        with TemporaryDirectory() as temp:
            root=Path(temp);content=root/'posts';content.mkdir()
            (content/'draft.md').write_text(SOURCE.replace('draft = false','draft = true'))
            build(root/'site',content,TODAY,preview=True)
            page=(root/'site/blog/draft/index.html').read_text()
            self.assertIn('noindex,nofollow',page);self.assertIn('Local preview',page)
    def test_missing_explicit_draft_state_and_bad_dates_fail(self):
        for text in [SOURCE.replace('draft = false',''), SOURCE.replace('updated = 2026-10-27','updated = 2026-10-26'), SOURCE.replace('updated = 2026-10-27','updated = 2026-10-28')]:
            with TemporaryDirectory() as temp:
                p=Path(temp)/'post.md';p.write_text(text)
                with self.assertRaises(ValueError): read_post(p,TODAY)
    def test_no_raw_html_or_executable_link_is_rendered(self):
        rendered=MD.render('<script>alert(1)</script>\n\n[x](javascript:alert(1))')
        self.assertNotIn('<script>',rendered);self.assertNotIn('href="javascript:',rendered)
    def test_table_too_wide_for_a_phone_becomes_labelled_cards(self):
        wide=MD.render('| View | Host | p50 | p95 | Max |\n| --- | --- | ---: | ---: | ---: |\n| Week | Old host | 14.9 · 15.1 ms | 46.1 · 47.6 ms | 90.9 · 100.9 ms |\n')
        self.assertIn('class="table-scroll table-stack"',wide);self.assertIn('<table role="table">',wide)
        self.assertIn('data-label="p95"',wide);self.assertIn('role="cell"',wide);self.assertIn('class="measure"',wide)
    def test_table_that_fits_a_phone_stays_a_table(self):
        narrow=MD.render('| Launch | Day view | Blocks drawn |\n| --- | --- | ---: |\n| 1 | Old | 108 |\n')
        self.assertIn('<div class="table-scroll" ',narrow);self.assertNotIn('data-label',narrow);self.assertNotIn('role="cell"',narrow)
    def test_diagram_caption_link_is_marked_to_open_the_dialog(self):
        src='/assets/blog/optimizing-calendar-rendering-with-ai/calendar-viewport.svg'
        rendered=MD.render(f'```diagram\nsrc: {src}\ncaption: A diagram\n```\n')
        self.assertIn(f'<a class="diagram-full" href="{src}">Open full size</a>',rendered)
        self.assertIn('.diagram-full',(Path(__file__).parent/'site/editorial.js').read_text())
    def test_no_duplicate_h1_or_unsized_markdown_image(self):
        for extra in ['\n# Another title\n','\n![image](/assets/img/social.png)\n']:
            with TemporaryDirectory() as temp:
                p=Path(temp)/'post.md';p.write_text(SOURCE+extra)
                with self.assertRaises(ValueError):read_post(p,TODAY)
    def test_metadata_is_escaped_in_html_and_schema(self):
        with TemporaryDirectory() as temp:
            root=Path(temp);content=root/'posts';content.mkdir()
            (content/'post.md').write_text(SOURCE.replace('Publishing test article','</script><b>Title</b>'))
            build(root/'site',content,TODAY)
            text=(root/'site/blog/post/index.html').read_text()
            self.assertNotIn('</script><b>',text);self.assertIn('&lt;b&gt;Title',text);self.assertIn('\\u003c',text)

if __name__=='__main__':unittest.main()
