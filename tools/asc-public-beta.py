#!/usr/bin/env python3
"""Put a build in front of the public beta: add it to `Banana Public Beta`, set what testers and
the reviewer read, and submit it for Beta App Review. Dry run unless --apply.

    python3 tools/asc-public-beta.py 54 --what-to-test notes.txt --review-notes review.txt
    python3 tools/asc-public-beta.py 54 --what-to-test notes.txt --review-notes review.txt --apply

Optional: --description file (the beta app description on the TestFlight page) and
--privacy-url URL. iOS and macOS are separate builds with the same number; both are handled, or
one with --platform IOS / MAC_OS.

Adding a build to an outside group is what releases it to strangers once Apple approves it, so
this is a decision, not a step of an upload: the upload scripts never call it. Uses the Banana
TestFlight API key, as `asc-builds.py` does (`~/.config/banana/release.env`).
"""
import argparse, importlib.util, json, os, sys, urllib.request

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("asc_builds", os.path.join(os.path.dirname(os.path.abspath(__file__)), "asc-builds.py"))
asc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(asc)
get = asc.get
GROUP = "Banana Public Beta"


def send(method, path, body):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + asc.token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()[:800]}


def text(path):
    return open(path, encoding="utf-8").read().strip() if path else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("build")
    ap.add_argument("--what-to-test"); ap.add_argument("--review-notes")
    ap.add_argument("--description"); ap.add_argument("--privacy-url")
    ap.add_argument("--platform", choices=["IOS", "MAC_OS"])
    ap.add_argument("--no-submit", action="store_true", help="set the texts and add to the group, but don't submit for review")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    what, notes, description = text(a.what_to_test), text(a.review_notes), text(a.description)
    if what and len(what) > 4000: sys.exit("What to Test is over Apple's 4,000 characters")
    if description and len(description) > 4000: sys.exit("The description is over Apple's 4,000 characters")
    do = a.apply
    say = (lambda s: print(s)) if do else (lambda s: print("would: " + s))
    failed = []

    def check(label, result):
        if isinstance(result, dict) and "error" in result:
            print(f"  FAILED {label}: {result['error']} {result['body'][:400]}"); failed.append(label)
        return result

    apps = get("/v1/apps", **{"filter[bundleId]": asc.BUNDLE_ID, "fields[apps]": "name"})
    if "error" in apps: sys.exit(str(apps))
    app = apps["data"][0]["id"]

    groups = get(f"/v1/apps/{app}/betaGroups", **{"fields[betaGroups]": "name,isInternalGroup,publicLink", "limit": "50"})
    group = next((g for g in groups.get("data", []) if g["attributes"]["name"] == GROUP), None)
    if not group: sys.exit(f"no beta group named {GROUP}")
    print(f"group: {GROUP}  {group['attributes'].get('publicLink')}")

    b = get("/v1/builds", **{"filter[app]": app, "filter[version]": a.build, "limit": "10",
                             "fields[builds]": "version,processingState,expired,preReleaseVersion",
                             "include": "preReleaseVersion", "fields[preReleaseVersions]": "platform,version"})
    if "error" in b: sys.exit(str(b))
    pre = {i["id"]: i["attributes"] for i in b.get("included", [])}
    builds = []
    for x in b["data"]:
        p = pre.get((x["relationships"]["preReleaseVersion"]["data"] or {}).get("id"), {})
        if a.platform and p.get("platform") != a.platform: continue
        builds.append((p.get("platform"), p.get("version"), x))
    if not builds: sys.exit(f"App Store Connect holds no build {a.build}" + (f" for {a.platform}" if a.platform else ""))
    for platform, version, x in builds:
        state = x["attributes"]["processingState"]
        print(f"build: {platform} {version} ({a.build})  {state}")
        if state != "VALID" or x["attributes"]["expired"]:
            sys.exit(f"{platform} {a.build} is {state}: wait until Apple has finished processing it")

    if description or a.privacy_url:
        locs = get(f"/v1/apps/{app}/betaAppLocalizations", **{"fields[betaAppLocalizations]": "locale"})
        loc = next((l for l in locs.get("data", []) if l["attributes"]["locale"] == "en-US"), None)
        attributes = {}
        if description: attributes["description"] = description
        if a.privacy_url: attributes["privacyPolicyUrl"] = a.privacy_url
        say(f"set the tester page's {' and '.join(attributes)} ({len(description or '')} characters of description)")
        if do and loc:
            check("tester page", send("PATCH", f"/v1/betaAppLocalizations/{loc['id']}",
                                      {"data": {"type": "betaAppLocalizations", "id": loc["id"], "attributes": attributes}}))

    if notes:
        say(f"set the notes for the reviewer ({len(notes)} characters)")
        if do:
            check("review notes", send("PATCH", f"/v1/betaAppReviewDetails/{app}",
                                       {"data": {"type": "betaAppReviewDetails", "id": app, "attributes": {"notes": notes}}}))

    for platform, version, x in builds:
        bid = x["id"]
        if what:
            say(f"set What to Test on {platform} {a.build} ({len(what)} characters)")
            if do:
                locs = get(f"/v1/builds/{bid}/betaBuildLocalizations", **{"fields[betaBuildLocalizations]": "locale"})
                loc = next((l for l in locs.get("data", []) if l["attributes"]["locale"] == "en-US"), None)
                if loc:
                    check(f"What to Test {platform}", send("PATCH", f"/v1/betaBuildLocalizations/{loc['id']}",
                          {"data": {"type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": what}}}))
                else:
                    check(f"What to Test {platform}", send("POST", "/v1/betaBuildLocalizations",
                          {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": what},
                                    "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}}))
        say(f"add {platform} {a.build} to {GROUP}")
        if do:
            check(f"add {platform} to the group", send("POST", f"/v1/betaGroups/{group['id']}/relationships/builds",
                                                       {"data": [{"type": "builds", "id": bid}]}))
        if not a.no_submit:
            say(f"submit {platform} {a.build} for Beta App Review")
            if do and not failed:
                check(f"submit {platform}", send("POST", "/v1/betaAppReviewSubmissions",
                      {"data": {"type": "betaAppReviewSubmissions",
                                "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}}))

    if not do:
        print("\nNothing was changed. Run again with --apply to do it.")
    elif failed:
        sys.exit("\nNot everything went through: " + ", ".join(failed))
    else:
        print("\nDone. `python3 tools/asc-builds.py` shows the builds; the review's outcome comes by email.")


if __name__ == "__main__":
    main()
