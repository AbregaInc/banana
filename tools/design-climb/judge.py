#!/usr/bin/env python3 -I
"""Design-climb judges: models from different families review capture runs through Cloudflare AI Gateway.

  judge.py score <run> [--judges opus,sol,argon] [--device phone]   # scorecard + ranked fixes
  judge.py pair <before-run> <after-run> [--judges ...]             # blind A/B per state
  judge.py report <run>                                             # print the saved verdicts
  --brief tools/design-climb/BRIEF-APP.md --area plan               # whole-app (atlas) runs, one area

<run> is a folder under design-climb/runs (or a path). Results go to <run>/judge-*.json.

Auth: the wrangler login (it carries `ai:write`); `wrangler whoami` refreshes it when near expiry.
The gateway (CF_AI_GATEWAY_ID, default "default") holds the provider keys, so no model key is used here.
Pair mode decides the hill climb: a change is kept only when most judges prefer it, with the
picture order randomised so no judge knows which is new.
"""
import base64, concurrent.futures, json, os, pathlib, random, re, subprocess, sys, tempfile, time, urllib.request, urllib.error
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
RUNS = ROOT / "design-climb" / "runs"
ACCOUNT = os.environ.get("CF_ACCOUNT_ID", "de2004a9cc26903d9d986a9db2106c05")
GATEWAY = os.environ.get("CF_AI_GATEWAY_ID", "default")
JUDGES = {
    "opus": "anthropic/claude-opus-5.5",
    "sol": "openai/gpt-6.1-sol",
    "argon": "google/gemini-4-argon",
    "grok": "xai/grok-4.5",
}
CATEGORIES = ["Task flow", "State and feedback", "Hierarchy", "Agent legibility (AX)", "Trust and control",
              "Discoverability", "Copy", "Platform fit", "Consistency (DX)"]


def token():
    cfg = pathlib.Path.home() / "Library/Preferences/.wrangler/config/default.toml"
    def read():
        text = cfg.read_text()
        tok = re.search(r'^oauth_token\s*=\s*"([^"]+)"', text, re.M)
        exp = re.search(r'^expiration_time\s*=\s*"([^"]+)"', text, re.M)
        return (tok.group(1) if tok else ""), (exp.group(1) if exp else "")
    tok, exp = read()
    left = (datetime.fromisoformat(exp.replace("Z", "+00:00")) - datetime.now(timezone.utc)).total_seconds() if exp else 0
    if left < 600:
        subprocess.run(["wrangler", "whoami"], capture_output=True)
        tok, _ = read()
    if not tok:
        sys.exit("no wrangler login: run `wrangler login`")
    return tok


def image_part(path):
    # Judges see the picture at about 2x points (long side 1600 px): small text stays legible,
    # without the downscale blur that once cost a council half a point.
    small = pathlib.Path(tempfile.gettempdir()) / f"design-climb-{os.getpid()}-{path.parent.name}-{path.name}"
    subprocess.run(["sips", "-Z", "1600", str(path), "--out", str(small)], capture_output=True)
    data = base64.b64encode((small if small.exists() else path).read_bytes()).decode()
    small.unlink(missing_ok=True)
    return {"type": "image", "data": data}


def provider_body(model, content, max_tokens):
    """The gateway passes each provider's own request shape through, so build that shape."""
    if model.startswith("anthropic/"):
        parts = [{"type": "text", "text": c["text"]} if c["type"] == "text" else
                 {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": c["data"]}} for c in content]
        return "responses", {"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": parts}]}
    if model.startswith("openai/"):
        parts = [{"type": "input_text", "text": c["text"]} if c["type"] == "text" else
                 {"type": "input_image", "image_url": f"data:image/png;base64,{c['data']}"} for c in content]
        return "responses", {"model": model, "max_output_tokens": max_tokens, "input": [{"role": "user", "content": parts}]}
    parts = [c if c["type"] == "text" else {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{c['data']}"}} for c in content]
    return "chat/completions", {"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": parts}]}


def reply_text(d):
    if "choices" in d:                                    # chat completions
        return d["choices"][0]["message"]["content"]
    if d.get("type") == "message" and "content" in d:     # Anthropic messages
        return "".join(c.get("text", "") for c in d["content"] if c.get("type") == "text")
    if "output" in d:                                     # OpenAI responses
        return "".join(c.get("text", "") for o in d["output"] if o.get("type") == "message" for c in o.get("content", []))
    raise ValueError(str(d)[:400])


def ask(model, content, max_tokens=12000, attempts=3):
    path, body = provider_body(model, content, max_tokens)
    url = f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/ai/v1/{path}"
    last = None
    for attempt in range(attempts):
        req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
            "Authorization": f"Bearer {token()}", "cf-aig-gateway-id": GATEWAY, "content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                return reply_text(json.load(r))
        except urllib.error.HTTPError as e:
            last = f"{e.code} {e.read()[:400]!r}"
        except Exception as e:  # network, timeout, malformed
            last = repr(e)
        time.sleep(4 * (attempt + 1))
    raise RuntimeError(f"{model}: {last}")


