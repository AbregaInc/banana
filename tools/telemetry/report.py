#!/usr/bin/env python3
"""Banana's usage counts, read from the Banana service's database (Service/, D1 `banana-service`).

    tools/telemetry/report.py [--days 30] [--local] [--with-dev]

Daily active copies (and those with a calendar connected), how far first runs get, who comes back
after 1, 7 and 30 days, what's used and what fails, and signed-in accounts active per day. Reads
through wrangler (logged in already); `--local` reads the copy `wrangler dev` made in Service/.
Developer installs (ours) are left out unless asked (accounts carry no channel, so not there).
"""
import argparse, json, subprocess, sys
from pathlib import Path

SERVICE = Path(__file__).resolve().parents[2] / "Service"


def query(sql, local):
    command = ["wrangler", "d1", "execute", "banana-service", "--json", "--command", sql,
               "--local" if local else "--remote"]
    out = subprocess.run(command, cwd=SERVICE, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(out.stderr.strip() or out.stdout.strip())
    return json.loads(out.stdout)[0]["results"]


def table(title, rows, columns):
    print(f"\n{title}")
    if not rows:
        print("  (nothing yet)")
        return
    widths = [max(len(str(c)), *(len(str(r.get(c, ""))) for r in rows)) for c in columns]
    print("  " + "  ".join(str(c).ljust(w) for c, w in zip(columns, widths)))
    for r in rows:
        print("  " + "  ".join(str(r.get(c, "")).ljust(w) for c, w in zip(columns, widths)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--local", action="store_true")
    ap.add_argument("--with-dev", action="store_true")
    a = ap.parse_args()
    where = f"day >= date('now', '-{int(a.days)} days')" + ("" if a.with_dev else " AND channel != 'dev'")

    table("Daily active copies", query(f"""
        SELECT day, SUM(count) AS active, SUM(CASE WHEN calendar = 1 THEN count ELSE 0 END) AS with_calendar,
               SUM(CASE WHEN platform = 'iphone' THEN count ELSE 0 END) AS iphone,
               SUM(CASE WHEN platform = 'ipad' THEN count ELSE 0 END) AS ipad,
               SUM(CASE WHEN platform = 'mac' THEN count ELSE 0 END) AS mac
        FROM counts WHERE event = 'active' AND {where} GROUP BY day ORDER BY day DESC""", a.local),
        ["day", "active", "with_calendar", "iphone", "ipad", "mac"])

    table("First run: how far it gets", query(f"""
        SELECT name AS step, SUM(CASE WHEN detail = 'shown' THEN count ELSE 0 END) AS shown,
               SUM(CASE WHEN detail = 'continued' THEN count ELSE 0 END) AS continued,
               SUM(CASE WHEN detail = 'skipped' THEN count ELSE 0 END) AS skipped
        FROM counts WHERE event = 'onboarding' AND {where} GROUP BY name
        ORDER BY CASE name WHEN 'welcome' THEN 0 WHEN 'wake' THEN 1 WHEN 'winddown' THEN 2
                 WHEN 'calendar' THEN 3 WHEN 'otherCalendar' THEN 4 ELSE 5 END""", a.local),
        ["step", "shown", "continued", "skipped"])

    # A copy counts as active once a day, with its days since first opened: the copies first opened
    # in a week are its day-0 count, and day 1/7/30 counts over that are who came back.
    table("Coming back, by the week first opened", query(f"""
        SELECT cohort, SUM(CASE WHEN since = 0 THEN count ELSE 0 END) AS new,
               SUM(CASE WHEN since = 1 THEN count ELSE 0 END) AS day1,
               SUM(CASE WHEN since = 7 THEN count ELSE 0 END) AS day7,
               SUM(CASE WHEN since = 30 THEN count ELSE 0 END) AS day30
        FROM counts WHERE event = 'active' {"" if a.with_dev else "AND channel != 'dev'"}
        GROUP BY cohort ORDER BY cohort DESC LIMIT 12""", a.local),
        ["cohort", "new", "day1", "day7", "day30"])

    table("What's used", query(f"""
        SELECT name AS feature, detail, SUM(count) AS times FROM counts
        WHERE event = 'feature' AND {where} GROUP BY name, detail ORDER BY times DESC""", a.local),
        ["feature", "detail", "times"])

    # Each copy reports its setup once a day: a fact's answers as shares of the copies reporting it.
    table("How copies are set up (share of reports)", query(f"""
        SELECT name AS fact, detail AS answer, SUM(count) AS reports,
               ROUND(100.0 * SUM(count) / SUM(SUM(count)) OVER (PARTITION BY name), 1) AS percent
        FROM counts WHERE event = 'setup' AND {where} GROUP BY name, detail ORDER BY name, reports DESC""", a.local),
        ["fact", "answer", "reports", "percent"])

    table("What fails", query(f"""
        SELECT name AS failure, SUM(count) AS times FROM counts
        WHERE event = 'failure' AND {where} GROUP BY name ORDER BY times DESC""", a.local),
        ["failure", "times"])

    # One row per account a day it was active (account_usage), whatever its devices sent.
    table("Signed-in accounts active per day (last 14 days)", query("""
        SELECT day, COUNT(DISTINCT account_id) AS accounts FROM account_usage
        WHERE event = 'active' AND day >= date('now', '-14 days') GROUP BY day ORDER BY day DESC""", a.local),
        ["day", "accounts"])


if __name__ == "__main__":
    main()
