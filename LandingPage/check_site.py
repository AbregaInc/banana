#!/usr/bin/env python3
"""The website's own rules, checked before a deploy.

    python3 LandingPage/check_site.py [folder]

Reads `LandingPage/site/` (or the folder named) as it would be served and fails (exit 1) when:
  - a page points at a file that isn't there, or an image has no size or no `alt`;
  - a link to TestFlight isn't the public one, or the page links to an App Store page that
    doesn't exist yet;
  - the copy says something `HANDOFF.md` rules out ("Claims to avoid"), names a feature that
    was switched off, quotes a price, or drops one of the qualifications it must carry;
  - the front page grows past its weight budget;
  - the link-preview video is missing, isn't a plain MP4, or is past what Messages downloads.

It also says whether the page is still hidden from search engines, which is a decision, not a
fault. `BananaTests/StoreListingTests.swift` holds the same rules for the App Store listing.
"""
from __future__ import annotations

import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

sys.dont_write_bytecode = True

try:
    from PIL import Image   # only to compare an image's stated shape with its file
except ImportError:
    Image = None

SITE = Path(__file__).resolve().parent / "site"
TESTFLIGHT = "https://testflight.apple.com/join/47yxmU8U"
# Outside pages the Privacy Policy points to on purpose: Google's rules for its user data, and
# where a Google account's access to Banana is taken away.
OUTSIDE = {"https://developers.google.com/terms/api-services-user-data-policy",
           "https://myaccount.google.com/permissions"}

# Switched off or removed on 8 Oct 2026 (the list StoreListingTests keeps), plus what the
# handoff's "Claims to avoid" and "Open marketing decisions" rule out.
RETIRED = ["guided plan", "strength or stretch", "form guide", "re-plan", "replan", "bedside",
           "standby", "flyover", "workout plan"]
AVOID = ["ai-powered", "ai powered", "automatically organi", "never miss", "battery", "medical-grade",
         "medical grade", "recovery score", "readiness", "personal trainer", "every calendar",
         "syncs instantly", "sync instantly", "fully offline", "private by default", "collect no data",
         "no data collected", "replaces calendar", "replaces your calendar", "skip ads", "ad skip",
         "skips ads", "ad-free", "accurate", "precise", "adherence", "diagnos", "treat"]
PRICE = re.compile(r"[$€£]\s?\d|\bfree\b|\bpricing\b|\bsubscription\b|\bper month\b", re.I)
MUST_SAY = ["does not give medical advice", "Apple Intelligence", "Google account", "approximate"]

# Bytes a first visit downloads for the front page: HTML, CSS, fonts and every image on it.
FRONT_PAGE_BUDGET = 900_000
ABOVE_THE_FOLD_BUDGET = 320_000   # HTML, CSS, fonts and the images that are not lazy
# Messages downloads at most 10 MB of a preview's image, icon and video together (Apple TN3156).
PREVIEW_BUDGET = 10_000_000
SOCIAL_VIDEO = "/assets/video/social.mp4"


class Page(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.refs: list[str] = []
        self.links: list[str] = []
        self.images: list[dict[str, str | None]] = []
        self.ids: set[str] = set()
        self.text: list[str] = []
        self.meta: dict[str, str] = {}
        self._skip = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = dict(attrs)
        if tag in ("script", "style"):
            self._skip += 1
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "img":
            self.images.append(a)
            self.refs.append(a.get("src") or "")
            self.text.append(a.get("alt") or "")
        if tag == "link" and a.get("href"):
            if a.get("rel") == "canonical":
                self.meta["canonical"] = a["href"]
            else:
                self.refs.append(a["href"])
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])
        if tag == "meta":
            key = a.get("name") or a.get("property")
            if key:
                self.meta[key] = a.get("content") or ""
                if key in ("description", "og:title", "og:description"):
                    self.text.append(a.get("content") or "")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style"):
            self._skip -= 1

    def handle_data(self, data: str) -> None:
        if not self._skip:
            self.text.append(data)


