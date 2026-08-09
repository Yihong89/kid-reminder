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
| `GET /api/tasks?date=YYYY-MM-DD` | — | Task list for a date (default today) `{ today, date, tasks: [{id,title,emoji,recurring,done,minutes}] }` |
| `POST /api/tasks` | `X-Admin-Pin` | Create task `{ title, emoji, recurring }` |
| `PATCH /api/tasks/:id` | `X-Admin-Pin` | Edit task |
| `DELETE /api/tasks/:id` | `X-Admin-Pin` | Delete task |
| `POST /api/tasks/:id/toggle` | — | Mark done / not done; `{ minutes }` = time spent, stored on the day's completion |
| `POST /api/verify` | — | Check admin PIN |
| `GET /`, `/admin` | — | Parent admin panel |

## Behavior

- **Rollover** — tasks not done stay in the list the next day.
- **Recurring** — `recurring: true` shows every day; `recurring: false` (one-off) hides the day after it's completed.
- **Any date** — `?date=` returns that day's view: history shows what was done that day (with `minutes`); future shows the plan.
- **Permissions** — parent actions require the admin PIN; the kid's app has no edit/delete controls.
- **LAN only** — bind to your private network; don't expose it to the internet (no TLS).

The admin panel includes a month **calendar** (click any day), an **emoji picker** dropdown,
**time-spent** entry when checking off, and a **red highlight** on unfinished one-off tasks.

## Env vars

- `PORT` — listen port (default `2021`)
- `ADMIN_PIN` — PIN for parent actions (default `1234` — **change it**)
- `DB_PATH` — SQLite file location (default `kidreminder.db` next to the script)
