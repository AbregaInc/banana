#!/usr/bin/env python3
"""Export the approved dimensional mascot into native and website brand assets.

Needs Pillow and librsvg's rsvg-convert. The original SVG and reference PNG are
retained in Brand/. iOS/Watch apply their own icon mask, so their exports are opaque.
"""
from pathlib import Path
import argparse
from functools import lru_cache
import io
import json
import shutil
import subprocess
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Brand/BananaMascot.svg"
INK = "#11171B"


def raster(svg: str, size: int) -> Image.Image:
    result = subprocess.run(["rsvg-convert", "--width", str(size), "--height", str(size)],
                            input=svg.encode(), capture_output=True, check=True)
    return Image.open(io.BytesIO(result.stdout)).convert("RGBA")


@lru_cache(maxsize=1)
def master() -> Image.Image:
    image = Image.open(ROOT / "Brand/BananaMascot.png").convert("RGBA")
    assert image.getextrema()[3] == (255, 255), "Native icon master must be opaque"
    return image.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)



def icon(size: int, *, beta: bool = False, mac: bool = False) -> Image.Image:
    canvas = master().copy()
    if beta:
        # Keep the eyes, eyebrow and subtle mouth unobscured.
        draw = ImageDraw.Draw(canvas)
        draw.rounded_rectangle((85, 88, 380, 218), radius=28, fill=INK)
        face = ImageFont.truetype(str(ROOT/"tools/app-store/fonts/IBMPlexMono-700.ttf"), 66)
        draw.text((232, 150), "BETA", font=face, anchor="mm", fill="#FFDC56")
    if mac:
        mask = Image.new("L", canvas.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((24, 24, 1000, 1000), radius=204, fill=255)
        canvas.putalpha(mask)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def monochrome() -> Image.Image:
    """Separate feature-shaped alpha glyph for red/black and other tinted faces."""
    return raster((ROOT / "Brand/BananaMonochrome.svg").read_text(), 100)



def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT/"AppStore/Generated")
    args = parser.parse_args()
    brand = ROOT/"Brand"
    # SVG consumers use an embedded raster with a platform-like corner mask.
    # The opaque raster is canonical; never reconstruct it from the historical flat SVG.
    import base64
    encoded = base64.b64encode((brand / "BananaMascot.png").read_bytes()).decode()
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
           '<defs><clipPath id="tile"><rect width="1024" height="1024" rx="220"/></clipPath></defs>'
           '<image width="1024" height="1024" clip-path="url(#tile)" href="data:image/png;base64,' + encoded + '"/></svg>')
    for name in ("BananaMascot.svg", "BananaMark.svg", "BananaAppIcon.svg"):
        (brand / name).write_text(svg)
    raster(svg, 1024).save(brand / "BananaMascotReference.png", optimize=True)
    icon(1024).save(brand/"BananaAppIconMaster.png", optimize=True)
    for folder, beta, mac in [("Banana",False,False),("Banana",True,False),
                              ("BananaMac",False,True),("BananaMac",True,True),
                              ("BananaWatch",False,False)]:
        assets = ROOT/folder/"Assets.xcassets"/("AppIconBeta.appiconset" if beta else "AppIcon.appiconset")
        for item in json.loads((assets/"Contents.json").read_text())["images"]:
            if not item.get("filename"): continue
            size = round(float(item["size"].split("x")[0])*float(item.get("scale","1x").removesuffix("x")))
            icon(size, beta=beta, mac=mac).save(assets/item["filename"], optimize=True)
    marks = ROOT/"Banana/Brand.xcassets/BrandMark.imageset"
    for item in json.loads((marks/"Contents.json").read_text())["images"]:
        size = 112*int(item["scale"].removesuffix("x"))
        icon(size).save(marks/item["filename"], optimize=True)
    widget = ROOT/"BananaWatchWidget/Assets.xcassets"
    glyph = icon(100).convert("RGBA")
    mask = Image.new("L", (100,100), 0)
    ImageDraw.Draw(mask).ellipse((0,0,99,99), fill=255)
    glyph.putalpha(mask)
    glyph.save(widget/"ComplicationIcon.imageset/complication-icon.png", optimize=True)
    # Tinted faces use a true transparent feature glyph, never the opaque yellow tile.
    old = widget/"BananaMark.symbolset"
    if old.exists(): shutil.rmtree(old)
    template = widget/"BananaMark.imageset"
    template.mkdir(exist_ok=True)
    monochrome().save(template/"mascot-template.png", optimize=True)
    (template/"Contents.json").write_text(json.dumps({"images":[{"filename":"mascot-template.png","idiom":"universal"}],
        "info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template"}},indent=2)+"\n")
    output = args.output/"brand"
    output.mkdir(parents=True, exist_ok=True)
    for source in (brand/"BananaMark.svg", brand/"BananaAppIcon.svg", brand/"BananaAppIconMaster.png"):
        (output/source.name).write_bytes(source.read_bytes())
    icon(1024, beta=True).save(output/"BananaBetaAppIconMaster.png", optimize=True)
    site = ROOT/"LandingPage/site"
    (site/"assets/img/banana-mark.svg").write_bytes(SOURCE.read_bytes())
    for name, size in [("apple-touch-icon.png",180),("favicon-48.png",48)]:
        icon(size).save(site/name, optimize=True)
    raster(SOURCE.read_text(),192).save(site/"assets/img/mark-192.webp", "WEBP", quality=92)
    # One command keeps the cloud app and its compact SVG wrapper in step too.
    import importlib.util
    spec = importlib.util.spec_from_file_location("banana_site_brand", ROOT / "LandingPage/build_site.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.cloud_brand()
    # Booking pages remain self-contained. Their 16px footer needs only a 3x raster,
    # also reused as the inline favicon rather than embedding the large master.
    compact = io.BytesIO()
    Image.open(brand / "BananaMascotReference.png").resize((48, 48), Image.Resampling.LANCZOS).save(compact, "PNG", optimize=True)
    data = "data:image/png;base64," + base64.b64encode(compact.getvalue()).decode()
    (ROOT / "Service/src/booking/pages/brand.gen.js").write_text(
        "// Generated by tools/app-store/brand.py from the approved mascot.\n"
        + "export const ICON = " + json.dumps(data) + ";\n"
        + 'export const LOGO = `<svg viewBox="0 0 48 48" aria-hidden="true"><image width="48" height="48" href="${ICON}"/></svg>`;\n')



if __name__ == "__main__":
    main()
