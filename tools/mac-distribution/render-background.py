#!/usr/bin/env python3
# /// script
# dependencies = ["playwright==1.64.1"]
# ///
"""Render the editable HTML installer artwork at standard and Retina sizes.

uv run tools/mac-distribution/render-background.py
Uses headless Chrome; never opens or focuses a window.
"""
from pathlib import Path
from playwright.sync_api import sync_playwright

artwork = Path(__file__).with_name('artwork').resolve()
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(
        executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        headless=True)
    try:
        for scale in (1, 2):
            page = browser.new_page(viewport={'width': 720, 'height': 480}, device_scale_factor=scale)
            page.goto((artwork / 'background.html').as_uri())
            page.evaluate('document.fonts.ready')
            page.screenshot(path=str(artwork / ('background' + ('@2x' if scale == 2 else '') + '.png')))
            page.close()
    finally:
        browser.close()