def json_from(text):
    m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S) or re.search(r"(\{.*\})", text, re.S)
    return json.loads(m.group(1) if m else text, strict=False)


def ask_json(model, content, raw_path):
    """Ask, keep the raw reply beside the run, and give a malformed reply one repair pass."""
    text = ask(model, content)
    raw_path.write_text(text)
    try:
        return json_from(text)
    except Exception as e:
        fixed = ask(model, [{"type": "text", "text": f"This JSON is malformed ({e}). Return the same content as valid JSON only, "
                             "escaping any double quote inside a string:\n\n" + text}])
        raw_path.with_suffix(".repaired.txt").write_text(fixed)
        return json_from(fixed)


JSON_RULE = "Inside JSON strings, quote UI text with ‘curly single quotes’, never straight double quotes."


def run_dir(name):
    p = pathlib.Path(name)
    return p if p.is_dir() else RUNS / name


def shots(run, device):
    pics = sorted(run.glob(f"{device}-*.png"))
    if AREA:
        pics = [p for p in pics if p.stem[len(device) + 1:].startswith(AREA + "__")]
    return pics


BRIEF = HERE / "BRIEF.md"
AREA = None


def context(run=None):
    """The brief, the owner calls, and what each picture shows: the run's own states.json when it
    has one (an atlas run), else the Pi walk's."""
    own = run / "states.json" if run else None
    states = json.loads((own if own and own.exists() else HERE / "states.json").read_text())["states"]
    return BRIEF.read_text(), (HERE / "OWNER-CALLS.md").read_text(), states


def state_of(path, device):
    return path.stem[len(device) + 1:]


def score(run, judges, device):
    brief, calls, states = context(run)
    pics = shots(run, device)
    if not pics:
        sys.exit(f"no {device} pictures in {run}")
    content = [{"type": "text", "text": f"{brief}\n\n## OWNER-CALLS.md\n\n{calls}\n\n## The screenshots ({device})\n"}]
    for p in pics:
        s = state_of(p, device)
        content += [{"type": "text", "text": f"\n### {s}\n{states.get(s, '')}"}, image_part(p)]
    content.append({"type": "text", "text": """
## Your reply

Reply with one JSON object and nothing else:
{
  "scores": {"<category>": <0-10>, ...every category...},
  "overall": <0-10>,
  "strengths": ["<what already works, one line each>"],
  "fixes": [
    {"priority": "MUST|SHOULD|COULD", "states": ["<state names>"], "lens": "UX|AX|DX",
     "problem": "<what is wrong and why it costs the person or the agent>",
     "fix": "<the concrete change: what to add, remove, merge, move, rename; exact words for copy>"}
  ]
}
Rank fixes by impact, at most 12. Prefer structural fixes (remove a step, merge two controls,
clarify a state) over cosmetic ones. A fix must respect the owner calls.\n""" + JSON_RULE})
    out = {}
    with concurrent.futures.ThreadPoolExecutor(len(judges)) as pool:
        futures = {pool.submit(ask_json, JUDGES[j], content, run / f"raw-score-{device}-{AREA or 'all'}-{j}.txt"): j for j in judges}
        for f in concurrent.futures.as_completed(futures):
            j = futures[f]
            try:
                out[j] = f.result()
                print(f"{j}: overall {out[j].get('overall')}", file=sys.stderr)
            except Exception as e:
                out[j] = {"error": str(e)}
                print(f"{j}: {e}", file=sys.stderr)
    saved = run / f"judge-score-{device}{'-' + AREA if AREA else ''}.json"
    if saved.exists():
        out = {**json.loads(saved.read_text()), **out}
    saved.write_text(json.dumps(out, indent=2))
    report_score(out)
    return out


