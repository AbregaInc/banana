"""Equal-weight known-item quality and paired latency at the query level."""

import math
import random
import statistics


def p95(values):
    return sorted(values)[math.ceil(0.95 * len(values)) - 1]


def summarize(tasks):
    def success(k):
        return sum(0 < task["rankAt50"] <= k for task in tasks)

    old = [statistics.median(t["baseMS"]) for t in tasks]
    new = [statistics.median(t["candidateMS"]) for t in tasks]
    paired = [a - b for a, b in zip(old, new)]
    rng = random.Random(32005)
    boot = sorted(statistics.median(rng.choices(paired, k=len(tasks))) for _ in range(2000))
    return dict(
        topics=len(tasks),
        corpusTargets=sum(t["targetPresent"] for t in tasks),
        top1=success(1),
        successAt5=success(5),
        successAt10=success(10),
        successAt50=success(50),
        mrrAt10=statistics.mean(1 / t["rankAt50"] if 0 < t["rankAt50"] <= 10 else 0 for t in tasks),
        baseQueryMedianMS=statistics.median(old),
        candidateQueryMedianMS=statistics.median(new),
        baseQueryP95MS=p95(old),
        candidateQueryP95MS=p95(new),
        baseMaxMS=max(max(t["baseMS"]) for t in tasks),
        candidateMaxMS=max(max(t["candidateMS"]) for t in tasks),
        medianPairedSavingMS=statistics.median(paired),
        bootstrap95SavingMS=[boot[49], boot[1949]],
    )


def lexical_summary(group):
    old_top = [0 < t["rankAt50"] <= 5 for t in group]
    new_top = [0 < t["lexicalRankAt50"] <= 5 for t in group]
    elapsed = [t["lexicalLookupMS"] for t in group]
    ranks = [t["lexicalRankAt50"] for t in group]
    return dict(
        topics=len(group),
        top1=ranks.count(1),
        successAt5=sum(new_top),
        successAt10=sum(0 < r <= 10 for r in ranks),
        successAt50=sum(r > 0 for r in ranks),
        mrrAt10=statistics.mean(1 / r if 0 < r <= 10 else 0 for r in ranks),
        gainedAt5=sum(new and not old for old, new in zip(old_top, new_top)),
        lostAt5=sum(old and not new for old, new in zip(old_top, new_top)),
        lookupMedianMS=statistics.median(elapsed),
        lookupP95MS=p95(elapsed),
    )
