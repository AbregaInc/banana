#!/usr/bin/env python3
"""Update only Banana's unpublished English App Store text drafts. Never submit or release.

Dry-run by default. Retains the exact proposed patches and previous values in --out, and a
diff.json of every field that would change (old and new value).
--flavour <name> takes the text from that listing's metadata folder (flavours/<name>.json).
Optional files (marketing_url, support_url, copyright, privacy_url) are sent when present.
--review-notes also sets App Review's Notes from review_notes.txt; it never touches the sign-in
fields (demo account name and password) or the contact.
Screenshots/build selection, pricing, contacts and legal declarations are separate operations.
"""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import listing  # noqa: E402

NOTES_LIMIT = 4000
# File in the metadata folder -> attribute, per resource. Files that are absent are not sent.
VERSION_FIELDS = {"description": "description", "keywords": "keywords", "promotional_text": "promotionalText",
                  "marketing_url": "marketingUrl", "support_url": "supportUrl"}
INFO_FIELDS = {"name": "name", "subtitle": "subtitle", "privacy_url": "privacyPolicyUrl"}


def attributes(folder, fields):
    """The attributes a metadata folder sets: one per file present."""
    return {attr: (folder/(name+".txt")).read_text().strip() for name, attr in fields.items() if (folder/(name+".txt")).exists()}


def changes(before, patches):
    """Every attribute a patch would change: path, field, old and new value."""
    old = {f"/v1/{b['type']}/{b['id']}": b["attributes"] for b in before}
    out = []
    for patch in patches:
        for key, value in patch["data"]["attributes"].items():
            was = old.get(patch["path"], {}).get(key)
            if was != value: out.append({"path": patch["path"], "field": key, "old": was, "new": value})
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--flavour", choices=listing.names(), help="another listing's text, such as calendar-only")
    parser.add_argument("--review-notes", action="store_true", help="also set App Review's Notes from review_notes.txt")
    args = parser.parse_args()
    if args.out.exists():
        sys.exit("Choose a new evidence directory; existing runs are never overwritten.")
    args.out.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location("asc", ROOT/"tools/asc-builds.py")
    asc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asc)
    metadata = listing.load(args.flavour)["metadata"]
    version_text = attributes(metadata, VERSION_FIELDS)
    info_text = attributes(metadata, INFO_FIELDS)
    copyright_file = metadata/"copyright.txt"
    notes = (metadata/"review_notes.txt").read_text().strip() if args.review_notes else None
    if notes is not None and len(notes) > NOTES_LIMIT:
        sys.exit(f"review_notes.txt is {len(notes)} characters; App Review's Notes hold {NOTES_LIMIT}")
    def get(path):
        result = asc.get(path)
        if "error" in result: raise RuntimeError(f"GET {path}: {result['error']}")
        return result
    apps = asc.get("/v1/apps", **{"filter[bundleId]":asc.BUNDLE_ID})
    if "error" in apps or len(apps.get("data",[])) != 1: raise RuntimeError("Cannot identify Banana app")
    app = apps["data"][0]["id"]
    versions = get(f"/v1/apps/{app}/appStoreVersions")["data"]
    candidates = [v for v in versions if v["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION"]
    if {v["attributes"]["platform"] for v in candidates} != {"IOS","MAC_OS"} or len(candidates) != 2:
        raise RuntimeError("Expected exactly two unpublished iOS/Mac drafts")
    patches, before = [], []
    for version in candidates:
        for loc in get(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]:
            if loc["attributes"]["locale"] != "en-US": continue
            before.append(loc)
            patches.append({"path":f"/v1/appStoreVersionLocalizations/{loc['id']}","data":{
                "type":"appStoreVersionLocalizations", "id":loc["id"], "attributes":dict(version_text)}})
        if copyright_file.exists():
            before.append({"type":"appStoreVersions","id":version["id"],"attributes":{"copyright":version["attributes"].get("copyright")}})
            patches.append({"path":f"/v1/appStoreVersions/{version['id']}","data":{
                "type":"appStoreVersions","id":version["id"],"attributes":{"copyright":copyright_file.read_text().strip()}}})
        if notes is not None:
            detail = get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail")["data"]
            # Only the notes: the sign-in fields stay as they are and are never read into evidence.
            before.append({"type":"appStoreReviewDetails","id":detail["id"],"attributes":{"notes":detail["attributes"].get("notes")}})
            patches.append({"path":f"/v1/appStoreReviewDetails/{detail['id']}","data":{
                "type":"appStoreReviewDetails","id":detail["id"],"attributes":{"notes":notes}}})
    for info in get(f"/v1/apps/{app}/appInfos")["data"]:
        if info["attributes"].get("appStoreState") != "PREPARE_FOR_SUBMISSION": continue
        for loc in get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]:
            if loc["attributes"]["locale"] != "en-US": continue
            before.append(loc)
            patches.append({"path":f"/v1/appInfoLocalizations/{loc['id']}","data":{
                "type":"appInfoLocalizations", "id":loc["id"], "attributes":dict(info_text)}})
    kinds = [p["data"]["type"] for p in patches]
    if kinds.count("appStoreVersionLocalizations") != 2 or kinds.count("appInfoLocalizations") != 1:
        raise RuntimeError("Expected two version texts and one app-info localization")
    (args.out/"before.json").write_text(json.dumps(before,indent=2)+"\n")
    (args.out/"proposed.json").write_text(json.dumps(patches,indent=2)+"\n")
    diff = changes(before, patches)
    (args.out/"diff.json").write_text(json.dumps(diff,indent=2)+"\n")
    for row in diff:
        print(f"{row['path']} {row['field']}: {len(row['old'] or '')} -> {len(row['new'])} characters")
    status = {"applied":False, "submitted":False, "patchCount":len(patches), "utc":datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (args.out/"status.json").write_text(json.dumps(status,indent=2)+"\n")
    if not args.apply:
        print(f"Prepared {len(patches)} draft text patches; no changes sent. {args.out}")
        return
    completed=[]
    try:
        for patch in patches:
            request=urllib.request.Request("https://api.appstoreconnect.apple.com"+patch["path"], method="PATCH",
                data=json.dumps({"data":patch["data"]}).encode(), headers={"Authorization":"Bearer "+asc.token(),"Content-Type":"application/json"})
            with urllib.request.urlopen(request, timeout=60) as response:
                result=json.load(response)
            expected=patch["data"]["attributes"]
            actual=get(patch["path"])["data"]["attributes"]
            if any(actual.get(k) != v for k,v in expected.items()): raise RuntimeError("Read-back mismatch for "+patch["path"])
            completed.append(patch["path"])
            (args.out/"completed.json").write_text(json.dumps(completed,indent=2)+"\n")
        status["applied"]=True
        print(f"Updated and read back {len(completed)} unpublished text drafts. No submission or release.")
    except Exception as error:
        status["error"]=str(error)
        raise
    finally:
        status["completed"]=completed
        (args.out/"status.json").write_text(json.dumps(status,indent=2)+"\n")


if __name__ == "__main__": main()
