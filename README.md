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
| `POST /api/tasks` | `X-Admin-Pin` | Create task `{ title, emoji, recurring, targetDate?, countdownStart? }` |
| `PATCH /api/tasks/:id` | `X-Admin-Pin` | Edit task (same fields as create) |
| `DELETE /api/tasks/:id` | `X-Admin-Pin` | Delete task |
| `POST /api/tasks/:id/toggle` | — | Mark done / not done; `{ minutes }` = time spent, stored on the day's completion |
| `POST /api/verify` | — | Check admin PIN |
| `GET /`, `/admin` | — | Parent admin panel |

Countdown fields: `targetDate` (YYYY-MM-DD) sets a future event; `countdownStart`
(default 7) is the number of days remaining at which the countdown becomes active.
`daysLeft` is computed server-side relative to the requested `date`.

Behavior:
- **Rollover** — tasks not done stay in the list the next day.
- **Recurring** — `recurring: true` shows every day; `recurring: false` (one-off) hides the day after it's completed.
- **Any date** — `?date=` returns that day's view: history shows what was done that day (with `minutes`); future shows the plan.
- **Permissions** — admin actions require the admin PIN. The **kid PIN** (`KID_PIN`, default `0626`)
  unlocks a read-only kid view: mark tasks done (with time) only — no add/edit/delete, no admin panels.

Admin panel features:
- **Calendar** — month view with per-day completion dots; click any day to inspect it.
- **Emoji picker** — choose from a curated dropdown instead of typing.
- **Time spent** — when marking a task done, enter the minutes; shown as `⏱ Nm`.
- **Red highlight** — unfinished one-off tasks are shown in red.
- **Two panels** — the **📋 Today** tab is the daily checklist (plus the calendar);
  future-dated tasks live in a separate **⏳ Countdown** tab.
- **Kid mode** — logging in with the kid PIN shows a big, friendly, read-only
  checklist: tap a task, enter minutes, done. "All done! 🎉" when finished.
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
