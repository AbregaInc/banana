"""Deterministic target-first probes shared by the private Mail replays."""

import datetime
import random
import re

families = ["sender", "subject", "sender-and-topic", "snippet", "refinement"]
stop = {
    "re",
    "fw",
    "fwd",
    "the",
    "that",
    "this",
    "from",
    "with",
    "your",
    "and",
    "for",
    "about",
    "some",
    "our",
    "you",
    "have",
    "was",
    "are",
    "has",
    "of",
    "an",
    "a",
    "to",
}


def words(text):
    return list(
        dict.fromkeys(
            w for w in re.findall(r"[^\W_]+", (text or "").lower()) if len(w) >= 3 and w not in stop
        )
    )


def sample_tasks(db, as_of_date, seed=73123):
    # Sample threads independently of retrieval results; each thread contributes at most one
    # task family. A refined query has a paired first attempt against the very same target.
    as_of = int(
        datetime.datetime.combine(
            as_of_date + datetime.timedelta(days=1), datetime.time(), tzinfo=datetime.UTC
        ).timestamp()
        * 1000
    )
    day = 86_400_000
    rng = random.Random(seed)
    result = []
    for band, lo, hi in [
        ("last30d", as_of - 30 * day, as_of),
        ("31to180d", as_of - 180 * day, as_of - 30 * day),
        ("older", 1, as_of - 180 * day),
    ]:
        ids = [
            r[0]
            for r in db.execute(
                "SELECT thread_pk FROM thread WHERE last_date>=? AND last_date<? ORDER BY thread_pk", (lo, hi)
            )
        ]
        rng.shuffle(ids)
        slots = {family: 0 for family in families}
        for pk in ids:
            record = db.execute(
                "SELECT from_name,subject,snippet FROM message WHERE thread_pk=? AND fetch_state>0 "
                "ORDER BY internal_date DESC,msg_pk DESC LIMIT 1",
                (pk,),
            ).fetchone()
            if not record:
                continue
            names, subject, snippet = map(words, record)
            family = min(slots, key=slots.get)
            if family in ("sender", "sender-and-topic") and not names:
                continue
            if family in ("subject", "refinement") and len(subject) < 2:
                continue
            if family == "sender-and-topic" and not subject:
                continue
            if family == "snippet" and len(snippet) < 2:
                continue
            slots[family] += 1
            case = f"{band}-{family}-{slots[family]}"
            if family == "sender":
                attempts = [names[-1]]
            elif family == "subject":
                attempts = [" ".join(rng.sample(subject, 2))]
            elif family == "snippet":
                attempts = [" ".join(rng.sample(snippet, 2))]
            elif family == "sender-and-topic":
                attempts = [names[-1] + " " + rng.choice(subject)]
            else:
                first, added = rng.sample(subject, 2)
                attempts = [first, first + " " + added]
            for step, attempt in enumerate(attempts):
                result.append(
                    {
                        "id": case,
                        "family": family,
                        "age": band,
                        "step": step + 1,
                        "query": attempt,
                        "pk": pk,
                        "targetPresent": True,
                        "baseMS": [],
                        "candidateMS": [],
                    }
                )
            if min(slots.values()) >= 8:
                break
        if min(slots.values()) < 8:
            raise RuntimeError("Insufficient eligible targets for " + band)
    return result