def pair(before, after, judges, device):
    brief, calls, states = context(after)
    names = sorted({state_of(p, device) for p in shots(before, device)} & {state_of(p, device) for p in shots(after, device)})
    if not names:
        sys.exit("no state pictured in both runs")
    rng = random.Random()
    order = {s: rng.random() < 0.5 for s in names}   # True: A is the after picture
    content = [{"type": "text", "text": f"{brief}\n\n## OWNER-CALLS.md\n\n{calls}\n\n"
                "## Blind comparison\nFor each state you get two versions, A and B, of the same screen in the same state. "
                "They are in random order; do not assume either is newer. Judge which serves the person and the agent better "
                "by the brief's categories, not by surface polish.\n"}]
    for s in names:
        a, b = (after, before) if order[s] else (before, after)
        content += [{"type": "text", "text": f"\n### {s}\n{states.get(s, '')}\nA:"}, image_part(a / f"{device}-{s}.png"),
                    {"type": "text", "text": "B:"}, image_part(b / f"{device}-{s}.png")]
    content.append({"type": "text", "text": """
## Your reply
One JSON object and nothing else:
{"states": {"<state>": {"winner": "A|B|tie", "why": "<one line>"}, ...every state...},
 "overall": {"winner": "A|B|tie", "why": "<two lines>"},
 "regressions": ["<anything that got worse, naming the state>"]}
If A and B look the same for a state, say tie.\n""" + JSON_RULE})
    out = {"order": {s: ("after" if order[s] else "before") + "=A" for s in names}, "judges": {}}
    with concurrent.futures.ThreadPoolExecutor(len(judges)) as pool:
        futures = {pool.submit(ask_json, JUDGES[j], content, after / f"raw-pair-{device}-{AREA or 'all'}-{j}.txt"): j for j in judges}
        for f in concurrent.futures.as_completed(futures):
            j = futures[f]
            try:
                v = f.result()
                def unblind(w, s):
                    if w == "tie":
                        return "tie"
                    if w not in ("A", "B"):
                        raise ValueError(f"Invalid winner for {s}: {w!r}")
                    return "after" if (w == "A") == order[s] else "before"
                per = {s: {"winner": unblind(x.get("winner"), s), "why": x.get("why", "")}
                       for s, x in v.get("states", {}).items() if s in order}
                out["judges"][j] = {"states": per, "regressions": v.get("regressions", []),
                                    "overall_raw": v.get("overall", {})}
            except Exception as e:
                out["judges"][j] = {"error": str(e)}
                print(f"{j}: {e}", file=sys.stderr)
    summarize_pair(out, names, judges)
    (after / f"judge-pair-{device}{'-' + AREA if AREA else ''}-vs-{before.name}.json").write_text(json.dumps(out, indent=2))
    report_pair(out)
    return out


def summarize_pair(out, names, judges):
    """Only complete ballots count; a majority of the requested council must answer."""
    complete = []
    for judge in judges:
        ballot = out["judges"].get(judge, {})
        states = ballot.get("states", {})
        if "error" not in ballot and set(states) == set(names) and all(
                state.get("winner") in ("after", "before", "tie") for state in states.values()):
            complete.append(judge)
    tally = {"after": 0, "before": 0, "tie": 0}
    for judge in complete:
        for state in out["judges"][judge]["states"].values():
            tally[state["winner"]] += 1
    quorum = max(2, len(judges) // 2 + 1)
    out["complete_judges"] = complete
    out["required_judges"] = quorum
    out["valid_comparison"] = len(complete) >= quorum
    out["tally"] = tally
    decided = tally["after"] + tally["before"]
    out["after_win_rate"] = (round(tally["after"] / decided, 3)
                             if out["valid_comparison"] and decided else None)


def report_score(out):
    judges = [j for j in out if "scores" in out[j]]
    print("| Category | " + " | ".join(judges) + " |\n| --- |" + " --- |" * len(judges))
    for c in CATEGORIES + ["overall"]:
        row = [str(out[j]["overall"] if c == "overall" else out[j]["scores"].get(c, "—")) for j in judges]
        print(f"| {c} | " + " | ".join(row) + " |")
    for j in judges:
        print(f"\n## {j}")
        for f in out[j].get("fixes", []):
            print(f"- [{f.get('priority')}/{f.get('lens')}] {', '.join(f.get('states', []))}: {f.get('problem')}\n    → {f.get('fix')}")


def report_pair(out):
    if out.get("valid_comparison") is False:
        print(f"INCOMPLETE: {len(out['complete_judges'])} complete judges; "
              f"{out['required_judges']} required. Do not accept this round.")
    print(json.dumps(out["tally"]), "after win rate:", out["after_win_rate"])
    for j, v in out["judges"].items():
        if "error" in v:
            print(j, v["error"]); continue
        print(f"\n## {j}")
        for s, x in sorted(v["states"].items()):
            print(f"- {s}: {x['winner']} — {x['why']}")
        for r in v.get("regressions", []):
            print(f"  regression: {r}")


def main():
    args = sys.argv[1:]
    def opt(name, default):
        if name in args:
            i = args.index(name); v = args[i + 1]; del args[i:i + 2]; return v
        return default
    global BRIEF, AREA
    judges = list(dict.fromkeys(opt("--judges", "opus,sol,argon").split(",")))
    device = opt("--device", "phone")
    BRIEF = pathlib.Path(opt("--brief", str(BRIEF)))
    AREA = opt("--area", None)
    if not args:
        sys.exit(__doc__)
    cmd = args[0]
    if cmd == "score":
        score(run_dir(args[1]), judges, device)
    elif cmd == "pair":
        result = pair(run_dir(args[1]), run_dir(args[2]), judges, device)
        if not result["valid_comparison"]:
            sys.exit(2)
    elif cmd == "report":
        run = run_dir(args[1])
        for f in sorted(run.glob("judge-*.json")):
            print(f"# {f.name}")
            d = json.loads(f.read_text())
            report_pair(d) if "tally" in d else report_score(d)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
