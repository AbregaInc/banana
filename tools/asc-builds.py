#!/usr/bin/env python3
"""List the builds App Store Connect holds for Banana. Read-only.

    python3 tools/asc-builds.py

Uses the Banana TestFlight API key (`~/.config/banana/release.env`) and needs PyJWT and cryptography.
It is also the one-second check to make before an archive: if Apple answers
FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED here, the upload will be refused too,
until the Account Holder accepts the pending agreement. And it is where to look a few
minutes after an upload: "latest uploads" says whether Apple kept it, and why not.
"""
import jwt, time, json, sys, os, urllib.request, urllib.parse
import re, pathlib
def _config(name):
    """Your own build config (Config/Local.xcconfig), else the stand-in."""
    root = pathlib.Path(__file__).resolve()
    while not (root / "Config").is_dir(): root = root.parent
    for f in ("Local.xcconfig", "Base.xcconfig"):
        p = root / "Config" / f
        if p.exists():
            m = re.search(rf"^{name}\s*=\s*(\S+)", p.read_text(), re.M)
            if m: return m.group(1)
    raise SystemExit(f"{name} is not set in Config/")
# The App Store Connect API key: ASC_KEY_ID and ASC_ISSUER_ID (tools/config.sh says where they live).
def _release(name):
    if name in os.environ: return os.environ[name]
    p = pathlib.Path.home() / ".config/banana/release.env"
    m = re.search(rf"^(?:export\s+)?{name}=(\S+)", p.read_text() if p.exists() else "", re.M)
    if not m: raise SystemExit(f"set {name} (see tools/config.sh)")
    return m.group(1)
KEY_ID=_release("ASC_KEY_ID"); ISSUER=_release("ASC_ISSUER_ID")
BUNDLE_ID=_config("BANANA_BUNDLE_ID")
key=open(os.path.expanduser(os.environ.get("ASC_KEY_PATH", f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"))).read()
def token():
    now=int(time.time())
    return jwt.encode({"iss":ISSUER,"iat":now,"exp":now+900,"aud":"appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid":KEY_ID})
def get(path, **params):
    url="https://api.appstoreconnect.apple.com"+path+("?"+urllib.parse.urlencode(params) if params else "")
    req=urllib.request.Request(url, headers={"Authorization":"Bearer "+token()})
    try:
        with urllib.request.urlopen(req, timeout=30) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()[:600]}
if __name__=="__main__":
    apps=get("/v1/apps", **{"filter[bundleId]":BUNDLE_ID,"fields[apps]":"name,bundleId,sku"})
    if "error" in apps: print(apps); sys.exit(1)
    for a in apps["data"]:
        print("app", a["id"], a["attributes"])
        b=get("/v1/builds", **{"filter[app]":a["id"],"sort":"-uploadedDate","limit":"12",
              "fields[builds]":"version,uploadedDate,processingState,expired,preReleaseVersion","include":"preReleaseVersion",
              "fields[preReleaseVersions]":"version,platform"})
        if "error" in b: print(b); continue
        pre={i["id"]:i["attributes"] for i in b.get("included",[])}
        for x in b["data"]:
            at=x["attributes"]; pid=(x.get("relationships",{}).get("preReleaseVersion",{}).get("data") or {}).get("id")
            p=pre.get(pid,{})
            print(f'  {p.get("platform","?"):8} {p.get("version","?")} ({at["version"]})  {at["uploadedDate"][:16]}  {at["processingState"]}  expired={at["expired"]}')
        # What became of the latest uploads. An upload Apple turns away while processing never
        # becomes a build: the reason is here (and in an email), not in xcodebuild's output,
        # which has already said "Upload succeeded".
        u=get(f"/v1/apps/{a['id']}/buildUploads", limit="6")
        if "error" in u: print("  uploads:", u); continue
        print("  latest uploads:")
        for x in u["data"]:
            at=x["attributes"]; state=at.get("state") or {}
            print(f'  {at.get("platform","?"):8} {at.get("cfBundleShortVersionString","?")} ({at.get("cfBundleVersion","?")})  {(at.get("uploadedDate") or at.get("createdDate") or "")[:16]}  {state.get("state")}')
            for kind in ("errors","warnings"):
                for e in state.get(kind,[]):
                    print(f'      {kind[:-1]} {e.get("code")}: {(e.get("description") or "")[:230]}')
