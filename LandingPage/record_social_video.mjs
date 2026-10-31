#!/usr/bin/env node
// Records the front page's calendar story as the link-preview video, site/assets/video/social.mp4.
// Messages plays an og:video that is a plain MP4 in the preview, muted and looping; everywhere
// else the preview keeps social.png.
//
//   cd LandingPage && npm install && node record_social_video.mjs
//
// Serves site/ itself, opens it headless at 1200 wide, hides the top bar and the buttons so it is
// framed like social.png, then steps the page's own Web Animations timeline one frame at a time
// (no real-time capture, so no dropped frames). Needs ffmpeg. Re-run after any change to the scene.
import { chromium } from "playwright-core";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const SITE = join(HERE, "site");
const OUT = join(SITE, "assets/video/social.mp4");
const FPS = 30;
const STORY = 11.4;   // the last beat ends at FINALE + .95 + .4 (index.html)
const HOLD = 2.2;     // the finished day, held
const FADE = 0.3;     // back to the empty day, so the loop's seam matches the page's own loop

const types = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2", ".svg": "image/svg+xml" };
const server = createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
  try {
    const file = join(SITE, path.endsWith("/") ? path + "index.html" : path);
    res.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream" }).end(readFileSync(file));
  } catch { res.writeHead(404).end(); }
}).listen(0, "127.0.0.1");
await new Promise(r => server.once("listening", r));
const url = `http://127.0.0.1:${server.address().port}/`;

const frames = mkdtempSync(join(tmpdir(), "banana-social-"));
// Headless shell, not headless Chrome: Chrome's new headless stops producing frames once the
// animations are paused, and screenshots then wait forever.
const browser = await chromium.launch({ channel: "chromium-headless-shell", args: ["--hide-scrollbars"] });
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 }, deviceScaleFactor: 1 });
  // Drop the page's long timers (the story's end, the hold before a replay) so its own loop never
  // fires during capture.
  await page.addInitScript(() => { const st = window.setTimeout; window.setTimeout = (fn, ms, ...a) => (ms >= 3000 ? 0 : st(fn, ms, ...a)); });
  await page.goto(url, { waitUntil: "load" });
  await page.evaluate(() => document.fonts.ready);
  await page.addStyleTag({ content: `
    .skip, .pad:has(> header.top), .hero .btn, .hero .also { display: none !important; }
    .hero { padding-block: 18px 10px !important; gap: 10px !important; }
  ` });
  await page.evaluate(() => Promise.all([...document.images].map(i => i.decode().catch(() => {}))));
  if (!(await page.evaluate(() => document.getAnimations().length))) throw new Error("the story did not start");

  const seek = t => page.evaluate(ms => document.getAnimations().forEach(a => { a.pause(); a.currentTime = ms; }), t * 1000);
  const fade = o => page.evaluate(o => document.querySelectorAll("#scene .blk.real, #scene .blk.busy, #scene .blk.trip, #scene [data-beat], #scene .cable, #scene .dot")
    .forEach(el => { el.style.opacity = o === null ? "" : String(o * Number(getComputedStyle(el).opacity)); }), o);
  let f = 0;
  const shot = () => page.screenshot({ path: join(frames, `f${String(f++).padStart(4, "0")}.png`), clip: { x: 0, y: 0, width: 1200, height: 630 } });
  for (let i = 0; i < Math.round((STORY + HOLD) * FPS); i++) { await seek(Math.min(i / FPS, STORY)); await shot(); }
  for (let i = 1; i <= Math.round(FADE * FPS); i++) { await seek(STORY); await fade(1 - i / (FADE * FPS)); await shot(); await fade(null); }

  // H.264 High, yuv420p, no sound, moov first: what Messages plays inline.
  execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-framerate", String(FPS), "-i", join(frames, "f%04d.png"),
    "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-pix_fmt", "yuv420p", "-preset", "veryslow",
    "-tune", "animation", "-crf", "20", "-movflags", "+faststart", "-an", OUT], { stdio: "inherit" });
  console.log(`${f} frames → ${OUT} (${Math.round(statSync(OUT).size / 1000)} KB)`);
} finally {
  await browser.close();
  server.close();
  rmSync(frames, { recursive: true, force: true });
}
