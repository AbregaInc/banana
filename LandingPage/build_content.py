#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.0.0", "markdownify==1.2.0"]
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
import hashlib
import json
from pathlib import Path
import re
from string import Template
import tomllib
import xml.etree.ElementTree as ET

from markdown_it import MarkdownIt

import store_links
from reader_exports import export_readers

HERE = Path(__file__).resolve().parent
ORIGIN = "https://bananatheapp.com"
PUBLISHER = {"@type": "Organization", "@id": ORIGIN + "/#organization", "name": "Abrega, Inc.", "url": ORIGIN + "/about", "logo": ORIGIN + "/apple-touch-icon.png"}
AUTHOR = {"@type": "Organization", "@id": ORIGIN + "/about#team", "name": "Banana team", "url": ORIGIN + "/about#team", "parentOrganization": {"@id": PUBLISHER["@id"]}}
MD = MarkdownIt("js-default", {"html": False, "typographer": False})
# A table that cannot fit a phone without breaking words is drawn as one card per row there, each
# value labelled with its column (editorial.css, .table-stack). Phone = 375 px less the page gutters;
# IBM Plex Mono at the phone table size is 8.4 px a character, plus 16 px of padding per cell.
PHONE_TABLE_WIDTH, CHAR_WIDTH, CELL_PADDING = 335, 8.4, 16
MEASURE = re.compile(r"\d")


def _text(inline) -> str:
    return "".join(child.content for child in inline.children or [] if child.type in ("text", "code_inline"))


def _narrowest(cell: str) -> int:
    # A short measurement ("14.9 · 15.1 ms") never wraps; anything else may wrap between words.
    if MEASURE.search(cell) and len(cell) <= 16:
        return len(cell)
    return max((len(word) for word in cell.split()), default=0)


def _table_cards(state) -> None:
    tokens = state.tokens
    for start, token in enumerate(tokens):
        if token.type != "table_open":
            continue
        end = next(i for i in range(start, len(tokens)) if tokens[i].type == "table_close")
        rows, headers, row = [], [], None
        for i in range(start, end):
            kind = tokens[i].type
            if kind == "tr_open":
                row = []
                rows.append(row)
            elif kind in ("th_open", "td_open"):
                row.append((tokens[i], _text(tokens[i + 1])))
            if kind == "th_open":
                headers.append(_text(tokens[i + 1]))
        widths = [max(_narrowest(text) for text in column) for column in zip(*[[text for _, text in r] for r in rows])]
        stack = token.meta["stack"] = state.env.get("comparison", False) or sum(w * CHAR_WIDTH + CELL_PADDING for w in widths) > PHONE_TABLE_WIDTH
        for r in rows[1:]:
            for (cell, text), header in zip(r, headers):
                if MEASURE.search(text) and len(text) <= 16:
                    cell.attrJoin("class", "measure")
                if stack and header:
                    cell.attrSet("data-label", header)
        if stack:
            # Explicit roles keep the table's semantics when the cards change its display.
            roles = {"thead_open": "rowgroup", "tbody_open": "rowgroup", "tr_open": "row", "th_open": "columnheader", "td_open": "cell"}
            for t in tokens[start:end]:
                if t.type in roles:
                    t.attrSet("role", roles[t.type])


MD.core.ruler.push("table_cards", _table_cards)
MD.renderer.rules["table_open"] = lambda tokens, idx, options, env: (
    '<div class="table-scroll table-stack" role="region" aria-label="Data table" tabindex="0"><table role="table">\n'
    if tokens[idx].meta.get("stack") else
    '<div class="table-scroll" role="region" aria-label="Data table" tabindex="0"><table>\n')
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
        f'<figcaption>{escape(fields["caption"])} · <a class="diagram-full" href="{escape(fields["src"])}">Open full size</a></figcaption></figure>'
        f'<dialog class="diagram-dialog" aria-label="{alt}"><div class="diagram-stage" style="--diagram-aspect:{width / height:.4f}"></div>'
        f'<button type="button" class="diagram-close">Close</button></dialog>\n'
    )


