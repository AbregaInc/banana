#!/usr/bin/env python3
"""Submit the prepared App Store versions for App Review. Dry run unless --apply.

    python3 tools/asc-submit.py 83            what would be submitted, and why not
    python3 tools/asc-submit.py 83 --apply    submit iOS and macOS (or one with --platform)
    python3 tools/asc-submit.py 117 --attach [--apply]   only select build 117 on the drafts

For each platform the version must be editable (new draft or rejected) with the given build selected and
manual release; an existing unsubmitted review submission is reused, a submitted one stops the
script. A rejected submission (UNRESOLVED_ISSUES) is resubmitted, as the web's "Resubmit to App
Review" does: the version's rejected item is marked resolved and the same submission is submitted
again. The dry run says which of the three it would do. Submission is the owner's decision, given in words for this build; nothing here is called
by the upload scripts. Uses the Banana TestFlight API key, as `asc-builds.py` does.
"""
import argparse, importlib.util, json, os, subprocess, sys, urllib.request
from pathlib import Path

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
EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED")


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

    Returns ("submit", version_id, submission_id_or_None), ("resubmit", version_id, submission_id)
    for a rejected submission, or ("stop", reason)."""
    drafts = [v for v in versions if v["attributes"].get("platform") == platform
              and v["attributes"].get("appVersionState") in EDITABLE_STATES]
    if len(drafts) != 1:
        return ("stop", f"{len(drafts)} editable versions for {platform}; expected one")
    v = drafts[0]; at = v["attributes"]
    if at.get("releaseType") != "MANUAL":
        return ("stop", f"{platform} release type is {at.get('releaseType')}, not MANUAL")
    if v.get("build") != build:
        return ("stop", f"{platform} draft has build {v.get('build')} selected, not {build}")
    open_ones = [s for s in submissions if s["attributes"].get("platform") == platform]
    states = [s["attributes"].get("state") for s in open_ones]
    for s in open_ones:
        if s["attributes"].get("state") not in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES"):
            return ("stop", f"{platform} already has a review submission in state {s['attributes'].get('state')}")
    if len(open_ones) > 1:
        return ("stop", f"{platform} has {len(open_ones)} open review submissions ({', '.join(states)}); expected one")
    if open_ones and states[0] == "UNRESOLVED_ISSUES":
        return ("resubmit", v["id"], open_ones[0]["id"])
    return ("submit", v["id"], open_ones[0]["id"] if open_ones else None)


def build_to_attach(platform, builds, version_string):
    """The one processed, unexpired build of that number for the platform and the draft's version
    (a 1.0.4 build can't go on version 1.0), or a reason it can't be."""
    usable = [b for b in builds if b["platform"] == platform and b["state"] == "VALID" and not b["expired"]]
    if len(usable) != 1:
        return ("stop", f"{platform}: {len(usable)} processed builds with that number; expected one")
    if usable[0]["version"] != version_string:
        return ("stop", f"{platform}: the build is version {usable[0]['version']}, the draft is {version_string}")
    return ("attach", usable[0]["id"])


def builds_numbered(app, number):
    r = asc_module().get("/v1/builds", **{"filter[app]": app, "filter[version]": number, "include": "preReleaseVersion",
                "fields[builds]": "version,processingState,expired,preReleaseVersion", "fields[preReleaseVersions]": "platform,version"})
    if "error" in r: raise SystemExit(f"builds: {r}")
    pre = {i["id"]: i["attributes"] for i in r.get("included", [])}
    def of(b): return pre.get((((b.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}).get("id"), {})
    return [{"id": b["id"], "platform": of(b).get("platform"), "version": of(b).get("version"),
             "state": b["attributes"]["processingState"], "expired": b["attributes"]["expired"]} for b in r["data"]]


def attach(app, versions, number, platforms, apply):
    """Select build `number` on each platform's draft. Never submits."""
    builds = builds_numbered(app, number); failed = False
    for platform in platforms:
        drafts = [v for v in versions if v["attributes"]["platform"] == platform]
        if len(drafts) != 1: print(f"{platform}: {len(drafts)} drafts; expected one"); failed = True; continue
        if drafts[0]["build"] == number: print(f"{platform}: build {number} already selected"); continue
        p = build_to_attach(platform, builds, drafts[0]["attributes"]["versionString"])
        if p[0] == "stop": print(p[1]); failed = True; continue
        if not apply: print(f"{platform}: would select build {number} (replacing {drafts[0]['build']}) on draft {drafts[0]['id']}"); continue
        r = send("PATCH", f"/v1/appStoreVersions/{drafts[0]['id']}/relationships/build", {"data": {"type": "builds", "id": p[1]}})
        if "error" in r: print(f"{platform}: select build failed: {r}"); failed = True; continue
        print(f"{platform}: build {number} selected")
    sys.exit(1 if failed else 0)


def versions_in_preparation(app):
    r = asc_module().get(f"/v1/apps/{app}/appStoreVersions", **{"filter[appVersionState]": ",".join(EDITABLE_STATES),
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


def verify_mac_launch(number):
    """Older uploads must meet the launch gate too, before any submission writes."""
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("mac_release_tests", root / "tools/mac-release-tests.py")
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    evidence = Path(os.environ.get("BANANA_MAC_LAUNCH_EVIDENCE", root / "private/releases/mac-launch"))
    gate.verify(root / ".build/mac-appstore" / f"Banana-{number}.xcarchive", evidence, expected_build=number)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build"); ap.add_argument("--apply", action="store_true")
    ap.add_argument("--platform", choices=PLATFORMS, action="append")
    ap.add_argument("--attach", action="store_true", help="only select the build on the drafts; no submission")
    a = ap.parse_args()
    if a.apply and not a.attach and "MAC_OS" in (a.platform or PLATFORMS):
        try:
            verify_mac_launch(a.build)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            raise SystemExit(f"Mac submission blocked by launch gate: {error}")
    apps = asc_module().get("/v1/apps", **{"filter[bundleId]": asc_module().BUNDLE_ID, "fields[apps]": "name"})
    if "error" in apps or not apps["data"]: raise SystemExit(f"apps: {apps}")
    app = apps["data"][0]["id"]
    versions = versions_in_preparation(app); submissions = review_submissions(app)
    for v in versions:
        print(f'draft {v["attributes"]["platform"]:7} {v["attributes"]["versionString"]} build {v["build"]} {v["attributes"]["appVersionState"]} release {v["attributes"]["releaseType"]}')
    for s in submissions:
        print(f'review submission {s["id"]} {s["attributes"]["platform"]} {s["attributes"]["state"]}')
    if a.attach:
        attach(app, versions, a.build, a.platform or PLATFORMS, a.apply)
    failed = False
    for platform in a.platform or PLATFORMS:
        p = plan(platform, versions, submissions, a.build)
        if p[0] == "stop":
            print(f"{platform}: not submitted: {p[1]}"); failed = True; continue
        action, version_id, submission_id = p
        if not a.apply:
            if action == "resubmit":
                print(f"{platform}: would resubmit rejected submission {submission_id}: mark version {version_id}'s rejected item resolved, then submit (build {a.build})"); continue
            print(f"{platform}: would submit version {version_id} (build {a.build})" + (f" through existing submission {submission_id}" if submission_id else "")); continue
        if not submission_id:
            r = send("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": platform},
                                                              "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})
            if "error" in r: print(f"{platform}: create submission failed: {r}"); failed = True; continue
            submission_id = r["data"]["id"]
        items = asc_module().get(f"/v1/reviewSubmissions/{submission_id}/items", **{"fields[reviewSubmissionItems]": "state,appStoreVersion", "include": "appStoreVersion"})
        if "error" in items:
            print(f"{platform}: read submission items failed: {items}"); failed = True; continue
        ours = [i for i in items.get("data", []) if (((i.get("relationships") or {}).get("appStoreVersion") or {}).get("data") or {}).get("id") == version_id]
        has_version = bool(ours)
        if action == "resubmit":
            if len(ours) != 1:
                print(f"{platform}: rejected submission has {len(ours)} matching version items; expected one"); failed = True; continue
            results = [send("PATCH", f"/v1/reviewSubmissionItems/{i['id']}", {"data": {"type": "reviewSubmissionItems", "id": i["id"], "attributes": {"resolved": True}}})
                       for i in ours if i["attributes"].get("state") == "REJECTED"]
            errors = [r for r in results if "error" in r]
            if errors: print(f"{platform}: mark rejected item resolved failed: {errors[0]}"); failed = True; continue
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
