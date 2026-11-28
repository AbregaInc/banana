#!/usr/bin/env python3
"""Score executable tool contracts and keep semantic-review rows visible."""
import argparse
from collections import Counter, defaultdict
from datetime import date, timedelta
import json
from pathlib import Path
import re

from jsonschema import Draft7Validator

LIMIT = re.compile(r"can[’']t|cannot|unable|no access|do(?:es)?n[’']t have access|do not have access|"
                   r"not (?:available|supported|able)|only (?:show|read|prepare)", re.I)
CLAIM = re.compile(r"\bI(?: have|[’']ve| just)? (?:successfully )?(?:saved|created|updated|deleted|"
                   r"sent|scheduled|archived|forwarded|cancelled|canceled|booked)\b", re.I)
QUESTION = re.compile(r"\?|\b(?:please tell me|please specify|need to know)\b", re.I)
QUOTED = re.compile(r'"([^"]+)"')
ISO = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
TIME = re.compile(r"\b([0-2]\d:[0-5]\d)\b")


def normalized(value):
    return " ".join(str(value or "").casefold().strip(" .?!").split())


def day_key(value, clock):
    today = date.fromisoformat(clock["date"])
    days = {"today": today, "tomorrow": today + timedelta(days=1),
            "yesterday": today - timedelta(days=1)}
    return str(days.get(value, value or today))


def draft_score(c, result):
    text = "\n".join(p.get("text", "") for p in result if p.get("type") == "text")
    if any(p.get("type") == "toolCall" for p in result) or not text.strip():
        return "fail", "draft_missing_or_action"
    if re.search(r"(?:^|\n)\s*(?:subject|from|to|cc|bcc):|sent from banana|blue anchovy|\[your name\]", text, re.I):
        return "fail", "draft_header_signature_or_quoted_instruction"
    if re.search(r"^(?:here(?:'s| is) (?:a|your|the)|sure[,!:]|certainly[,!:])", text.strip(), re.I):
        return "fail", "draft_meta_preamble"
    prompt = c["prompt"]
    for required in re.findall(r"\$\d+|#[A-Z]-\d+|\bRoom 3\b", prompt):
        if required.casefold() not in text.casefold():
            return "fail", "draft_missing_explicit_fact"
    if c["family"] == "signature-boundary" and re.search(r"\b(?:best regards|kind regards|sincerely)\b", text, re.I):
        return "fail", "draft_signoff"
    return "review", "draft_contract_pass_semantic_review"


# Reviewed search contracts list all and only the optional filters the user supplied.
# A false unread flag filters for read mail in the native store.
MAIL_SEARCH_CONTRACTS = {
    "mail-001": ({"venue", "deposit"}, {"sender": "noor"}),
    "mail-008": ({"invoice"}, {}),
}


def matches_mail_search(arguments, query_words, filters):
    query = set(re.findall(r"\w+", normalized(arguments.get("query"))))
    supplied = {key: normalized(value) if isinstance(value, str) else value
                for key, value in arguments.items() if key != "query"}
    return query == query_words and supplied == filters


