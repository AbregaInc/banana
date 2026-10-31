#!/usr/bin/env python3
"""Render this editorial draft locally. Never writes the public site or deploys.
Run: uv run --with markdown-it-py==4.0.0 python docs/blog/calendar-renderer/drafts/preview.py
"""
from pathlib import Path
from datetime import date
import json
import re
import shutil
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / 'LandingPage'))
from build_content import build

SLUG = 'optimizing-calendar-rendering-with-ai'
content = Path('/tmp/banana-hn-draft-content')
out = Path('/tmp/banana-hn-draft-preview')
content.mkdir(exist_ok=True)
old = content / 'ai-hill-climb.md'
if old.exists(): old.unlink()
shutil.copyfile(HERE / 'ai-hill-climb.md', content / (SLUG + '.md'))
shutil.copytree(ROOT / 'LandingPage/site', out, dirs_exist_ok=True)
build(out, content, date.today(), preview=True)
page = out / 'blog' / SLUG / 'index.html'
assets = page.parent / 'assets'
shutil.copytree(HERE / 'assets', assets, dirs_exist_ok=True)
s = page.read_text()
hero = '''<figure class="calendar-hero">
<video id="calendar-fixture-video" loop muted playsinline controls preload="metadata" poster="assets/ipad-day-performance.png" width="1600" height="1200" aria-label="Banana iPad Day and Week calendar performance fixture, scrolling through populated views">
<source src="assets/ipad-calendar-fixture.mp4?v=week-motion-2" type="video/mp4">
<a href="assets/ipad-calendar-fixture.mp4?v=week-motion-2">Watch the iPad calendar fixture</a>
</video><figcaption>Day and Week on iPad · 3,000 synthetic events across 12 calendars.</figcaption></figure>
<script>
(() => {
 const video = document.getElementById('calendar-fixture-video');
 const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
 const update = () => {
   if (reducedMotion.matches) { video.pause(); video.removeAttribute('autoplay'); }
   else { video.autoplay = true; video.muted = true; video.play().catch(() => {}); }
 };
 update(); reducedMotion.addEventListener('change', update);
})();
</script>'''
link = '<p><a href="calendar-demo.html">Day and Week performance fixtures</a></p>'
assert link in s
s = s.replace(link, hero)
diagram = '<p><a href="calendar-viewport.html">Diagram: how the calendar chooses which event views to build</a></p>'
assert diagram in s
s = s.replace(diagram, '<iframe title="How the calendar builds event views" src="calendar-viewport.html" loading="lazy" style="width:100%;height:760px;border:0"></iframe>')
css = '''<style>
.calendar-hero{width:min(960px,calc(100vw - 48px));max-width:none;margin:28px 0 36px}.calendar-hero video{display:block;width:100%;height:auto;border:1px solid #e6dccb;border-radius:8px;background:#fff}.calendar-hero figcaption{font-size:12px;color:#625a78;margin-top:12px}@media(max-width:650px){.calendar-hero{width:100%}}
</style>'''
s = s.replace('</head>', css + '</head>')
image_url = 'https://bananatheapp.com/assets/img/blog/calendar-rendering-ai-og.png'
s = s.replace('https://bananatheapp.com/assets/img/social.png', image_url)
s = re.sub(r'<meta property="og:image:alt" content="[^"]*">', '<meta property="og:image:alt" content="Banana Day and Week performance fixtures beside the calendar rendering result: 95.05 ms to 38.22 ms of preparation work.">', s)
s = s.replace('</head>', '<meta property="og:image:type" content="image/png"><meta name="twitter:image" content="'+image_url+'"><meta name="twitter:image:alt" content="Banana calendar Day and Week performance fixtures and a 60 percent reduction in measured preparation work."></head>')
page.write_text(s)
for filename in ['calendar-viewport.html', 'calendar-demo.html', 'og-image.html']:
    source = HERE / filename
    if source.exists(): shutil.copyfile(source, page.parent / filename)
og = HERE / 'assets/calendar-rendering-ai-og.png'
if og.exists():
    target = out / 'assets/img/blog/calendar-rendering-ai-og.png'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(og, target)
# Keep the previously shared local link working, with the new canonical URL.
alias = out / 'blog/ai-hill-climb'
shutil.copytree(page.parent, alias, dirs_exist_ok=True)
print('Local preview: http://localhost:8896/blog/' + SLUG + '/')
assert s.count('<table>') == 4
assert 'event artwork' not in s.lower()
assert 'noindex,nofollow' in s
