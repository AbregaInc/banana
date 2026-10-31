#!/usr/bin/env python3
"""Prepare/upload draft media through Apple's new App Asset Library. Never submit.

Reads live specifications and device groups instead of legacy screenshot-set enums.
Dry-run unless --apply. --place explicitly replaces only matching unpublished draft
placements, retaining old assets and a restoration record. Reuse --out to resume.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time
import urllib.request
import urllib.error
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
API = "https://api.appstoreconnect.apple.com"
FOLDERS = {"iphone":("iphone-6.9","IPHONE_APP_STORE","IOS"),
           "ipad":("ipad-13","IPAD_APP_STORE","IOS"),
           "watch":("watch","WATCH_APP_STORE","IOS"),
           "mac":("mac","MAC_APP_STORE","MAC_OS")}


def matches(image, path, spec, placement_type):
    if placement_type not in spec.get("compatiblePlacementTypes",[]): return False
    d = spec["dimensions"]
    w,h = image.size
    if not (d["minWidth"] <= w <= d["maxWidth"] and d["minHeight"] <= h <= d["maxHeight"]): return False
    if path.suffix.lower() not in spec["fileExtensions"] or path.stat().st_size > spec["maxFileSize"]: return False
    if not spec.get("alphaAllowed",False) and (image.mode != "RGB" or "transparency" in image.info): return False
    if d["minWidth"] == d["maxWidth"] and d["minHeight"] == d["maxHeight"]: return True
    a,b = map(int,spec["aspectRatio"].split(":"))
    return abs(w*b-h*a) <= max(a,b) # Header specifications allow whole-pixel rounding.


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--package",type=Path,default=ROOT/"AppStore/Generated")
    p.add_argument("--out",type=Path,required=True)
    p.add_argument("--platform",choices=["all",*FOLDERS],default="all")
    p.add_argument("--creative",action="store_true")
    p.add_argument("--apply",action="store_true")
    p.add_argument("--place",action="store_true")
    args=p.parse_args()
    if args.place and not args.apply: p.error("--place requires --apply")
    args.out.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location("asc",ROOT/"tools/asc-builds.py")
    asc=importlib.util.module_from_spec(spec);spec.loader.exec_module(asc)
    def get(path,**params):
        for attempt in range(3):
            try:
                result=asc.get(path,**params)
                if "error" in result: raise RuntimeError(f"GET {path}: {result['error']}")
                return result
            except (TimeoutError, urllib.error.URLError):
                if attempt == 2: raise
                time.sleep(attempt+1)
    def send(method,path,data=None):
        body=json.dumps({"data":data}).encode() if data else None
        request=urllib.request.Request(API+path,method=method,data=body,
            headers={"Authorization":"Bearer "+asc.token(),"Content-Type":"application/json"})
        try:
            with urllib.request.urlopen(request,timeout=60) as response:
                raw=response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path}: {error.code} {error.read().decode()[:600]}") from error
    app=get("/v1/apps",**{"filter[bundleId]":asc.BUNDLE_ID})["data"]
    if len(app)!=1:raise RuntimeError("Cannot uniquely identify Banana")
    app=app[0]["id"]
    library=get(f"/v1/apps/{app}/assetLibrary")["data"]["id"]
    catalog=get("/v1/appAssetLibraryRefData")
    (args.out/"catalog.json").write_text(json.dumps(catalog,indent=2)+"\n")
    catalog=catalog["data"][0]["attributes"]
    feature=next(x for x in catalog["features"] if x["featureId"]=="APP_STORE_VERSIONS")
    groups={x["placementProfileGroupId"]:x for x in catalog["placementProfileGroups"]}
    specs={x["specId"]:x for x in catalog["imageSpecs"]}
    kinds={x["placementTypeId"]:x for x in catalog["placementTypes"]}
    versions={v["attributes"]["platform"]:v for v in get(f"/v1/apps/{app}/appStoreVersions")["data"] if v["attributes"]["appStoreState"]=="PREPARE_FOR_SUBMISSION"}
    targets={}
    for platform,v in versions.items():
        locs=get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
        targets[platform]=next(x["id"] for x in locs if x["attributes"]["locale"]=="en-US")
    platforms=list(FOLDERS) if args.platform=="all" else [args.platform]
    files=[]
    for platform in platforms:
        folder,device,store=FOLDERS[platform]
        paths=sorted((args.package/"screenshots"/folder).glob("*.png"))
        if not paths:raise RuntimeError("Missing screenshot set: "+platform)
        files += [(path,"APP_SCREENSHOT",device,store,platform) for path in paths]
    if args.creative:
        files += [(args.package/"creative/en-US/header-3840x1646.png","PRODUCT_PAGE_HEADER_ASSET","ANY","IOS","header"),
                  (args.package/"creative/en-US/search-1920x1280.png","APP_STORE_SEARCH_RESULTS_ASSET","ANY","IOS","search")]
    plan=[]
    for path,kind,device,store,platform in files:
        with Image.open(path) as image:
            eligible={key for key,s in specs.items() if matches(image,path,s,kind)}
        candidates=[mapping for mapping in kinds[kind]["specMappings"] if groups[mapping["placementGroupId"]]["platform"]==device and eligible.intersection(mapping["specs"])]
        if len(candidates)!=1:raise RuntimeError(f"Ambiguous/unavailable placement for {path}: {len(candidates)}")
        mapping=candidates[0];group=mapping["placementGroupId"]
        limits=[limit["maxCount"] for policy in feature["placementPolicies"] if policy["placementType"]==kind for limit in policy["groupLimits"] if group in limit["groupIds"]]
        if not limits:raise RuntimeError("Unavailable feature/group: "+group)
        plan.append({"file":str(path),"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"kind":kind,"group":group,
                     "locale":targets[store],"store":store,"platform":platform,
                     "specIds":sorted(eligible.intersection(mapping["specs"])),
                     "category":kinds[kind]["acceptsAssetCategories"][0],"limit":min(limits)})
    buckets={}
    for item in plan:buckets.setdefault((item["locale"],item["kind"],item["group"]),[]).append(item)
    if any(len(items)>items[0]["limit"] for items in buckets.values()):raise RuntimeError("Placement count exceeds Apple's live limit")
    (args.out/"plan.json").write_text(json.dumps(plan,indent=2)+"\n")
    if not args.apply:
        print(f"Validated {len(plan)} files against Apple's live catalog; {len(buckets)} draft groups. No changes sent.")
        return
    captured=json.loads((args.package/"capture-status.json").read_text()).get("freshPlatforms",{})
    required=set(platforms)
    if "iphone" in required:required.update(["mac","watch"])
    if args.creative:required.update(["iphone","mac"])
    if not required.issubset(captured):raise RuntimeError("Fresh candidate captures required for: "+", ".join(sorted(required-set(captured))))
    for platform in required:
        hashes=captured[platform].get("rawSHA256",{})
        paths=sorted((args.package/"raw"/platform).glob("*.png"))
        if not hashes or {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}!=hashes:
            raise RuntimeError("Capture evidence mismatch: "+platform)
    state_file=args.out/"state.json"
    state=json.loads(state_file.read_text()) if state_file.exists() else {"assets":{},"placements":{},"submitted":False}
    def save():state_file.write_text(json.dumps(state,indent=2)+"\n")
    for item in plan:
        path=Path(item["file"]);key=item["sha256"]+":"+item["category"]
        if key not in state["assets"]:
            result=send("POST","/v1/appAssetLibraryImages",{"type":"appAssetLibraryImages","attributes":{
                "fileName":path.name,"fileSize":path.stat().st_size,"category":item["category"],
                "referenceName":f"Banana website — {item['platform']} — {path.stem} — {item['sha256'][:12]}"},
                "relationships":{"assetLibrary":{"data":{"type":"appAssetLibraries","id":library}}}})["data"]
            state["assets"][key]={"id":result["id"],"uploaded":False};save()
        asset=state["assets"][key];image=get("/v1/appAssetLibraryImages/"+asset["id"])["data"]
        if image["attributes"]["state"]=="AWAITING_UPLOAD":
            content=path.read_bytes()
            for operation in image["attributes"]["uploadOperations"]:
                request=urllib.request.Request(operation["url"],method=operation["method"],
                    data=content[operation["offset"]:operation["offset"]+operation["length"]],
                    headers={h["name"]:h["value"] for h in operation["requestHeaders"]})
                with urllib.request.urlopen(request,timeout=60) as response:response.read()
            send("PATCH","/v1/appAssetLibraryImages/"+asset["id"],{"type":"appAssetLibraryImages","id":asset["id"],"attributes":{"uploaded":True}})
        deadline=time.monotonic()+600
        while True:
            image=get("/v1/appAssetLibraryImages/"+asset["id"])["data"];status=image["attributes"]["state"]
            if status not in ["AWAITING_UPLOAD","UPLOAD_COMPLETE","COMPLETE"]:break
            if time.monotonic()>deadline:raise RuntimeError("Processing timeout; resume this run later: "+path.name)
            time.sleep(2)
        if status not in ["PREPARE_FOR_SUBMISSION","APPROVED","ACTIVE"]:raise RuntimeError(f"Asset processing {status}: {path.name}")
        if image["attributes"].get("specId") not in item["specIds"]:raise RuntimeError("Apple matched an unexpected specification: "+path.name)
        asset.update(uploaded=True,state=status);item["assetID"]=asset["id"];save()
        print(f"Processed {item['platform']}/{path.name}: {status}",flush=True)
    if not args.place:
        print("Assets uploaded to the library only; draft placements unchanged.")
        return
    for (locale,kind,group),items in buckets.items():
        version=versions[items[0]["store"]]
        if get("/v1/appStoreVersions/"+version["id"])["data"]["attributes"]["appStoreState"]!="PREPARE_FOR_SUBMISSION":
            raise RuntimeError("Draft is no longer editable; placements untouched")
        existing=get(f"/v1/appStoreVersionLocalizations/{locale}/placements",**{"filter[placementType]":kind,"filter[placementGroup]":group,"sort":"placementGroupPosition","limit":"200"})["data"]
        bucket_key=locale+":"+kind+":"+group
        if bucket_key not in state["placements"]:
            state["placements"][bucket_key]={"before":existing,"created":[]};save()
        desired=[item["assetID"] for item in items]
        current=[(x.get("relationships",{}).get("image",{}).get("data") or {}).get("id") for x in existing]
        if current==desired:continue
        # All replacements have finished processing before removing any draft placement.
        # Underlying previous images remain in the library and in the restoration record.
        for old in existing:send("DELETE","/v1/appAssetLibraryPlacements/"+old["id"])
        created=[]
        for item in items:
            result=send("POST","/v1/appAssetLibraryPlacements",{"type":"appAssetLibraryPlacements","attributes":{"placementType":kind,"placementGroup":group},
                "relationships":{"image":{"data":{"type":"appAssetLibraryImages","id":item["assetID"]}},
                "appStoreVersionLocalization":{"data":{"type":"appStoreVersionLocalizations","id":locale}}}})["data"]
            created.append(result["id"]);state["placements"][bucket_key]["created"]=created;save()
        send("POST","/v1/appAssetLibraryPlacementOrderingRequests",{"type":"appAssetLibraryPlacementOrderingRequests","attributes":{"placementGroup":group},
            "relationships":{"orderedPlacements":{"data":[{"type":"appAssetLibraryPlacements","id":i} for i in created]},
            "appStoreVersionLocalization":{"data":{"type":"appStoreVersionLocalizations","id":locale}}}})
        actual=get(f"/v1/appStoreVersionLocalizations/{locale}/placements",**{"filter[placementType]":kind,"filter[placementGroup]":group,"sort":"placementGroupPosition","include":"image","limit":"200"})["data"]
        if [x["relationships"]["image"]["data"]["id"] for x in actual]!=desired:raise RuntimeError("Placement read-back order differs")
        state["placements"][bucket_key]["verified"]=True;save()
        print(f"Verified {kind}/{group}: {len(created)} unpublished placements",flush=True)
    print("Draft media updated. No review submission or release.")


if __name__=="__main__":main()
