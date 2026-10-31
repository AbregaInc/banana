#!/usr/bin/env python3
"""Submit the prepared App Store versions for App Review. Dry run unless --apply.

    python3 tools/asc-submit.py 83            what would be submitted, and why not
    python3 tools/asc-submit.py 83 --apply    submit iOS and macOS (or one with --platform)

For each platform the draft must be in PREPARE_FOR_SUBMISSION with the given build selected and
manual release; an existing unsubmitted review submission is reused, a submitted one stops the
script. Submission is the owner's decision, given in words for this build; nothing here is called
by the upload scripts. Uses the Banana TestFlight API key, as `asc-builds.py` does.
"""
import argparse, importlib.util, json, os, sys, urllib.request

sys.dont_write_bytecode = True
_asc = None


def asc_module():
    """asc-builds.py, loaded on first use: it reads the API key when imported, which `plan` never needs."""
    global _asc
    if _asc is None:
        spec = importlib.util.spec_from_file_location("asc_builds", os.path.join(os.path.dirname(os.path.abspath(__file__)), "asc-builds.py"))
        _asc = importlib.util.module_from_spec(spec); spec.loader.exec_module(_asc)
    return _asc


API = "https://api.appstoreconnect.apple.com"
PLATFORMS = ("IOS", "MAC_OS")


def send(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + asc_module().token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()[:800]}


def plan(platform, versions, submissions, build):
    """What to do for one platform, from the drafts and review submissions Apple lists.

    Returns ("submit", version_id, submission_id_or_None) or ("stop", reason)."""
    drafts = [v for v in versions if v["attributes"].get("platform") == platform]
    if len(drafts) != 1:
        return ("stop", f"{len(drafts)} versions in PREPARE_FOR_SUBMISSION for {platform}; expected one")
    v = drafts[0]; at = v["attributes"]
    if at.get("releaseType") != "MANUAL":
        return ("stop", f"{platform} release type is {at.get('releaseType')}, not MANUAL")
    if v.get("build") != build:
        return ("stop", f"{platform} draft has build {v.get('build')} selected, not {build}")
    open_ones = [s for s in submissions if s["attributes"].get("platform") == platform]
    for s in open_ones:
        if s["attributes"].get("state") != "READY_FOR_REVIEW":
            return ("stop", f"{platform} already has a review submission in state {s['attributes'].get('state')}")
    return ("submit", v["id"], open_ones[0]["id"] if open_ones else None)


def versions_in_preparation(app):
    r = asc_module().get(f"/v1/apps/{app}/appStoreVersions", **{"filter[appVersionState]": "PREPARE_FOR_SUBMISSION",
                "fields[appStoreVersions]": "platform,versionString,appVersionState,releaseType,build",
                "include": "build", "fields[builds]": "version"})
    if "error" in r: raise SystemExit(f"appStoreVersions: {r}")
    builds = {i["id"]: i["attributes"]["version"] for i in r.get("included", []) if i["type"] == "builds"}
    out = []
    for v in r["data"]:
        bid = ((v.get("relationships") or {}).get("build") or {}).get("data")
        v["build"] = builds.get(bid["id"]) if bid else None
        out.append(v)
    return out


def review_submissions(app):
    r = asc_module().get(f"/v1/apps/{app}/reviewSubmissions", **{"fields[reviewSubmissions]": "platform,state,submittedDate", "limit": "50"})
    if "error" in r: raise SystemExit(f"reviewSubmissions: {r}")
    return [s for s in r["data"] if s["attributes"].get("state") not in ("COMPLETE", "CANCELING", "COMPLETING")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build"); ap.add_argument("--apply", action="store_true")
    ap.add_argument("--platform", choices=PLATFORMS, action="append")
    a = ap.parse_args()
    apps = asc_module().get("/v1/apps", **{"filter[bundleId]": asc_module().BUNDLE_ID, "fields[apps]": "name"})
    if "error" in apps or not apps["data"]: raise SystemExit(f"apps: {apps}")
    app = apps["data"][0]["id"]
    versions = versions_in_preparation(app); submissions = review_submissions(app)
    for v in versions:
        print(f'draft {v["attributes"]["platform"]:7} {v["attributes"]["versionString"]} build {v["build"]} {v["attributes"]["appVersionState"]} release {v["attributes"]["releaseType"]}')
    for s in submissions:
        print(f'review submission {s["id"]} {s["attributes"]["platform"]} {s["attributes"]["state"]}')
    failed = False
    for platform in a.platform or PLATFORMS:
        p = plan(platform, versions, submissions, a.build)
        if p[0] == "stop":
            print(f"{platform}: not submitted: {p[1]}"); failed = True; continue
        _, version_id, submission_id = p
        if not a.apply:
            print(f"{platform}: would submit version {version_id} (build {a.build})" + (f" through existing submission {submission_id}" if submission_id else "")); continue
        if not submission_id:
            r = send("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": platform},
                                                              "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})
            if "error" in r: print(f"{platform}: create submission failed: {r}"); failed = True; continue
            submission_id = r["data"]["id"]
        items = asc_module().get(f"/v1/reviewSubmissions/{submission_id}/items", **{"fields[reviewSubmissionItems]": "state", "include": "appStoreVersion"})
        has_version = any(((i.get("relationships") or {}).get("appStoreVersion") or {}).get("data", {}).get("id") == version_id for i in items.get("data", []))
        if not has_version:
            r = send("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
            if "error" in r: print(f"{platform}: add version to submission failed: {r}"); failed = True; continue
        r = send("PATCH", f"/v1/reviewSubmissions/{submission_id}", {"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}})
        if "error" in r: print(f"{platform}: submit failed: {r}"); failed = True; continue
        state = asc_module().get(f"/v1/reviewSubmissions/{submission_id}", **{"fields[reviewSubmissions]": "state,submittedDate"})["data"]["attributes"]
        vstate = asc_module().get(f"/v1/appStoreVersions/{version_id}", **{"fields[appStoreVersions]": "appVersionState"})["data"]["attributes"]
        print(f'{platform}: submitted. review submission {submission_id} {state.get("state")} at {state.get("submittedDate")}; version {vstate.get("appVersionState")}')
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