def local(ref: str) -> Path | None:
    """The file a root-relative reference names, or None for one that leaves the site."""
    if not ref.startswith("/") or ref.startswith("//"):
        return None
    path = ref.split("#")[0].split("?")[0]
    target = SITE / ("index.html" if path == "/" else path.lstrip("/"))
    return target / "index.html" if target.is_dir() else target


def check() -> list[str]:
    faults: list[str] = []
    css = (SITE / "styles.css").read_text(encoding="utf-8")
    css_files = [SITE / u.lstrip("/") for u in re.findall(r'url\("(/[^"]+)"\)', css)]
    for file in css_files:
        if not file.exists():
            faults.append(f"styles.css points at {file.relative_to(SITE)}, which isn't there")
    # The front page carries its own styles, fonts included.
    home = (SITE / "index.html").read_text(encoding="utf-8")
    home_files = [SITE / u.lstrip("/") for u in re.findall(r'url\("(/[^"]+)"\)', home)]
    for file in home_files:
        if not file.exists():
            faults.append(f"index.html points at {file.relative_to(SITE)}, which isn't there")

    pages = {}
    for file in sorted(SITE.rglob("*.html")):
        name = str(file.relative_to(SITE))
        page = Page()
        page.feed((SITE / name).read_text(encoding="utf-8"))
        pages[name] = page
        for ref in page.refs:
            target = local(ref)
            if target is None:
                faults.append(f"{name} loads {ref!r} from outside the site")   # nothing is, by design
            elif not target.exists():
                faults.append(f"{name} points at {ref}, which isn't there")
        for image in page.images:
            src = image.get("src")
            if "alt" not in image:
                faults.append(f"{name}: {src} has no alt (decoration takes an empty one)")
            if not (image.get("width") and image.get("height")):
                faults.append(f"{name}: {src} has no width and height, so the page jumps as it loads")
            elif Image and local(src or "") and local(src).exists():
                stated = int(image["width"]) / int(image["height"])
                width, height = Image.open(local(src)).size
                if abs(stated - width / height) > 0.01:
                    faults.append(f"{name}: {src} is {width}x{height}, not the shape its width and height say")
        for link in page.links:
            if link.startswith("#"):
                if link[1:] not in page.ids:
                    faults.append(f"{name}: {link} leads nowhere on the page")
            elif link.startswith("/"):
                # Cloudflare serves privacy.html at /privacy, and /#faq is the home page.
                path = link.split("#")[0]
                if not (local(path).exists() or (path != "/" and local(path + ".html").exists())):
                    faults.append(f"{name}: {link} isn't a page of the site")
            elif "testflight.apple.com" in link:
                if link != TESTFLIGHT:
                    faults.append(f"{name}: {link} isn't the public TestFlight link")
            elif "apps.apple.com" in link or "itunes.apple.com" in link:
                faults.append(f"{name}: {link} — there is no App Store page yet")
            elif name.startswith("blog/") and urlsplit(link).scheme == "https" and urlsplit(link).hostname:
                pass  # editorial citations may link to public HTTPS sources
            elif not link.startswith("mailto:") and link not in OUTSIDE:
                faults.append(f"{name}: {link} leaves the site; add it to this check on purpose")

    front = pages["index.html"]
    text = re.sub(r"\s+", " ", " ".join(front.text))
    lowered = text.lower().replace("’", "'")
    for words in RETIRED:
        if words in lowered:
            faults.append(f"the page still says “{words}”, which the app no longer has")
    for words in AVOID:
        if words in lowered:
            faults.append(f"the page says “{words}”, which HANDOFF.md rules out")
    found = PRICE.search(text)
    if found:
        faults.append(f"the page talks about price (“{found.group(0)}”); pricing is undecided")
    for words in MUST_SAY:
        if words.lower() not in lowered:
            faults.append(f"the page no longer says “{words}”")
    if TESTFLIGHT not in front.links:
        faults.append("the page has no link to the TestFlight")
    if front.meta.get("canonical") != "https://bananatheapp.com/":
        faults.append("the canonical address isn't https://bananatheapp.com/")
    if front.meta.get("og:image", "").replace("https://bananatheapp.com", "") != "/assets/img/social.png":
        faults.append("the social preview image isn't the one in assets/img")
    faults += check_preview_video(front.meta)

    # Include the eager scene artwork inserted by the existing JavaScript.
    scene_files = [SITE / f"assets/img/room-{name}.png" for name in ("work", "personal", "studio")]
    for file in scene_files:
        if not file.is_file(): faults.append(f"scene image missing: {file.name}")
    # Weight: what the front page makes a first visitor download.
    eager = [local(i["src"]) for i in front.images if i.get("loading") != "lazy"]
    lazy = [local(i["src"]) for i in front.images if i.get("loading") == "lazy"]
    shell = [SITE / "index.html", *home_files, *scene_files]   # styles.css is for the other pages
    first = sum(f.stat().st_size for f in {*shell, *eager} if f and f.exists())
    whole = first + sum(f.stat().st_size for f in set(lazy) - set(eager) if f and f.exists())
    print(f"first screen {first / 1000:.0f} KB (budget {ABOVE_THE_FOLD_BUDGET // 1000}), "
          f"whole page {whole / 1000:.0f} KB (budget {FRONT_PAGE_BUDGET // 1000})")
    if first > ABOVE_THE_FOLD_BUDGET:
        faults.append(f"the first screen weighs {first / 1000:.0f} KB")
    if whole > FRONT_PAGE_BUDGET:
        faults.append(f"the whole page weighs {whole / 1000:.0f} KB")

    hidden = "noindex" in front.meta.get("robots", "")
    print("search engines: " + ("kept out (noindex)" if hidden else "allowed in"))
    from check_seo import check_seo
    faults += check_seo(SITE)
    return faults