_default_fence = MD.renderer.rules["fence"]


def _fence(tokens, idx, options, env):
    token = tokens[idx]
    kind = (token.info or "").strip()
    slug = env.get("slug", "post")
    if kind == "screenshot":
        fields = _embed_fields(token.content, kind, ("src", "width", "height", "alt", "caption"), slug)
        src = escape(fields["src"])
        return (f'<figure class="media-figure guide-shot"><a href="{src}">'
                f'<img src="{src}" width="{int(fields["width"])}" height="{int(fields["height"])}" '
                f'loading="lazy" alt="{escape(fields["alt"])}"></a>'
                f'<figcaption>{escape(fields["caption"])}</figcaption></figure>')
    if kind == "video":
        return _render_video(_embed_fields(token.content, kind, ("src", "poster", "width", "height", "caption"), slug))
    if kind == "diagram":
        return _render_diagram(_embed_fields(token.content, kind, ("src", "caption"), slug), slug)
    return _default_fence(tokens, idx, options, env)


MD.renderer.rules["fence"] = _fence


def read_post(path: Path, today: date, include_unpublished: bool = False, section: str = "blog") -> dict | None:
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
    data.update(slug=path.stem, body=MD.render(parts[2], {"slug": path.stem, "comparison": data["category"] == "Calendar comparison"}), url=ORIGIN + f"/{section}/{path.stem}/")
    return data


def schema_text(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False).replace("<", "\\u003c")


DEFAULT_IMAGE = ("/assets/img/social.png", "Banana brings work, personal and studio calendars together into one daily plan.")


def render(title: str, description: str, path: str, body: str, schema: dict, *, article: bool = False, extra_head: str = "", image: tuple[str, str] = DEFAULT_IMAGE) -> str:
    return Template((HERE / "templates/editorial.html").read_text()).substitute(
        style_version=hashlib.sha256((HERE / "site/editorial.css").read_bytes()).hexdigest()[:12],
        title=escape(title), description=escape(description), url=ORIGIN + path,
        og_image=ORIGIN + image[0], og_image_alt=escape(image[1]),
        body=body, schema=schema_text(schema), og_type="article" if article else "website",
        header_action=('<a class="button" href="https://app.bananatheapp.com/">Open web app</a>' if path.startswith("/compare/") else '<a class="button" href="/download/mac">Download for Mac</a>'),
        blog_current='aria-current="page"' if path == "/blog/" else "",
        about_current='aria-current="page"' if path == "/about" else "", extra_head=extra_head)


