#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.0.0"]
# ///
"""Build static editorial pages, RSS and sitemap. No runtime or CMS credentials.

    uv run LandingPage/build_content.py

Only explicit draft=false posts dated today or earlier are published. TOML metadata
uses +++ delimiters; HTML is disabled in Markdown. Generated files are tracked.
Rich media goes through fenced blocks: ```video (src, poster, width, height, caption, alt) and
```diagram (src of an SVG under site/assets, caption, alt). Posts may set image/image_alt.
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, time, timezone
from email.utils import format_datetime
from html import escape
import json
from pathlib import Path
import re
from string import Template
import tomllib
import xml.etree.ElementTree as ET

from markdown_it import MarkdownIt

HERE = Path(__file__).resolve().parent
ORIGIN = "https://bananatheapp.com"
PUBLISHER = {"@type": "Organization", "@id": ORIGIN + "/#organization", "name": "Abrega, Inc.", "url": ORIGIN + "/about", "logo": ORIGIN + "/apple-touch-icon.png"}
AUTHOR = {"@type": "Organization", "@id": ORIGIN + "/about#team", "name": "Banana team", "url": ORIGIN + "/about#team", "parentOrganization": {"@id": PUBLISHER["@id"]}}
MD = MarkdownIt("js-default", {"html": False, "typographer": False})
# Tables retain native semantics inside a keyboard-scrollable region on small screens.
MD.renderer.rules["table_open"] = lambda tokens, idx, options, env: '<div class="table-scroll" role="region" aria-label="Data table" tabindex="0"><table>\n'
MD.renderer.rules["table_close"] = lambda tokens, idx, options, env: '</table></div>\n'


def _embed_fields(content: str, kind: str, required: tuple[str, ...], slug: str) -> dict:
    fields = {}
    for line in content.strip().splitlines():
        key, sep, value = line.partition(":")
        if not sep or not key.strip():
            raise ValueError(f"{slug}: {kind} embed lines are `key: value`, got {line!r}")
        fields[key.strip()] = value.strip()
    missing = [k for k in required if not fields.get(k)]
    if missing:
        raise ValueError(f"{slug}: {kind} embed needs {', '.join(missing)}")
    for key in ("src", "poster"):
        if key in fields:
            if not fields[key].startswith("/assets/"):
                raise ValueError(f"{slug}: {kind} {key} must be a site path under /assets/")
            if not (HERE / "site" / fields[key].lstrip("/")).is_file():
                raise ValueError(f"{slug}: {kind} {key} not found in site/: {fields[key]}")
    return fields


def _render_video(fields: dict) -> str:
    alt = escape(fields.get("alt") or fields["caption"])
    return (
        f'<figure class="media-figure media-video"><video data-autoplay loop muted playsinline controls preload="metadata" '
        f'poster="{escape(fields["poster"])}" width="{int(fields["width"])}" height="{int(fields["height"])}" aria-label="{alt}">'
        f'<source src="{escape(fields["src"])}" type="video/mp4"><a href="{escape(fields["src"])}">Watch the video</a></video>'
        f'<figcaption>{escape(fields["caption"])}</figcaption></figure>\n'
    )


def _render_diagram(fields: dict, slug: str) -> str:
    svg = (HERE / "site" / fields["src"].lstrip("/")).read_text()
    svg = re.sub(r"<\?xml[^>]*\?>\s*", "", svg).strip()
    box = re.search(r'viewBox="([\d.\s-]+)"', svg)
    if not svg.startswith("<svg") or not box:
        raise ValueError(f"{slug}: diagram src must be an SVG with a viewBox")
    _, _, width, height = (float(v) for v in box.group(1).split())
    alt = escape(fields.get("alt") or fields["caption"])
    return (
        f'<figure class="media-figure diagram-figure" data-diagram><button type="button" class="diagram-open" aria-label="Enlarge diagram: {alt}">{svg}</button>'
        f'<figcaption>{escape(fields["caption"])} · <a href="{escape(fields["src"])}">Open full size</a></figcaption></figure>'
        f'<dialog class="diagram-dialog" aria-label="{alt}"><div class="diagram-stage" style="--diagram-aspect:{width / height:.4f}"></div>'
        f'<button type="button" class="diagram-close">Close</button></dialog>\n'
    )


_default_fence = MD.renderer.rules["fence"]


def _fence(tokens, idx, options, env):
    token = tokens[idx]
    kind = (token.info or "").strip()
    slug = env.get("slug", "post")
    if kind == "video":
        return _render_video(_embed_fields(token.content, kind, ("src", "poster", "width", "height", "caption"), slug))
    if kind == "diagram":
        return _render_diagram(_embed_fields(token.content, kind, ("src", "caption"), slug), slug)
    return _default_fence(tokens, idx, options, env)


MD.renderer.rules["fence"] = _fence


def read_post(path: Path, today: date, include_unpublished: bool = False) -> dict | None:
    parts = path.read_text().split("+++", 2)
    if len(parts) != 3 or parts[0].strip():
        raise ValueError(f"{path}: expected +++ TOML metadata +++")
    data = tomllib.loads(parts[1])
    for key in ("title", "description", "author", "category"):
        if not isinstance(data.get(key), str) or not data[key].strip():
            raise ValueError(f"{path}: missing {key}")
    if data["author"] != AUTHOR["name"]:
        raise ValueError(f"{path}: add a real author profile before using another byline")
    for key in ("published", "updated"):
        if type(data.get(key)) is not date:
            raise ValueError(f"{path}: {key} must be a TOML date")
    if data["updated"] < data["published"]:
        raise ValueError(f"{path}: updated precedes published")
    if type(data.get("draft")) is not bool:
        raise ValueError(f"{path}: draft must explicitly be true or false")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", path.stem):
        raise ValueError(f"{path}: use a lowercase hyphenated filename")
    if "image" in data:
        if not isinstance(data["image"], str) or not data["image"].startswith("/assets/") or not (HERE / "site" / data["image"].lstrip("/")).is_file():
            raise ValueError(f"{path}: image must be a site path under /assets/ that exists")
        if not isinstance(data.get("image_alt"), str) or not data["image_alt"].strip():
            raise ValueError(f"{path}: image needs image_alt")
    if not include_unpublished and (data["draft"] or data["published"] > today):
        return None
    if not include_unpublished and data["updated"] > today:
        raise ValueError(f"{path}: updated is in the future")
    tokens = MD.parse(parts[2])
    if not any(t.type == "paragraph_open" for t in tokens):
        raise ValueError(f"{path}: empty post")
    if any(t.type == "heading_open" and t.tag == "h1" for t in tokens):
        raise ValueError(f"{path}: title supplies h1; use ## for headings")
    if any(t.type == "inline" and any(c.type == "image" for c in (t.children or [])) for t in tokens):
        raise ValueError(f"{path}: images need sized template support; use text links until added")
    data.update(slug=path.stem, body=MD.render(parts[2], {"slug": path.stem}), url=ORIGIN + f"/blog/{path.stem}/")
    return data


def schema_text(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False).replace("<", "\\u003c")


DEFAULT_IMAGE = ("/assets/img/social.png", "Banana brings work, personal and studio calendars together into one daily plan.")


def render(title: str, description: str, path: str, body: str, schema: dict, *, article: bool = False, extra_head: str = "", image: tuple[str, str] = DEFAULT_IMAGE) -> str:
    return Template((HERE / "templates/editorial.html").read_text()).substitute(
        title=escape(title), description=escape(description), url=ORIGIN + path,
        og_image=ORIGIN + image[0], og_image_alt=escape(image[1]),
        body=body, schema=schema_text(schema), og_type="article" if article else "website",
        blog_current='aria-current="page"' if path == "/blog/" else "",
        about_current='aria-current="page"' if path == "/about" else "", extra_head=extra_head)


def build(out: Path, content: Path, today: date, preview: bool = False) -> None:
    posts = [post for path in sorted(content.glob("*.md")) if (post := read_post(path, today, preview))]
    posts.sort(key=lambda p: (p["published"], p["slug"]), reverse=True)
    blog = out / "blog"
    blog.mkdir(parents=True, exist_ok=True)
    # Remove only outputs owned by this generator, including a formerly published draft.
    manifest = out / ".content-manifest.json"
    if manifest.exists():
        for relative in json.loads(manifest.read_text()):
            candidate = out / relative
            if candidate.is_file() and candidate.resolve().is_relative_to(blog.resolve()):
                candidate.unlink()
    generated = []
    def write(path: str, value: str) -> None:
        target = out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)
        if path.startswith("blog/"):
            generated.append(path)
    rows = []
    for post in posts:
        title, desc = escape(post["title"]), escape(post["description"])
        pub, updated = post["published"].isoformat(), post["updated"].isoformat()
        label = post["published"].strftime("%B %d, %Y").replace(" 0", " ")
        path = f'/blog/{post["slug"]}/'
        rows.append(f'<article class="post-row"><div class="meta"><time datetime="{pub}">{label}</time><br>{escape(post["category"])}</div><div><h2><a href="{path}">{title}</a></h2><p>{desc}</p><a class="read" href="{path}">Read the post <span aria-hidden="true">→</span></a></div></article>')
        body = f'<nav aria-label="Breadcrumb"><ol class="breadcrumb"><li><a href="/">Home</a></li><li aria-hidden="true">/</li><li><a href="/blog/">Blog</a></li></ol></nav><article><header class="article-head"><p class="eyebrow">{escape(post["category"])}</p><h1>{title}</h1><p class="meta">By <a href="/about#team">Banana team</a> · Published <time datetime="{pub}">{label}</time>'
        if updated != pub:
            body += f' · Updated <time datetime="{updated}">{updated}</time>'
        body += f'</p></header><div class="prose">{post["body"]}<div class="article-end"><a href="/blog/">← All posts</a> · <a href="/support">Questions? Contact us</a></div></div></article>'
        graph = {"@context": "https://schema.org", "@graph": [PUBLISHER, AUTHOR, {"@type": "BlogPosting", "@id": post["url"] + "#article", "headline": post["title"], "description": post["description"], "url": post["url"], "mainEntityOfPage": post["url"], "datePublished": pub, "dateModified": updated, "author": {"@id": AUTHOR["@id"]}, "publisher": {"@id": PUBLISHER["@id"]}, "image": ORIGIN + post.get("image", DEFAULT_IMAGE[0]), "inLanguage": "en", "isPartOf": {"@id": ORIGIN + "/blog/#blog"}}, {"@type": "BreadcrumbList", "itemListElement": [{"@type": "ListItem", "position": i, "name": name, "item": ORIGIN + link} for i, (name, link) in enumerate([("Home", "/"), ("Blog", "/blog/"), (post["title"], path)], 1)]}]}
        extra = f'<meta property="article:published_time" content="{pub}">\n<meta property="article:modified_time" content="{updated}">'
        image = (post["image"], post["image_alt"]) if "image" in post else DEFAULT_IMAGE
        write(f'blog/{post["slug"]}/index.html', render(post["title"] + " · Banana", post["description"], path, body, graph, article=True, extra_head=extra, image=image))
    body = '<header class="intro"><p class="eyebrow">The Banana blog</p><h1 class="index-title">Building Banana.</h1><p>Engineering notes on the calendar, the app, and the tests behind them. What we built, what we measured, and what still needs work.</p><a href="/blog/feed.xml">Follow along with RSS →</a></header><section class="posts" aria-label="Latest posts">' + ("".join(rows) or '<p>No posts yet. Check back soon.</p>') + '</section>'
    write("blog/index.html", render("Banana blog · Engineering and product development", "Engineering notes from the Banana team on calendar rendering, performance testing, and building a native daily planning app.", "/blog/", body, {"@context": "https://schema.org", "@type": "Blog", "@id": ORIGIN + "/blog/#blog", "url": ORIGIN + "/blog/", "name": "Banana blog", "publisher": PUBLISHER, "blogPost": [{"@type": "BlogPosting", "url": p["url"], "headline": p["title"]} for p in posts]}))
    about_body = '<header class="intro"><p class="eyebrow">About Banana</p><h1>Many calendars.<br>One you.</h1><p>Banana brings Google calendars, reminders, routines, travel time, and weather into one daily plan on iPhone, iPad, and Apple silicon Mac, with a companion Apple Watch app.</p></header><div class="prose"><h2 id="team">Made by Abrega, Inc.</h2><p>The Banana team publishes engineering notes and product documentation on this site. We explain what the app does, the permissions it needs, and the limits that matter when you use it.</p><p>Banana is currently in public beta through TestFlight. Calendar features require a Google account. Optional modules include food, workouts and sleep, notes, and podcasts. Capabilities and permissions vary by device. Banana is for general wellness and planning and does not give medical advice.</p><h2>Get in touch</h2><p>For product questions, feedback, or corrections to a guide, write to <a href="mailto:support@abrega.com">support@abrega.com</a>.</p><p><a href="/blog/">Read the blog</a> · <a href="/support">Get help</a> · <a href="/privacy">Read the Privacy Policy</a></p></div>'
    write("about.html", render("About Banana · Made by Abrega, Inc.", "Banana is made by Abrega, Inc. Learn about the daily planning app, the Banana team, and how to contact us.", "/about", about_body, {"@context": "https://schema.org", "@graph": [PUBLISHER, AUTHOR, {"@type": "AboutPage", "url": ORIGIN + "/about", "name": "About Banana", "about": {"@id": ORIGIN + "/#application"}}]}))
    ET.register_namespace("atom", "http://www.w3.org/2005/Atom")
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    for tag, value in [("title", "Banana blog"), ("link", ORIGIN + "/blog/"), ("description", "Engineering and product development notes from the Banana team."), ("language", "en")]:
        ET.SubElement(channel, tag).text = value
    ET.SubElement(channel, "{http://www.w3.org/2005/Atom}link", href=ORIGIN + "/blog/feed.xml", rel="self", type="application/rss+xml")
    for post in posts:
        item = ET.SubElement(channel, "item")
        for tag, value in [("title", post["title"]), ("link", post["url"]), ("description", post["description"]), ("pubDate", format_datetime(datetime.combine(post["published"], time(), timezone.utc))), ("category", post["category"])]:
            ET.SubElement(item, tag).text = value
        ET.SubElement(item, "guid", isPermaLink="true").text = post["url"]
    write("blog/feed.xml", '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(rss, encoding="unicode") + "\n")
    ns = "http://www.sitemaps.org/schemas/sitemap/0.9"
    ET.register_namespace("", ns)
    sitemap = ET.Element(f"{{{ns}}}urlset")
    for path in ["/", "/about", "/support", "/privacy", "/terms", "/blog/", *[f'/blog/{p["slug"]}/' for p in posts]]:
        item = ET.SubElement(sitemap, f"{{{ns}}}url")
        ET.SubElement(item, f"{{{ns}}}loc").text = ORIGIN + path
        matching = next((p for p in posts if path == f'/blog/{p["slug"]}/'), None)
        if matching:
            ET.SubElement(item, f"{{{ns}}}lastmod").text = matching["updated"].isoformat()
    write("sitemap.xml", '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(sitemap, encoding="unicode") + "\n")
    manifest.write_text(json.dumps(sorted(generated), indent=2) + "\n")
    if preview:
        for file in out.rglob("*.html"):
            html = file.read_text().replace("</head>", '<meta name="robots" content="noindex,nofollow"></head>')
            html = html.replace('<main id="main"', '<p role="status" class="shell">Local preview — includes unpublished content.</p><main id="main"')
            file.write_text(html)
    print(f"{'Previewed' if preview else 'Published'} {len(posts)} post(s); blog, about, RSS and sitemap generated.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=HERE / "site")
    parser.add_argument("--preview", action="store_true", help="Include drafts in a separate local-only output folder")
    args = parser.parse_args()
    if args.preview:
        if args.out.resolve() == (HERE / "site").resolve() or args.out.resolve().is_relative_to((HERE / "site").resolve()):
            parser.error("Preview output must be outside the public site directory")
        import shutil
        shutil.copytree(HERE / "site", args.out, dirs_exist_ok=True)
    build(args.out, HERE / "content/posts", date.today(), args.preview)
