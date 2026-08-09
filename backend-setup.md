# Kid Reminder — Backend Setup

A tiny, dependency-free Node.js server that stores a daily checklist and serves a
web admin panel. No database to install, no npm packages — only Node's built-in
`node:http` + `node:sqlite`.

## Requirements

- A Mac (or any machine) with **Node.js ≥ 22** (uses the built-in `node:sqlite` module)
- Runs on your LAN so the kid's app and the admin panel can reach it

## Install & run

```bash
cp -r backend/ ~/kidreminder
cd ~/kidreminder

# optional: set a strong admin PIN
export ADMIN_PIN="change-me"
node server.js          # defaults to port 2021
```

The admin panel is served at `http://<server-ip>:2021` — open it from any browser on
the same WiFi and enter the PIN to manage tasks.

### Auto-start on macOS (launchd)

Create `~/Library/LaunchAgents/com.kidreminder.server.plist`:

```xml
<dict>
    <key>Label</key>
    <string>com.kidreminder.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/node</string>
        <string>/path/to/kidreminder/server.js</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ADMIN_PIN</key>
        <string>change-me</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
```

Then:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kidreminder.server.plist
```

## API

Base path `/api`:

| Endpoint | Auth | Description |
|---|---|---|
| `GET /api/tasks?date=YYYY-MM-DD&type=todo\|countdown` | — | Task list for a date (default today). `type=todo` = daily checklist only; `type=countdown` = future-dated events only. |
| `POST /api/tasks` | `X-Admin-Pin` or `X-Kid-Pin` | Create task `{ title, emoji, repeat, targetDate?, countdownEnabled?, countdownStart? }`; owner recorded as `createdBy` |
| `PATCH /api/tasks/:id` | `X-Admin-Pin` | Edit task (admin only) |
| `DELETE /api/tasks/:id` | `X-Admin-Pin` or `X-Kid-Pin` | Delete; admin any task, kid only tasks they created |
| `POST /api/tasks/:id/toggle` | — | Mark done / not done; `{ minutes }` = time spent, stored on the day's completion |
| `POST /api/verify` | — | Check a PIN, returns `{ role: "admin" }` or `{ role: "kid" }` |
| `GET /`, `/admin` | — | Parent admin panel |

Countdown: `targetDate` (YYYY-MM-DD) sets a future event; `countdownStart` (default 7)
is the days-remaining threshold where the countdown becomes active. `daysLeft` is
computed server-side relative to the requested `date`.

## Behavior

- **Repeat** — `daily` shows every day; `once` hides after completion; `weekly`, `biweekly`,
  `monthly` show only on scheduled days (anchored to the task's date or creation date).
- **Rollover** — daily tasks not done stay in the list the next day.
- **Any date** — `?date=` returns that day's view: history shows what was done that day (with `minutes`); future shows the plan.
- **Permissions** — admin and kid share the same interface. The only difference: the kid PIN
  (`KID_PIN`) can edit or delete only tasks it created (admin can edit/delete everything).
  Parent tasks are read-only for the kid (server returns 403 on edit/delete).
- **LAN only** — bind to your private network; don't expose it to the internet (no TLS).

The admin panel has two tabs: **📋 Today** (the daily checklist + month calendar) and
**⏳ Countdown** (future-dated events with `⏳ Nd` countdowns, `📅 Today!`, `⏰ Nd ago`).
Also includes an **emoji picker** dropdown, **time-spent** entry when checking off, and a
**red highlight** on unfinished one-off tasks.

## Env vars

- `PORT` — listen port (default `2021`)
- `ADMIN_PIN` — PIN for parent actions (default `1234` — **change it**)
- `KID_PIN` — PIN that unlocks the read-only kid view (default `4321` — **change it**)
- `DB_PATH` — SQLite file location (default `kidreminder.db` next to the script)
