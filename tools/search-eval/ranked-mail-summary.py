"""Summarize paired snapshot and ranking-only runs. Inputs contain numeric ranks and clocks."""

import argparse
import json
import math
import statistics
from pathlib import Path


def latency(values):
    samples = sorted(values)

    def q(p):
        return round(samples[math.ceil(p * len(samples)) - 1], 3)

    return {
        "samples": len(samples),
        "p50": round(statistics.median(samples), 3),
        "p95": q(0.95),
        "p99": q(0.99),
        "max": q(1),
        "over100": sum(t > 100 for t in samples),
    }


def summarize(run, reference):
    rows = run["samples"]
    groups = {}
    for family in sorted({s["family"] for s in rows}):
        subset = [s for s in rows if s["family"] == family]
        group = groups[family] = {}
        for method, limit, samples in [
            (
                "prototype",
                50,
                [v for v in reference["samples"] if v["family"] == family],
            ),
            *(
                (m, k, [v for v in subset if v["method"] == m and v["limit"] == k])
                for m in ["chronological", "ranked"]
                for k in [5, 50]
            ),
        ]:
            by_topic = {}
            repeated = {}
            for sample in samples:
                topic = sample["topic"]
                rank = sample["rank"]
                repeated.setdefault(topic, set()).add(rank)
                if sample.get("trial", 0) == 0:
                    by_topic[topic] = rank
            ranks = list(by_topic.values())
            cases = [s for s in samples if s.get("trial", 0) == 0]
            group[f"{method}-{limit}"] = {
                "tasks": len(cases),
                "unstableRanks": sum(len(v) > 1 for v in repeated.values()),
                "unstableTop5": sum(
                    len({0 < rank <= 5 for rank in v}) > 1 for v in repeated.values()
                ),
                "first": sum(r == 1 for r in ranks),
                "top5": sum(0 < r <= 5 for r in ranks),
                "top50": sum(0 < r <= 50 for r in ranks),
                "exactFilenameFirst": sum(
                    s.get("exactFilenameFirst") is True for s in cases
                )
                if family == "complete-filename"
                else None,
                "lookupMS": latency([s["ms"] for s in samples]),
            }
        rank5 = {
            v["topic"]: v["rank"]
            for v in subset
            if v["method"] == "ranked" and v["limit"] == 5 and v["trial"] == 0
        }
        for name, items in [
            ("prototype", reference["samples"]),
            ("chronological", subset),
        ]:
            items = [
                s
                for s in items
                if s["family"] == family
                and s.get("method", "chronological") == "chronological"
                and s.get("limit", 5) == 5
                and s.get("trial", 0) == 0
            ]
            assert len(items) == len(rank5)
            group["pairedAgainst" + name.title()] = {
                "gained": sum(
                    0 < rank5[s["topic"]] <= 5 and not 0 < s["rank"] <= 5 for s in items
                ),
                "lost": sum(
                    not 0 < rank5[s["topic"]] <= 5 and 0 < s["rank"] <= 5 for s in items
                ),
            }
    return {
        "synchronizeSeconds": round(run["buildSeconds"], 3),
        "allTopicsLatencyMS": {
            f"{method}-{limit}": latency(
                [s["ms"] for s in rows if s["method"] == method and s["limit"] == limit]
            )
            for method in ("chronological", "ranked")
            for limit in (5, 50)
        },
        "families": groups,
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for name in ["beta", "beta-reference", "public", "public-reference", "out"]:
        p.add_argument("--" + name, type=Path, required=True)
    a = p.parse_args()
    report = {
        name: summarize(json.loads(path.read_text()), json.loads(ref.read_text()))
        for name, path, ref in [
            ("beta", a.beta, a.beta_reference),
            ("public", a.public, a.public_reference),
        ]
    }
    a.out.write_text(json.dumps(report, indent=2) + "\n")
