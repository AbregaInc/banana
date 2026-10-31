#!/usr/bin/env python3
"""Search and publishing invariants, run by check_site.py before every deploy."""
from html.parser import HTMLParser
import json
from pathlib import Path
from urllib.parse import urlsplit, unquote
import xml.etree.ElementTree as ET

ORIGIN = "https://bananatheapp.com"

class Document(HTMLParser):
    def __init__(self):
        super().__init__()
        self.title = ""
        self.h1s = 0
        self.meta = {}
        self.links = []
        self.ids = set()
        self.lang = None
        self.canonical = None
        self.schemas = []
        self._schema = None
        self._title = False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html": self.lang = a.get("lang")
        if tag == "h1": self.h1s += 1
        if tag == "title": self._title = True
        if tag == "meta": self.meta[a.get("name", a.get("property"))] = a.get("content", "")
        if tag == "link" and a.get("rel") == "canonical": self.canonical = a.get("href")
        if tag == "a" and a.get("href"): self.links.append(a["href"])
        if a.get("id"): self.ids.add(a["id"])
        if tag == "script" and a.get("type") == "application/ld+json": self._schema = ""
    def handle_data(self, data):
        if self._title: self.title += data
        if self._schema is not None: self._schema += data
    def handle_endtag(self, tag):
        if tag == "title": self._title = False
        if tag == "script" and self._schema is not None:
            self.schemas.append(json.loads(self._schema)); self._schema = None


def url_for(relative):
    if relative == "index.html": return ORIGIN + "/"
    if relative.endswith("/index.html"): return ORIGIN + "/" + relative[:-10]
    return ORIGIN + "/" + relative.removesuffix(".html")


def check_seo(site: Path) -> list[str]:
    errors, documents = [], {}
    titles, descriptions = set(), set()
    for file in sorted(site.rglob("*.html")):
        name = str(file.relative_to(site))
        doc = Document()
        try: doc.feed(file.read_text())
        except (ValueError, TypeError) as e:
            errors.append(f"{name}: invalid JSON-LD: {e}"); continue
        documents[url_for(name)] = doc
        if name == "404.html":
            if "noindex" not in doc.meta.get("robots", ""): errors.append("404 must stay noindex")
            continue
        if doc.canonical != url_for(name): errors.append(f"{name}: canonical must match its public URL")
        if doc.h1s != 1: errors.append(f"{name}: expected exactly one h1")
        if doc.lang != "en": errors.append(f"{name}: missing language")
        if not doc.title or doc.title in titles: errors.append(f"{name}: missing/duplicate title")
        desc = doc.meta.get("description")
        if not desc or desc in descriptions: errors.append(f"{name}: missing/duplicate description")
        titles.add(doc.title); descriptions.add(desc)
        if doc.meta.get("og:url") != doc.canonical: errors.append(f"{name}: social URL and canonical differ")
        for key in ("og:title", "og:description", "og:image", "twitter:card"):
            if not doc.meta.get(key): errors.append(f"{name}: missing {key}")
        if "noindex" in doc.meta.get("robots", ""): errors.append(f"{name}: published page is noindex")
        if name.startswith("blog/") and not doc.schemas: errors.append(f"{name}: missing structured data")
        if name.startswith("blog/") and name != "blog/index.html":
            nodes = [node for schema in doc.schemas for node in schema.get("@graph", [schema])]
            articles = [node for node in nodes if node.get("@type") == "BlogPosting"]
            if len(articles) != 1:
                errors.append(f"{name}: expected exactly one BlogPosting")
            else:
                article = articles[0]
                for key in ("headline", "description", "author", "publisher", "datePublished", "dateModified", "image"):
                    if not article.get(key): errors.append(f"{name}: article missing {key}")
                if article.get("url") != doc.canonical or article.get("mainEntityOfPage") != doc.canonical:
                    errors.append(f"{name}: article URL must match canonical")
                if article.get("datePublished") != doc.meta.get("article:published_time") or article.get("dateModified") != doc.meta.get("article:modified_time"):
                    errors.append(f"{name}: article and social dates differ")
    for url, doc in documents.items():
        for link in doc.links:
            parts = urlsplit(link)
            if parts.scheme or parts.netloc or not parts.path.startswith("/"): continue
            target = documents.get(ORIGIN + parts.path)
            if parts.fragment and target and unquote(parts.fragment) not in target.ids:
                errors.append(f"{url}: broken anchor {link}")
    try:
        sitemap = ET.parse(site / "sitemap.xml")
        urls = [x.text for x in sitemap.findall(".//{*}loc")]
        expected = {u for u in documents if not u.endswith("/404")}
        if set(urls) != expected or len(urls) != len(set(urls)):
            errors.append("sitemap must contain every indexable page exactly once")
        feed = ET.parse(site / "blog/feed.xml")
        items = feed.findall("./channel/item")
        posts = {u for u in documents if u.startswith(ORIGIN + "/blog/") and u != ORIGIN + "/blog/"}
        if {item.findtext("link") for item in items} != posts: errors.append("RSS and published posts differ")
    except (OSError, ET.ParseError) as e:
        errors.append(f"sitemap/feed invalid: {e}")
    if f"Sitemap: {ORIGIN}/sitemap.xml" not in (site / "robots.txt").read_text():
        errors.append("robots.txt must advertise the sitemap")
    for css in site.glob("*.css"):
        import re
        for ref in re.findall(r'url\("(/[^"]+)"\)', css.read_text()):
            if not (site / ref.lstrip("/")).is_file(): errors.append(f"{css.name}: missing {ref}")
    print(f"search checks: {len(documents)-1} indexable pages, sitemap, RSS, metadata and internal anchors")
    return errors
