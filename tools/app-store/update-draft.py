#!/usr/bin/env python3
"""Update only Banana's unpublished English App Store text drafts. Never submit or release.

Dry-run by default. Retains the exact proposed patches and previous values in --out.
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.out.exists():
        sys.exit("Choose a new evidence directory; existing runs are never overwritten.")
    args.out.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location("asc", ROOT/"tools/asc-builds.py")
    asc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asc)
    metadata = ROOT/"tools/app-store/metadata/en-US"
    def value(name): return (metadata/(name+".txt")).read_text().strip()
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
                "type":"appStoreVersionLocalizations", "id":loc["id"], "attributes":{
                    "description":value("description"), "keywords":value("keywords"),
                    "promotionalText":value("promotional_text")}}})
    for info in get(f"/v1/apps/{app}/appInfos")["data"]:
        if info["attributes"].get("appStoreState") != "PREPARE_FOR_SUBMISSION": continue
        for loc in get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]:
            if loc["attributes"]["locale"] != "en-US": continue
            before.append(loc)
            patches.append({"path":f"/v1/appInfoLocalizations/{loc['id']}","data":{
                "type":"appInfoLocalizations", "id":loc["id"], "attributes":{
                    "name":value("name"), "subtitle":value("subtitle")}}})
    if len(patches) != 3: raise RuntimeError("Expected two version texts and one app-info localization")
    (args.out/"before.json").write_text(json.dumps(before,indent=2)+"\n")
    (args.out/"proposed.json").write_text(json.dumps(patches,indent=2)+"\n")
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
