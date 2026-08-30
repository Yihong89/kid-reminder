# Kid Reminder

A simple daily checklist app for kids. The parent manages tasks from a web panel;
the kid sees the checklist and marks tasks done from a native macOS app.

**Language: English | [中文](README.zh-CN.md)**

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
- **Permissions** — the **admin PIN** unlocks full control; a separate **kid PIN** (`KID_PIN`)
  unlocks the same interface, but the kid can only **edit or delete tasks they created**.
  Parent-created tasks are locked for the kid (no edit/delete buttons, and the server rejects
  them with 403). Both roles can add tasks and mark tasks done.
- **Parent-only tasks** 🔒 — when adding/editing a task, the parent can tick **🔒 parent only**.
  Those tasks are **hidden from the kid entirely** (the server filters them out of every list,
  and the kid gets a 403 on toggle/edit/delete attempts). The parent sees a 🔒 badge and keeps
  full access — toggle, edit, delete — on both parent-only and kid-created tasks.
- **Pokémon collection** ⚡ — when the kid finishes **all** of today's tasks, the parent can
  award a **⭐ stamp** (gold markers on the calendar). Every time the kid checks off a task, a
  cheerful **chime** plays 🎵. On the **⚡ Pokémon** panel, the kid can **spend a stamp to randomly
  unlock a Pokémon** — **Kanto (151)** first, and once it's fully caught, **Johto (100)** unlocks
  automatically as a second generation. Locked slots show a **?**. Each unlock plays a **fanfare**
  and reveals the Pokémon; clicking an unlocked one pops up a **bigger sprite with details** (name,
  types). Sprites + sounds are served from the backend (`/sprites/`, `/sounds/`) —
  non-commercial, private family use of the public PokéAPI sprite art.

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
- **Navigation** — tabs live in a left sidebar on wide screens; on narrow ones (phones)
  they collapse to a wrapped row above the content instead of squeezing into one line.

## Chinese dictation (听写)

A vocabulary word bank (character, compound word, pinyin, example sentence — tagged
识读/识写 and by grade level) drives adaptive listening-test sessions:

- **Weakest-first** — each session pulls 10 words from the characters the kid has
  gotten wrong most often (lowest `correct_count`), shuffled.
- **Audio only, no text** — the kid hears the word + sentence read aloud (TTS, see
  below) and writes it down; nothing is shown on screen during the test.
- **Parent grading** — once the kid finishes, the session sits as *pending grading*
  until the parent marks each word ✓/✗ on the web admin, which updates that word's
  weak/strong count for future sessions.
- **Web admin** — `📚 生词库` tab (full word-bank CRUD) and `📝 听写记录` tab (session
  history: graded / pending / abandoned, with a delete button for cleanup).

## English wrong-answer practice (英语错题练习)

A question bank (`english_questions`) built from the kid's own real mistakes —
fill-in-the-blank/spelling, multiple choice, and sentence-transformation questions,
each carrying the correct answer and a short explanation.

- **Self-graded** — typed/tapped answers are checked automatically against the
  correct answer (supports multiple accepted alternatives); no parent step needed.
  Uses the same weakest-first adaptive selection as dictation.
- **Spelling audio** — fill-blank questions flagged as spelling-worthy get a 🔊
  button that reads the completed sentence aloud.
- **Self-override** — for sentence-transformation items where the auto-grader is too
  strict, the kid can flip the verdict once after seeing the correct answer.
- **Web admin** — `📖 英语错题` tab (bank CRUD) and `📋 英语练习记录` tab (read-only
  session history, since grading is automatic).
- **macOS app** — take a practice set, or log a brand-new mistake straight from the
  app via an **➕ add a mistake** form (writes into the same shared bank the web
  admin manages).
- **Kept in sync automatically** — the kid keeps a running mistake log in a private
  GitHub repo; a weekly job on the Mac Mini pulls it and imports any new entries
  (idempotent, so re-runs are harmless). See
  [`tools/english-wrong-answers/README.md`](tools/english-wrong-answers/README.md).

### Text-to-speech

Dictation and spelling audio are synthesized by a private neural TTS service
(Qwen3-TTS) running alongside the backend, cached to disk per word/question so
each one is only generated once. If that service is busy or unavailable, the
backend automatically falls back to macOS's built-in `say` voices — lower
quality, but instant and always available, so the 🔊 button never just goes dead.

## macOS app

Native SwiftUI app (`macos-app/`). **Today** checklist, **Calendar** (month view
with completion dots + pink countdown-event markers; click any day to inspect
its tasks), **Countdown** panel, **听写** (dictation) and **英语错题** (English
practice) tabs, and a **Settings** view where the server IP, port, and PIN are
configured — changes apply immediately (no restart needed). The build produces a
signed `.app` with a custom icon (from `Resources/AppIcon.svg`).

### Download the app

Grab the latest release from the **Releases** page:
<https://github.com/Yihong89/kid-reminder/releases>

`KidReminder.zip` is a **universal build** (Apple Silicon + Intel). Unzip, move
`KidReminder.app` to Applications, and open **Settings** to enter the server IP,
port, and PIN.

Because the app is **ad-hoc signed** (not notarized), macOS Gatekeeper blocks the
first launch. Allow it once with any of these:

- **Right-click → Open** on `KidReminder.app`, then click **Open**
- Or: System Settings → Privacy & Security → scroll down → click **Open Anyway** next to Kid Reminder
- Or in Terminal: `xattr -d com.apple.quarantine /path/to/KidReminder.app`

**Updates are automatic:** the app checks GitHub for a newer release on launch;
in **Settings → Updates** a **Download & Update** button fetches and installs the
new version automatically (no manual download).

### Build from source (no Xcode needed, just Command Line Tools + Swift)

```bash
cd macos-app
./build.sh        # produces build/KidReminder.app
```

Copy `KidReminder.app` to the MacBook, **right-click → Open** on first launch.
On first run, open **Settings** and enter the server IP, port, and PIN. The kid
PIN unlocks the checklist (own tasks only); the admin PIN unlocks full control.
The app reads the connection settings on every request, so edits apply instantly.

## Deployment notes

- Server auto-starts via launchd (`com.kidreminder.server`).
- LAN-only; set a DHCP reservation for the Mac Mini so its IP stays stable.
- Full setup guide: [backend-setup.md](backend-setup.md)

## Roadmap (planned)

Ideas we want to build next:

1. **Multi-kid support** 👨‍👧‍👦
   - One parent account can link to **many kid accounts**.
   - The parent manages **each kid's tasks separately** and awards stamps to each kid individually.
