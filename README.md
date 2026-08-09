# Kid Reminder

A simple daily checklist app for kids. The parent manages tasks from a web panel;
the kid sees the checklist and marks tasks done from a native macOS app.

![arch: backend on Mac Mini + web admin + macOS client]

## Architecture

```
┌─────────────────────────── Mac Mini (home, same WiFi) ───────────────────────────┐
│  Node.js backend (port 2021)                                                     │
│   ├── REST API   → GET /api/tasks, POST /api/tasks/:id/toggle, …                │
│   ├── SQLite     → kidreminder.db (tasks + daily completions)                    │
│   └── Admin panel → single HTML page (parent, PIN-locked)                        │
└───────────────────────────────────────────────────────────────────────────────────┘
        ▲ HTTP (LAN)                                      ▲ HTTP (LAN, browser)
        │                                                   │
┌───────┴───────────────────┐            ┌─────────────────┴──────────────┐
│  Kid's macOS app          │            │  Parent's browser/phone       │
│  (SwiftUI, checklist +    │            │  http://<mac-mini-ip>:2021    │
│   morning notification)   │            │  (add / edit / delete tasks)  │
└───────────────────────────┘            └────────────────────────────────┘
```

## Backend (deployed)

Zero-dependency Node.js — uses only built-in `node:http` + `node:sqlite`.

```bash
cd backend
node server.js        # PORT=2021, ADMIN_PIN=1234 (env-overridable)
```

| Endpoint | Auth | Description |
|---|---|---|
| `GET /api/tasks?date=YYYY-MM-DD&type=todo\|countdown` | — | Task list for a date (default today). `type=todo` = daily checklist only; `type=countdown` = future-dated events only. `{ today, date, type, tasks: [{id,title,emoji,recurring,done,minutes,targetDate,countdownStart,daysLeft}] }` |
| `POST /api/tasks` | `X-Admin-Pin` or `X-Kid-Pin` | Create task `{ title, emoji, repeat, targetDate?, countdownEnabled?, countdownStart? }`; owner recorded as `createdBy` |
| `PATCH /api/tasks/:id` | `X-Admin-Pin` | Edit task (admin only) |
| `DELETE /api/tasks/:id` | `X-Admin-Pin` or `X-Kid-Pin` | Delete; admin any task, kid only tasks they created |
| `POST /api/tasks/:id/toggle` | — | Mark done / not done; `{ minutes }` = time spent, stored on the day's completion |
| `POST /api/verify` | — | Check admin PIN |
| `GET /`, `/admin` | — | Parent admin panel |

Repeat values: `daily`, `weekly`, `biweekly`, `monthly`, `once`.

Countdown: `targetDate` (YYYY-MM-DD) is the task's date; `countdownEnabled` turns on
the countdown; `countdownStart` (default 7) is the days-remaining threshold where it
becomes active. `daysLeft` is computed server-side relative to the requested `date`.

Behavior:
- **Repeat** — `daily` shows every day; a dated non-countdown `once` task appears only on
  that date; an undated `once` hides after it's completed; countdown `once` events stay
  visible (so the countdown panel can count down) until done; `weekly`, `biweekly`, and
  `monthly` show only on their scheduled days (anchored to the task's date, or its creation
  date if no date is set).
- **Rollover** — daily tasks not done stay in the list the next day.
- **Any date** — `?date=` returns that day's view: history shows what was done that day (with `minutes`); future shows the plan.
- **Permissions** — the **admin PIN** unlocks full control; the **kid PIN** (`KID_PIN`, default `0626`)
  unlocks the same interface, but the kid can only **edit or delete tasks they created**.
  Parent-created tasks are locked for the kid (no edit/delete buttons, and the server rejects
  them with 403). Both roles can add tasks and mark tasks done.

Admin panel features:
- **Calendar** — month view with per-day completion dots (green all done / amber partial)
  and **pink markers on countdown event days**; click any day to inspect it.
- **Emoji picker** — choose from a curated dropdown instead of typing.
- **Time spent** — when marking a task done, enter the minutes; shown as `⏱ Nm`.
- **Red highlight** — unfinished one-off tasks are shown in red.
- **Two panels** — the **📋 Today** tab is the daily checklist (plus the calendar);
  future-dated tasks live in a separate **⏳ Countdown** tab.
- **Add-task popup** — a **＋** button opens a form dialog: name, emoji, a **repeat**
  dropdown (Daily / Weekly / Bi-weekly / Monthly / Once), a **date** field, and a
  **countdown** checkbox that unlocks the days-before value.
- **Kid mode** — the kid sees the **exact same interface** as the parent (full calendar
  with day navigation, Today/Countdown tabs, add, minutes, countdown). The only difference:
  the kid can edit/delete only tasks they created — parent tasks show no ✏️/🗑 buttons
  (also enforced server-side with a 403).
- **Countdown** — set a target date on a future task (e.g. an exam). Within the
  `countdownStart` window it shows a live `⏳ Nd` countdown, `📅 Today!` on the day,
  and `⏰ Nd ago` once passed. Future events can't be checked off until their day.

## macOS app (planned)

Native SwiftUI app for the kid's MacBook:
- Shows today's checklist from `GET /api/tasks`
- Tap to mark done via `POST /api/tasks/:id/toggle`
- Daily morning notification (local, scheduled on the MacBook)

## Deployment notes

- Server auto-starts via launchd (`com.kidreminder.server`).
- LAN-only; set a DHCP reservation for the Mac Mini so its IP stays stable.
- Full setup guide: [backend-setup.md](backend-setup.md)
