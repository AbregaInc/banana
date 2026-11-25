"""Build linked Markdown representations from the same HTML that readers see."""
from pathlib import Path
import re
from html import escape
from urllib.parse import urljoin, urlsplit
import xml.etree.ElementTree as ET

from bs4 import BeautifulSoup
from markdownify import markdownify


def export_readers(out: Path, origin: str) -> None:
    pages = {}
    for loc in ET.parse(out / "sitemap.xml").findall(".//{*}loc"):
        path = urlsplit(loc.text).path
        filename = path + ("index.html" if path.endswith("/") else ".html")
        file = out / filename.lstrip("/")
        if file.exists():
            pages[path] = (file, filename.removesuffix(".html") + ".md")
    index = ["# Banana", "> Banana is a daily planner for Google calendars on iPhone, iPad and Mac."]
    entries = {}
    for path, (file, md_path) in pages.items():
        html = file.read_text()
        soup = BeautifulSoup(html, "html.parser")
        main = soup.main
        for node in main.select("nav, script, style, svg, dialog, [aria-hidden=true]"):
            node.decompose()
        for node in main.select("summary"):
            node.name = "h3"
        for node in main.select("img"):
            if not node.get("alt"):
                node.decompose()
        for tag in main.select("[href], [src], [poster]"):
            for attr in ("href", "src", "poster"):
                if attr in tag.attrs:
                    url = urljoin(origin + path, tag[attr])
                    parts = urlsplit(url)
                    if attr == "href" and parts.netloc == urlsplit(origin).netloc and parts.path in pages and not parts.fragment:
                        url = origin + pages[parts.path][1]
                    tag[attr] = url
        content = markdownify(str(main), heading_style="ATX", newline_style="BACKSLASH", bullets="-", strip=["button"]).strip()
        output = out / md_path.lstrip("/")
        output.write_text(content + f"\n\n[Canonical HTML page]({origin}{path})\n")
        title = soup.title.get_text(strip=True).split(" · ")[0]
        desc = soup.find("meta", attrs={"name": "description"})["content"]
        group = next((label for prefix, label in [("/compare/", "Comparisons"), ("/guides/", "Guides"), ("/blog/", "Engineering")] if path.startswith(prefix)), "Product" if path in ("/", "/calendar/") else "Company and support")
        entries.setdefault(group, []).append(f"- [{title}]({origin}{md_path}): {desc}")
        directory = footer(pages)
        html = re.sub(r"<!--directory-->.*?<!--/directory-->", lambda _: "<!--directory-->" + directory + "<!--/directory-->", html, flags=re.S)
        head = (f'<link rel="alternate" type="text/markdown" href="{md_path}">\n'
                '<link rel="describedby" href="/llms.txt">\n<link rel="stylesheet" href="/directory.css">')
        html = re.sub(r"<!--reader-links-->.*?<!--/reader-links-->\n?", "", html, flags=re.S)
        file.write_text(html.replace("</head>", "<!--reader-links-->" + head + "<!--/reader-links-->\n</head>"))
    for group in ("Product", "Guides", "Comparisons", "Engineering", "Company and support"):
        if group in entries:
            index.extend(["## " + group, "\n".join(entries[group])])
    (out / "llms.txt").write_text("\n\n".join(index) + "\n")
    manifest = out / ".markdown-outputs"
    files = {md for _, md in pages.values()}
    if manifest.exists():
        for old in set(manifest.read_text().splitlines()) - files:
            candidate = out / old.lstrip("/")
            if candidate.suffix == ".md" and candidate.resolve().is_relative_to(out.resolve()):
                candidate.unlink(missing_ok=True)
    manifest.write_text("\n".join(sorted(files)) + "\n")
    headers = out / "_headers"
    if headers.exists():
        base = headers.read_text().partition("# Generated Markdown routes")[0].rstrip()
        rules = [f'{md}\n  Content-Type: text/markdown; charset=utf-8\n  Link: <{origin}{path}>; rel="canonical"' for path, (_, md) in pages.items()]
        headers.write_text(base + "\n\n# Generated Markdown routes\n" + "\n".join(rules) + "\n")


def footer(pages: dict) -> str:
    groups = {
        "Calendar": [("Calendar overview", "/calendar/"), ("Calendar guides", "/guides/"), ("Compare apps", "/compare/")],
        "Banana": [("About", "/about"), ("Engineering blog", "/blog/"), ("Support", "/support"), ("FAQ", "/#faq"), ("TestFlight", "https://testflight.apple.com/join/47yxmU8U")],
        "Resources": [("RSS", "/blog/feed.xml"), ("Privacy", "/privacy"), ("Terms", "/terms")],
    }
    for path, (file, _) in pages.items():
        if path.startswith("/compare/") and path != "/compare/":
            title = BeautifulSoup(file.read_text(), "html.parser").title.get_text(strip=True).split(" · ")[0]
            groups.setdefault("Comparisons", []).append((title, path))
    sections = []
    for label, links in groups.items():
        items = "".join(f'<li><a href="{escape(url)}">{name}</a></li>' for name, url in links)
        sections.append(f'<div><strong>{label}</strong><ul>{items}</ul></div>')
    return '<nav class="site-directory" aria-label="Footer">' + "".join(sections) + "</nav>"