def classify(c, row, schemas, clock):
    if "error" in row:
        return "fail", "inference_error"
    parts = row.get("result", {}).get("content", [])
    if c["surface"] == "compose":
        return draft_score(c, parts)
    text = "\n".join(p.get("text", "") for p in parts if p.get("type") == "text")
    calls = [p for p in parts if p.get("type") == "toolCall"]
    wanted, prompt = c["expected"], c["prompt"]
    if CLAIM.search(text):
        return "fail", "unverified_effect"
    if wanted == "capability_gap":
        case_id = c["id"]
        calendar_expectations = {
            "calendar-041": {"period": "thisWeek", "durationMinutes": 30, "limit": 3},
            "calendar-043": {"date": "thursday", "limit": 1, "longestFirst": True},
            "calendar-044": {"period": "next7days", "durationMinutes": 120, "limit": 1, "weekdaysOnly": True},
        }
        if case_id in calendar_expectations and len(calls) == 1 and calls[0]["name"] == "find_free_time":
            arguments = calls[0]["arguments"]
            if Draft7Validator(schemas["find_free_time"]).is_valid(arguments) and all(
                arguments.get(key) == value for key, value in calendar_expectations[case_id].items()
            ):
                return "pass", "new_availability_contract_pass"
            return "fail", "new_capability_arguments_wrong"
        fixture_goal = {
            "mail-011": ("read_mail_inbox", "Proof approval", "Tuesday"),
            "mail-016": ("read_mail_thread", "300", "Tuesday"),
            "mail-017": ("read_mail_thread", "Friday", "waive"),
        }.get(case_id)
        fixture_action = {
            "mail-041": ("prepare_event_from_email", {"sourceStart": "2026-11-25T12:00:00-05:00", "sourceEnd": "2026-11-25T15:00:00-08:00"}),
            "mail-042": ("check_calendar_interval", {"start": "2026-11-25T15:00:00-05:00", "end": "2026-11-25T15:45:00-05:00"}),
            "mail-044": ("create_note", {}),
        }.get(case_id)
        continuation = row.get("continuation", {}).get("content", [])
        if len(calls) == 1 and calls[0]["name"] in {"read_mail_thread", "read_mail_inbox"}:
            tool = calls[0]["name"]
            if not Draft7Validator(schemas[tool]).is_valid(calls[0]["arguments"]):
                return "fail", "invalid_mail_read"
            if (fixture_goal or fixture_action) and row.get("fixtureMatched") is False:
                return "fail", "fixture_search_did_not_match"
            if fixture_goal and continuation:
                answer = " ".join(p.get("text", "") for p in continuation if p.get("type") == "text")
                correct = tool == fixture_goal[0] and all(term.casefold() in answer.casefold() for term in fixture_goal[1:])
                if case_id == "mail-011":
                    correct = correct and answer.startswith("Needs attention") and any(
                        "fyi" in p.get("text", "").casefold() and "monthly newsletter" in p.get("text", "").casefold()
                        for p in continuation[1:])
                return ("review", "fixture_contains_expected_facts") if correct else ("fail", "fixture_missing_expected_facts")
            if fixture_action and continuation:
                action, expectations = fixture_action
                proposals = [p for p in continuation if p.get("type") == "toolCall"]
                if len(proposals) != 1 or proposals[0]["name"] != action:
                    return "fail", "incorrect_cross_module_continuation"
                arguments = proposals[0]["arguments"]
                if not Draft7Validator(schemas[action]).is_valid(arguments) or any(
                    arguments.get(key) != value for key, value in expectations.items()
                ):
                    return "fail", "incorrect_cross_module_arguments"
                if action == "create_note" and not all(term in arguments["text"] for term in ("2026-12-03", "Venue booking", "Noor")):
                    return "fail", "note_missing_source_evidence"
                return "pass", "cross_module_fixture_contract_pass"
            return "review", "mail_selection_needs_native_evidence"
        if case_id in {"mail-001", "mail-008", "calendar-042"} and len(calls) == 1:
            tool = "find_free_time" if c["domain"] == "calendar" else "search_mail"
            args = calls[0]["arguments"]
            if calls[0]["name"] == tool and tool in schemas and Draft7Validator(schemas[tool]).is_valid(args):
                expected = {
                    **{key: matches_mail_search(args, *contract) for key, contract in MAIL_SEARCH_CONTRACTS.items()},
                    "calendar-042": day_key(args.get("date"), clock) == day_key("tomorrow", clock)
                        and args.get("after") == "13:00" and args.get("before", "17:00") == "17:00"
                        and args.get("durationMinutes") == 60,
                }[case_id]
                if expected:
                    return "pass", "new_capability_contract_pass"
                return "fail", "new_capability_arguments_wrong"
        if calls:
            return "fail", "substitute_tool_" + calls[0]["name"]
        if not LIMIT.search(text):
            return "fail", "missing_limit"
        if c["domain"] == "mail" and not re.search(r"mail|inbox|message|draft|sender", text, re.I):
            return "fail", "mail_limit_without_mail"
        return "gap", "honest_capability_limit"
    if wanted in {"answer", "clarify", "clarify_time"}:
        if calls:
            return "fail", "unexpected_tool_" + calls[0]["name"]
        if not text.strip():
            return "fail", "empty"
        if wanted == "answer":
            if LIMIT.search(text) and c["family"] != "conversation":
                return "review", "possible_unnecessary_refusal"
            return "review", "answer_needs_semantic_review"
        if not QUESTION.search(text):
            return "fail", "missing_clarification"
        if wanted == "clarify_time" and not re.search(r"\b(?:time|start|when|AM|PM|morning|evening)\b", text, re.I):
            return "fail", "wrong_clarification"
        return "review", "clarification_needs_semantic_review"
    if wanted.endswith("_page") or wanted.startswith("open_"):
        tool = "open_page"
    elif wanted.startswith("agenda_"):
        tool = "day_plan"
    elif wanted.startswith("event_"):
        tool = "prepare_event"
    elif wanted in {"search", "calendar_search"}:
        tool = "search_app"
    else:
        tool = wanted
    if len(calls) != 1 or calls[0]["name"] != tool:
        return "fail", "expected_" + tool + "_got_" + (calls[0]["name"] if calls else "text")
    args = calls[0]["arguments"]
    if tool not in schemas or not Draft7Validator(schemas[tool]).is_valid(args):
        return "fail", "invalid_schema"
    if tool == "open_page":
        section = wanted.removesuffix("_page") if wanted.endswith("_page") else wanted.removeprefix("open_")
        if args.get("section") != section:
            return "fail", "wrong_section"
    if tool == "day_plan":
        expected = ISO.search(prompt).group() if wanted == "agenda_date" else wanted.removeprefix("agenda_")
        if day_key(args.get("date"), clock) != day_key(expected, clock):
            return "fail", "wrong_agenda_day"
        if expected == "yesterday" or (ISO.fullmatch(expected) and expected < clock["date"]):
            return "gap", "native_agenda_rejects_past_day"
        if re.search(r"rest of today|tomorrow morning", prompt, re.I):
            return "gap", "day_agenda_has_no_time_window_filter"
    if tool == "prepare_event":
        title = QUOTED.search(prompt)
        if title and normalized(title[1]) != normalized(args.get("title")):
            return "fail", "wrong_title"
        is_all_day = wanted == "event_all_day"
        if bool(args.get("isAllDay")) != is_all_day:
            return "fail", "wrong_all_day"
        expected_day = ISO.search(prompt)
        if expected_day:
            expected_day = expected_day.group()
        elif wanted != "event_time":
            expected_day = "today" if wanted == "event_today" else "tomorrow"
        if expected_day and day_key(args.get("day"), clock) != day_key(expected_day, clock):
            return "fail", "wrong_event_day"
        if wanted == "event_time" and "day" in args:
            return "fail", "invented_day"
        expected_time = TIME.search(prompt)
        spoken = ("11:15", "12:00", "19:00", "08:30", "14:00")
        if c["family"] == "event-colloquial":
            expected_time = spoken[(int(c["id"].split("-")[-1]) - 1) % 5]
        elif expected_time:
            expected_time = expected_time.group()
        if expected_time and args.get("time") != expected_time:
            return "fail", "wrong_event_time"
        duration = re.search(r"\b(\d+) minutes\b", prompt)
        if duration and args.get("durationMinutes", 60) != int(duration[1]):
            return "fail", "wrong_duration"
        if duration and int(duration[1]) < 15:
            return "gap", "native_event_minimum_is_15_minutes"
    if tool == "search_app":
        phrase = QUOTED.search(prompt)
        if not phrase or normalized(args.get("query")) != normalized(phrase[1]):
            return "fail", "wrong_literal_query"
        if wanted == "calendar_search" and args.get("section") != "plan":
            return "fail", "search_scope_not_calendar"
    if tool == "create_note":
        if args.get("text") != QUOTED.search(prompt)[1]:
            return "fail", "changed_exact_note"
    if tool in {"prepare_meal", "nutrition_view", "read_nutrients"}:
        return "review", "nutrition_arguments_need_semantic_review"
    return "pass", "tool_contract_pass"


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("run", type=Path)
    cli.add_argument("--out", type=Path)
    args = cli.parse_args()
    evidence = json.loads((args.run / "metadata.json").read_text())
    schemas = {t["name"]: t["parameters"] for t in evidence["tools"]}
    requests = {c["id"]: c for c in json.loads((args.run / "cases.json").read_text())}
    backend = evidence.get("backend", "qwen")
    responses = args.run / "responses.jsonl"
    model_rows = rows(responses) if responses.exists() else []
    if len(set(r["id"] for r in model_rows)) != len(model_rows):
        raise ValueError("Duplicate result")
    apple = args.run / "apple-composer.jsonl"
    apple_rows = rows(apple) if apple.exists() else []
    counters = defaultdict(Counter)
    reasons = defaultdict(Counter)
    entries = []
    for source_backend, source in [(backend, model_rows), ("apple", apple_rows)]:
        for row in source:
            case = requests[row["id"]]
            state, reason = classify(case, row, schemas, evidence["clock"])
            label = "/".join((source_backend, case["domain"], case["surface"]))
            counters[label][state] += 1
            reasons[label][reason] += 1
            entries.append({"backend": source_backend, "id": case["id"], "status": state, "reason": reason,
                            "family": case["family"], "expected": case["expected"], "prompt": case["prompt"],
                            "response": row.get("result", {}).get("content", []), "error": row.get("error")})
    if backend == "apple":
        coverage = {"expectedApple": len(evidence["selection"]), "actualApple": len(model_rows),
                    "appleWithResponse": sum(any(step["raw"].get("result") for step in r.get("trace", []))
                                             for r in model_rows),
                    "appleWithProviderError": sum(any(step["raw"].get("error") for step in r.get("trace", []))
                                                  for r in model_rows)}
    elif backend == "local-trial":
        coverage = {"expectedTrial": len(evidence["selection"]), "actualTrial": len(model_rows),
                    "trialConfirmedInference": sum(bool(r.get("trace")) for r in model_rows)}
    else:
        coverage = {"expectedQwen": len(evidence["selection"]), "actualQwen": len(model_rows),
                    "qwenConfirmedInference": sum(bool(r.get("trace")) for r in model_rows),
                    "actualApple": len(apple_rows)}
    result = {**coverage, "counts": counters, "reasons": reasons, "entries": entries}
    if args.out:
        args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "entries"}, indent=2))


if __name__ == "__main__":
    main()
