#!/usr/bin/env python3
"""Import events from the macOS Calendar app into the kid-reminder server.

Reads a calendar (e.g. the kid's) via AppleScript, then creates a task for
each event: repeat=once, target date = event day, a 7-day countdown on
exams/deadlines, and an auto-picked emoji.

Usage:
    python3 import_calendar.py --url http://<server>:2021 --pin <ADMIN_PIN> \
        [--calendar <kid-name>] [--days 90] [--dry-run]
"""
import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

# Titles containing these get a countdown (exams / assignment deadlines).
COUNTDOWN = ("exam", "test", "eoy", "eoa", "deadline", "composition", "writing",
             "oral", "posting", "assignment", "performance task", "tasmo", "cep",
             "common test", "考试", "写作")


def pick_emoji(title: str) -> str:
    t = title.lower()
    if "math" in t:
        return "➗"
    if "scien" in t:
        return "🔬"
    if "english" in t:
        return "📝"
    if "华" in t or "chinese" in t:
        return "📖"
    if "cep" in t:
        return "🧑‍🏫"
    if "cca" in t:
        return "🎨"
    if "holiday" in t:
        return "🏖️"
    if "hbl" in t:
        return "🏠"
    if "early" in t:
        return "🕐"
    if "tasmo" in t:
        return "🧮"
    return "📅"


def is_countdown(title: str) -> bool:
    t = title.lower()
    return any(k in t for k in COUNTDOWN)


def fetch_events(calendar_name: str, days: int):
    script = f'''
    tell application "Calendar"
      set out to ""
      set nowD to current date
      set endD to nowD + ({days} * days)
      repeat with cal in calendars
        if name of cal is "{calendar_name}" then
          set evs to (every event of cal whose start date ≥ nowD and start date ≤ endD)
          repeat with e in evs
            set sd to start date of e
            set yy to year of sd
            set mm to month of sd as integer
            set dd to day of sd
            set dat to (yy as text) & "-" & (mm as text) & "-" & (dd as text)
            set out to out & summary of e & "\\t" & dat & linefeed
          end repeat
        end if
      end repeat
      return out
    end tell
    '''
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit("osascript failed: " + res.stderr)

    events = []
    for line in res.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            # zero-pad the date to YYYY-MM-DD
            yy, mm, dd = parts[1].split("-")
            date = f"{yy}-{int(mm):02d}-{int(dd):02d}"
            events.append((parts[0], date))
    return events


def create_task(url: str, pin: str, title: str, date: str, countdown: bool, emoji: str) -> int:
    payload = {
        "title": title,
        "emoji": emoji,
        "repeat": "once",
        "targetDate": date,
        "countdownEnabled": countdown,
        "countdownStart": 7,
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url.rstrip("/") + "/api/tasks", data=data, method="POST",
        headers={"Content-Type": "application/json", "X-Admin-Pin": pin})
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", required=True, help="server base URL, e.g. http://<mac-mini-ip>:2021")
    ap.add_argument("--pin", required=True, help="admin PIN")
    ap.add_argument("--calendar", default="<kid-name>", help="Calendar app calendar name")
    ap.add_argument("--days", type=int, default=90)
    ap.add_argument("--dry-run", action="store_true", help="list events without creating tasks")
    args = ap.parse_args()

    events = fetch_events(args.calendar, args.days)
    print(f"Found {len(events)} events in calendar '{args.calendar}' (next {args.days} days)")

    ok = 0
    for title, date in events:
        cd = is_countdown(title)
        emoji = pick_emoji(title)
        mark = "⏳" if cd else "· "
        if args.dry_run:
            print(f"  {mark} {title}  [{date}]  {emoji}")
            continue
        code = create_task(args.url, args.pin, title, date, cd, emoji)
        good = code in (200, 201)
        print(f"  {'OK ' if good else 'ERR'}({code}) {mark} {title}  [{date}]")
        ok += 1 if good else 0

    print(f"\nImported {ok}/{len(events)}" if not args.dry_run else f"Would import {len(events)}")


if __name__ == "__main__":
    main()
