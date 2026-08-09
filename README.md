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
| `GET /api/tasks` | — | Today's task list `{ today, tasks: [{id,title,emoji,recurring,done}] }` |
| `POST /api/tasks` | `X-Admin-Pin` | Create task `{ title, emoji, recurring }` |
| `PATCH /api/tasks/:id` | `X-Admin-Pin` | Edit task |
| `DELETE /api/tasks/:id` | `X-Admin-Pin` | Delete task |
| `POST /api/tasks/:id/toggle` | — | Mark done / not done (used by kid's app) |
| `POST /api/verify` | — | Check admin PIN |
| `GET /` , `/admin` | — | Parent admin panel |

Behavior:
- **Rollover** — tasks not done stay in the list the next day.
- **Recurring** — `recurring: true` shows every day; `recurring: false` (one-off) hides the day after it's completed.
- **Permissions** — parent actions require the admin PIN; the kid's app has no edit/delete controls.

## macOS app (planned)

Native SwiftUI app for the kid's MacBook:
- Shows today's checklist from `GET /api/tasks`
- Tap to mark done via `POST /api/tasks/:id/toggle`
- Daily morning notification (local, scheduled on the MacBook)

## Deployment notes

- Server auto-starts via launchd (`com.kidreminder.server`).
- LAN-only; set a DHCP reservation for the Mac Mini so its IP stays stable.
- Full setup guide: [backend-setup.md](backend-setup.md)