def build(out: Path, content: Path, today: date, preview: bool = False, store: str | None = None) -> None:
    store_links.apply(out, store)
    posts = [post for path in sorted(content.glob("*.md")) if (post := read_post(path, today, preview))]
    posts.sort(key=lambda p: (p["published"], p["slug"]), reverse=True)
    guides = [guide for path in sorted((content.parent / "guides").glob("*.md"))
              if (guide := read_post(path, today, preview, section="guides"))]
    comparisons = [item for path in sorted((content.parent / "compare").glob("*.md"))
                   if (item := read_post(path, today, preview, section="compare"))]
    articles = posts + guides + comparisons
    blog = out / "blog"
    blog.mkdir(parents=True, exist_ok=True)
    # Remove only outputs owned by this generator, including a formerly published draft.
    manifest = out / ".content-manifest.json"
    if manifest.exists():
        for relative in json.loads(manifest.read_text()):
            candidate = out / relative
            if candidate.is_file() and any(candidate.resolve().is_relative_to((out / section).resolve()) for section in ("blog", "guides", "compare")):
                candidate.unlink()
    generated = []
    def write(path: str, value: str) -> None:
        target = out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)
        if path.startswith(("blog/", "guides/", "compare/")):
            generated.append(path)
    rows = []
    guide_rows = []
    comparison_rows = []
    for post in articles:
        is_guide = post in guides
        section, section_label = ("guides", "Guides") if is_guide else ("blog", "Blog")
        if post in comparisons:
            section, section_label = "compare", "Comparisons"
        title, desc = escape(post["title"]), escape(post["description"])
        pub, updated = post["published"].isoformat(), post["updated"].isoformat()
        label = post["published"].strftime("%B %d, %Y").replace(" 0", " ")
        path = f'/{section}/{post["slug"]}/'
        if section == "compare":
            comparison_rows.append(f'<li><a href="{path}">{title}</a><p>{escape(post["question"])}</p></li>')
        else:
            (guide_rows if is_guide else rows).append(f'<article class="post-row"><div class="meta"><time datetime="{pub}">{label}</time><br>{escape(post["category"])}</div><div><h2><a href="{path}">{title}</a></h2><p>{desc}</p><a class="read" href="{path}">Read the {"guide" if is_guide else "post"} <span aria-hidden="true">→</span></a></div></article>')
        body = f'<nav aria-label="Breadcrumb"><ol class="breadcrumb"><li><a href="/">Home</a></li><li aria-hidden="true">/</li><li><a href="/{section}/">{section_label}</a></li></ol></nav><article><header class="article-head"><p class="eyebrow">{escape(post["category"])}</p><h1>{title}</h1><p class="meta">By <a href="/about#team">Banana team</a> · Published <time datetime="{pub}">{label}</time>'
        if updated != pub:
            body += f' · Updated <time datetime="{updated}">{updated}</time>'
        body += f'</p></header><div class="prose">{post["body"]}<div class="article-end"><a href="/{section}/">← {section_label}</a> · <a href="/support">Questions? Contact us</a></div></div></article>'
        if is_guide:
            lead, _, rest = post["body"].partition("</p>")
            lead += "</p>"
            visual = ""
            rest = rest.lstrip()
            if rest.startswith("<figure"):
                figure, _, rest = rest.partition("</figure>")
                visual = figure.replace('loading="lazy"', 'loading="eager"') + "</figure>"
            date_line = f'<time datetime="{updated}">{escape(label) if updated == pub else updated}</time>'
            body = (f'<article class="reader {"field-guide" if post["category"] == "Calendar guide" else ""}"><nav class="reader-trail" aria-label="Breadcrumb">'
                    f'<a href="/">Home</a> / <a href="/guides/">Guides</a></nav>'
                    f'<header class="reader-head"><div><h1>{title}</h1>'
                    f'<p class="meta">{escape(post["category"])} · {date_line}</p></div>'
                    f'<div class="reader-lead">{lead}</div>{visual}</header>'
                    f'<div class="prose reader-body">{rest}</div></article>')
        if section == "compare":
            template = Template((HERE / "templates/comparison.html").read_text())
            body = template.substitute(get_url=escape(store or "/calendar/"), summary=escape(post["summary"]), competitor=escape(post["competitor"]),
                                       question=escape(post["question"]), banana_fit=escape(post["banana_fit"]),
                                       competitor_fit=escape(post["competitor_fit"]), details=post["body"])
        graph = {"@context": "https://schema.org", "@graph": [PUBLISHER, AUTHOR, {"@type": "BlogPosting" if section == "blog" else "Article", "@id": post["url"] + "#article", "headline": post["title"], "description": post["description"], "url": post["url"], "mainEntityOfPage": post["url"], "datePublished": pub, "dateModified": updated, "author": {"@id": AUTHOR["@id"]}, "publisher": {"@id": PUBLISHER["@id"]}, "image": ORIGIN + post.get("image", DEFAULT_IMAGE[0]), "inLanguage": "en", "isPartOf": {"@id": ORIGIN + f"/{section}/#{section}"}}, {"@type": "BreadcrumbList", "itemListElement": [{"@type": "ListItem", "position": i, "name": name, "item": ORIGIN + link} for i, (name, link) in enumerate([("Home", "/"), (section_label, f"/{section}/"), (post["title"], path)], 1)]}]}
        extra = f'<meta property="article:published_time" content="{pub}">\n<meta property="article:modified_time" content="{updated}">'
        image = (post["image"], post["image_alt"]) if "image" in post else DEFAULT_IMAGE
        write(f'{section}/{post["slug"]}/index.html', render(post["title"] + " · Banana", post["description"], path, body, graph, article=True, extra_head=extra, image=image))
    body = '<header class="intro"><p class="eyebrow">The Banana blog</p><h1 class="index-title">Building Banana.</h1><p>Engineering notes on the calendar, the app, and the tests behind them. What we built, what we measured, and what still needs work.</p><a href="/blog/feed.xml">Follow along with RSS →</a></header><section class="posts" aria-label="Latest posts">' + ("".join(rows) or '<p>No posts yet. Check back soon.</p>') + '</section>'
    write("blog/index.html", render("Banana blog · Engineering and product development", "Engineering notes from the Banana team on calendar rendering, performance testing, and building a native daily planning app.", "/blog/", body, {"@context": "https://schema.org", "@type": "Blog", "@id": ORIGIN + "/blog/#blog", "url": ORIGIN + "/blog/", "name": "Banana blog", "publisher": PUBLISHER, "blogPost": [{"@type": "BlogPosting", "url": p["url"], "headline": p["title"]} for p in posts]}))
    guide_index = '<header class="intro"><h1>Calendar guides</h1></header>' + "".join(guide_rows)
    write("guides/index.html", render("Calendar guides · Banana", "Step-by-step guides to planning across Google calendars with Banana.", "/guides/", guide_index, {"@context": "https://schema.org", "@type": "CollectionPage", "@id": ORIGIN + "/guides/#guides", "url": ORIGIN + "/guides/"}))
    compare_index = '<section class="compare-page"><h1>Calendar comparisons</h1><ul class="compare-list">' + "".join(comparison_rows) + '</ul></section>'
    write("compare/index.html", render("Compare calendar apps · Banana", "Compare calendar providers, sharing controls and prices with Banana Calendar.", "/compare/", compare_index, {"@context": "https://schema.org", "@type": "CollectionPage", "@id": ORIGIN + "/compare/#compare", "url": ORIGIN + "/compare/"}))
    calendar = (HERE / "templates/calendar.html").read_text()
    calendar = calendar.replace("$download", store_links.regions(store)["hero"])
    write("calendar/index.html", render("Google Calendar planner for multiple accounts · Banana", "Plan across Google accounts with Apple Reminders, travel time and private Busy blocks on iPhone, iPad and Mac.", "/calendar/", calendar, {"@context": "https://schema.org", "@type": "WebPage", "url": ORIGIN + "/calendar/", "name": "Banana Calendar", "about": {"@id": ORIGIN + "/#application"}}))
    about_body = '<header class="intro"><p class="eyebrow">About Banana</p><h1>Many calendars.<br>One you.</h1><p>Banana brings Google calendars, reminders, routines, travel time, and weather into one daily plan on iPhone, iPad, and Apple silicon Mac.</p></header><div class="prose"><h2 id="team">Made by Abrega, Inc.</h2><p>The Banana team publishes engineering notes and product documentation on this site. We explain what the app does, the permissions it needs, and the limits that matter when you use it.</p>' + store_links.about(store) + '<h2>Get in touch</h2><p>For product questions, feedback, or corrections to a guide, write to <a href="mailto:support@abrega.com">support@abrega.com</a>.</p><p><a href="/blog/">Read the blog</a> · <a href="/support">Get help</a> · <a href="/privacy">Read the Privacy Policy</a></p></div>'
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
    for path in ["/", "/about", "/support", "/privacy", "/terms", "/blog/", "/calendar/", "/guides/", "/compare/", *[p["url"].removeprefix(ORIGIN) for p in articles]]:
        item = ET.SubElement(sitemap, f"{{{ns}}}url")
        ET.SubElement(item, f"{{{ns}}}loc").text = ORIGIN + path
        matching = next((p for p in articles if ORIGIN + path == p["url"]), None)
        if matching:
            ET.SubElement(item, f"{{{ns}}}lastmod").text = matching["updated"].isoformat()
    write("sitemap.xml", '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(sitemap, encoding="unicode") + "\n")
    export_readers(out, ORIGIN)
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
    build(args.out, HERE / "content/posts", date.today(), args.preview, store_links.app_store_url())
