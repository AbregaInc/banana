"""Where the site sends people to get Banana: one switch, `store.json`'s `appStoreUrl`.

Empty, the pages offer the direct Mac download and the iPhone and iPad TestFlight beta. Set to
the App Store page Apple gives the app, the App Store leads and the beta stays in the fine print.
`build_content.py` writes the marked regions (`<!--store:name-->…<!--/store-->`) of the home and
support pages and the About page from here; `check_site.py` fails when a page is out of step.
Never set an App Store address before Apple has published the app.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG = HERE / "store.json"
TESTFLIGHT = "https://testflight.apple.com/join/47yxmU8U"
MAC = "/download/mac"
APP_STORE = re.compile(r"https://apps\.apple\.com/(?:[a-z]{2}/)?app/(?:[a-z0-9-]+/)?id\d{6,}")
PAGES = ("index.html", "support.html")
REGION = re.compile(r"(<!--store:(\w+)-->)(.*?)(<!--/store-->)", re.S)


def app_store_url(config: Path = CONFIG) -> str | None:
    """The App Store address, or None while the app isn't there yet."""
    url = (json.loads(config.read_text()).get("appStoreUrl") or "").strip()
    if url and not APP_STORE.fullmatch(url):
        raise ValueError(f"{config.name}: {url!r} isn't an App Store app address")
    return url or None


def _schema(url: str | None) -> str:
    download = [url, "https://bananatheapp.com" + MAC] if url else "https://bananatheapp.com" + MAC
    graph = [
        {"@type": "Organization", "@id": "https://bananatheapp.com/#organization", "name": "Abrega, Inc.",
         "url": "https://bananatheapp.com/about", "logo": "https://bananatheapp.com/apple-touch-icon.png"},
        {"@type": "WebSite", "@id": "https://bananatheapp.com/#website", "url": "https://bananatheapp.com/",
         "name": "Banana", "publisher": {"@id": "https://bananatheapp.com/#organization"}, "inLanguage": "en"},
        {"@type": "SoftwareApplication", "@id": "https://bananatheapp.com/#application", "name": "Banana",
         "url": "https://bananatheapp.com/", "applicationCategory": "ProductivityApplication",
         "operatingSystem": "iOS 26.1+, iPadOS 26.1+, macOS 26+ (Apple silicon)",
         "description": "A daily planner for Google calendars, reminders, routines, weather and travel time.",
         "publisher": {"@id": "https://bananatheapp.com/#organization"}, "downloadUrl": download},
    ]
    return '<script type="application/ld+json">' + json.dumps({"@context": "https://schema.org", "@graph": graph}) + "</script>"


def regions(url: str | None) -> dict[str, str]:
    """Each marked region's HTML for the current state."""
    mac = f'<a class="btn" href="{MAC}">Download for Mac</a>'
    if url is None:
        buttons = f'<div class="download-actions">{mac}<a class="btn secondary" href="{TESTFLIGHT}">iPhone &amp; iPad beta</a></div>'
        return {
            "schema": _schema(None),
            "header": f'<a class="btn small" href="{MAC}">Download for Mac</a>',
            "hero": buttons + '\n    <p class="compatibility">Apple silicon · macOS 26+</p>',
            "end": buttons + '\n    <p class="fine">Mac: Apple silicon, macOS 26+. iPhone and iPad: iOS 26.1+ through TestFlight. Calendar features need a Google account.</p>',
            "get": f'<h2>The beta</h2>\n    <p>Download <a href="{MAC}">Banana for Mac</a>, or join the <a href="{TESTFLIGHT}">iPhone and iPad TestFlight beta</a>. On Mac, update controls are in Settings → About → Updates. For feedback, write to us; TestFlight users can also send a screenshot through TestFlight.</p>',
        }
    buttons = f'<div class="download-actions"><a class="btn" href="{url}">App Store</a>{mac.replace("btn", "btn secondary")}</div>'
    return {
        "schema": _schema(url),
        "header": f'<a class="btn small" href="{url}">App Store</a>',
        "hero": buttons + '\n    <p class="compatibility">iPhone · iPad · Mac</p>',
        "end": buttons + f'\n    <p class="fine">iPhone and iPad: iOS 26.1+. Mac: Apple silicon, macOS 26+. Beta: <a href="{TESTFLIGHT}">TestFlight</a>. Calendar features need a Google account.</p>',
        "get": f'<h2>Getting Banana</h2>\n    <p>Get Banana on the <a href="{url}">App Store</a> for iPhone, iPad and Mac. The <a href="{MAC}">Mac download</a> and the <a href="{TESTFLIGHT}">iPhone and iPad TestFlight beta</a> also have the modules still to come. In the Mac download, update controls are in Settings → About → Updates. For feedback, write to us; TestFlight users can also send a screenshot through TestFlight.</p>',
    }


def about(url: str | None) -> str:
    """The About page's paragraph on getting Banana."""
    if url is None:
        get = "Banana for Mac is available as a direct download. iPhone and iPad use the public TestFlight beta."
        early = "the Mac download and the beta have them now"
    else:
        get = f'Banana is on the <a href="{url}">App Store</a> for iPhone, iPad and Mac.'
        early = "the Mac download and the TestFlight beta have them now"
    return (f"<p>{get} Calendar features require a Google account. Workouts and sleep, food, notes and "
            f"podcasts are coming later as modules; {early}. Banana does not give medical advice.</p>")


def render(html: str, url: str | None) -> str:
    """The page with its marked regions written for `url`; unknown region names fail."""
    wanted = regions(url)

    def swap(match: re.Match) -> str:
        if match.group(2) not in wanted:
            raise KeyError(f"unknown store region {match.group(2)!r}")
        return match.group(1) + wanted[match.group(2)] + match.group(4)

    return REGION.sub(swap, html)


def apply(site: Path, url: str | None) -> None:
    for name in PAGES:
        page = site / name
        if page.exists():
            page.write_text(render(page.read_text(encoding="utf-8"), url), encoding="utf-8")
