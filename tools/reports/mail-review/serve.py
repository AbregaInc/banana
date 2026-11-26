#!/usr/bin/env python3
"""Serve the Mail comparison and save review feedback on this Mac."""
import argparse
import hashlib
import json
import os
import re
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CASES = {
    "linked-image-card": "Linked image card",
    "multi-panel-digest": "Multi-panel digest",
}
REVIEW_VARIANT = "grouped"
WIDTHS = (320, 393, 480)
PREVIEW_CSP = (
    "default-src 'none'; style-src 'unsafe-inline'; img-src data:; "
    "form-action 'none'; base-uri 'none'; frame-ancestors 'self'"
)
UI_CSP = (
    "default-src 'none'; script-src 'self'; style-src 'self'; "
    "connect-src 'self'; frame-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
)
STATIC = {
    "/": ("index.html", "text/html"),
    "/review.css": ("review.css", "text/css"),
    "/review.js": ("review.js", "text/javascript"),
    "/preview.js": ("preview.js", "text/javascript"),
}


def prepare_cases(directory, titles):
    cases = []
    previews = {}
    rules = (HERE / "preview.js").read_bytes()
    for key, title in titles.items():
        path = directory / f"{key}-formatted.html"
        html = path.read_text(encoding="utf-8")
        if "img-src banana-mail-image:" not in html:
            raise ValueError(f"Expected a Banana embedded formatted snapshot at {path}")
        html = html.replace("img-src banana-mail-image:", "img-src data:", 1)
        # Preserve destination equality without exposing destinations or enabling navigation.
        destinations = {}
        def preview_link(match):
            destination = destinations.setdefault(match[2], len(destinations) + 1)
            return f'{match[1]}href="#review-link-{destination}"'

        html = re.sub(r'(<a\b[^>]*?)\bhref="([^"]*)"', preview_link, html, flags=re.I)
        previews[key] = html
        cases.append({
            "id": key, "title": title, "revision": hashlib.sha256(html.encode() + rules).hexdigest()[:12],
        })
    return cases, previews


class ReviewServer(ThreadingHTTPServer):
    def __init__(self, port, directory, state, proxy_origin=None, *, titles=CASES, quiet=False):
        self.cases, self.previews = prepare_cases(directory, titles)
        self.state = state
        self.quiet = quiet
        self.lock = threading.Lock()
        super().__init__(("127.0.0.1", port), Handler)
        self.host = f"127.0.0.1:{self.server_port}"
        self.origin = f"http://{self.host}"
        self.origins = {self.host: self.origin}
        if proxy_origin:
            self.origins[urlparse(proxy_origin).netloc] = proxy_origin

    def read_reviews(self):
        if self.state.exists():
            return json.loads(self.state.read_text(encoding="utf-8"))
        return {}

    def update(self, action):
        if not isinstance(action, dict):
            raise ValueError("Expected a feedback object.")
        case_id = action.get("case")
        case = next((item for item in self.cases if case_id == item["id"]), None)
        if case is None or action.get("revision") != case["revision"]:
            raise ValueError("This preview changed. Reload before saving.")
        with self.lock:
            state = self.read_reviews()
            review = state.setdefault(case_id, {}).setdefault(
                case["revision"], {"vote": None, "notes": []}
            )
            if action.get("type") != "note":
                raise ValueError("Unknown feedback action.")
            note = self.note(action, datetime.now(timezone.utc).isoformat())
            if any(existing["id"] == note["id"] for existing in review["notes"]):
                return review
            review["notes"].append(note)
            self.state.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.state.with_suffix(".tmp")
            with temporary.open("w", encoding="utf-8") as file:
                os.chmod(temporary, 0o600)
                json.dump(state, file, ensure_ascii=False, indent=2)
                file.write("\n")
                file.flush()
                os.fsync(file.fileno())
            temporary.replace(self.state)
            return review

    @staticmethod
    def note(action, timestamp):
        note_id = action.get("id")
        if not isinstance(note_id, str) or not re.fullmatch(r"[0-9a-f-]{36}", note_id):
            raise ValueError("Invalid note ID.")
        body = action.get("body")
        width, images, anchor = action.get("width"), action.get("images"), action.get("anchor")
        if not isinstance(body, str) or not 0 < len(body.strip()) <= 2000:
            raise ValueError("Enter a note of 1–2,000 characters.")
        if width not in WIDTHS or type(images) is not bool:
            raise ValueError("Invalid preview context.")
        if anchor is not None:
            if (
                not isinstance(anchor, dict)
                or type(anchor.get("element")) is not int or not 0 <= anchor["element"] <= 50000
                or any(type(anchor.get(axis)) not in (int, float) or not 0 <= anchor[axis] <= 1
                       for axis in ("x", "y"))
                or not isinstance(anchor.get("excerpt"), str) or len(anchor["excerpt"]) > 160
            ):
                raise ValueError("Invalid annotation location.")
            anchor = {key: anchor[key] for key in ("element", "x", "y", "excerpt")}
        return {
            "id": note_id, "body": body.strip(), "variant": REVIEW_VARIANT,
            "width": width, "images": images, "anchor": anchor, "savedAt": timestamp,
        }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        if not self.server.quiet:
            super().log_message(format, *args)

    def respond(self, status, body, content_type="application/json", csp=UI_CSP):
        self.send_response(status)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy", csp)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def json(self, status, data):
        self.respond(status, json.dumps(data, ensure_ascii=False).encode())

    def do_GET(self):
        if self.headers.get("Host") not in self.server.origins:
            return self.json(403, {"error": "Open a configured review address."})
        path = urlparse(self.path).path
        if path in STATIC:
            filename, mime = STATIC[path]
            return self.respond(200, (HERE / filename).read_bytes(), mime)
        if path == "/api/review":
            with self.server.lock:
                state = self.server.read_reviews()
            return self.json(200, {"cases": self.server.cases, "reviews": state})
        if path.startswith("/preview/"):
            html = self.server.previews.get(path.removeprefix("/preview/"))
            if html is not None:
                return self.respond(200, html.encode(), "text/html", PREVIEW_CSP)
        self.json(404, {"error": "Page not found."})

    def do_POST(self):
        origin = self.server.origins.get(self.headers.get("Host"))
        if (
            not origin
            or self.headers.get("Origin") != origin
            or self.headers.get_content_type() != "application/json"
        ):
            return self.json(403, {"error": "Feedback must come from the local review page."})
        if self.path != "/api/review":
            return self.json(404, {"error": "Page not found."})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 24576:
                raise ValueError("Invalid feedback size.")
            action = json.loads(self.rfile.read(length))
            self.json(200, self.server.update(action))
        except ValueError as error:
            self.json(400, {"error": str(error)})
        except OSError:
            self.json(500, {"error": "Could not save feedback to disk. Try again."})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--snapshots", type=Path, default=ROOT / "private/newsletter-check")
    parser.add_argument("--state", type=Path, default=ROOT / "private/mail-review/feedback.json")
    parser.add_argument("--proxy-origin", help="Exact browser origin for a trusted loopback reverse proxy")
    args = parser.parse_args()
    if args.proxy_origin and not re.fullmatch(
        r"https?://[a-z0-9.-]+(?::[0-9]+)?", args.proxy_origin
    ):
        parser.error("--proxy-origin requires an HTTP(S) origin without a path")
    try:
        with ReviewServer(args.port, args.snapshots, args.state, args.proxy_origin) as server:
            print(server.origin, flush=True)
            server.serve_forever()
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