def check_preview_video(meta: dict[str, str]) -> list[str]:
    """Messages plays og:video in the preview only when it is a downloadable MP4; a page or a
    stream would need a tap or show nothing."""
    faults = []
    video = meta.get("og:video", "").replace("https://bananatheapp.com", "")
    if video != SOCIAL_VIDEO:
        return [f"the preview video isn't {SOCIAL_VIDEO}"]
    if meta.get("og:video:secure_url") != meta.get("og:video"):
        faults.append("og:video:secure_url doesn't match og:video")
    if meta.get("og:video:type") != "video/mp4":
        faults.append("og:video:type isn't video/mp4")
    if (meta.get("og:video:width"), meta.get("og:video:height")) != ("1200", "630"):
        faults.append("og:video isn't stated as 1200×630")
    file = local(SOCIAL_VIDEO)
    if not file.exists():
        return faults + [f"{SOCIAL_VIDEO} isn't there (node LandingPage/record_social_video.mjs)"]
    if file.read_bytes()[4:8] != b"ftyp":
        faults.append(f"{SOCIAL_VIDEO} isn't an MP4")
    image = local(meta.get("og:image", "").replace("https://bananatheapp.com", ""))
    preview = file.stat().st_size + (image.stat().st_size if image and image.exists() else 0)
    print(f"link preview {preview / 1000:.0f} KB (Messages' limit {PREVIEW_BUDGET // 1_000_000} MB)")
    if preview > PREVIEW_BUDGET:
        faults.append(f"the preview image and video weigh {preview / 1_000_000:.1f} MB together")
    return faults


if __name__ == "__main__":
    if len(sys.argv) > 1:
        SITE = Path(sys.argv[1]).resolve()
    faults = check()
    for fault in faults:
        print("FAULT  " + fault)
    print("site check: " + (f"{len(faults)} fault(s)" if faults else "passed"))
    sys.exit(1 if faults else 0)
