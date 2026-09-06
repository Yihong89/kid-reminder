# Backend Portability: can it run on Windows / Linux?

**Scope.** The `backend/server.js` service is currently deployed on a **home Mac Mini**
(macOS, launchd, Node v24). This report answers whether the same service — unchanged
or with small tweaks — could run on a **Windows** or **Linux** host instead.

**Short answer.** **Yes — with a couple of small, non-core changes.** The service is
not macOS-specific. It is a zero-dependency Node.js app using only built-in modules
(`node:http`, `node:fs`, `node:path`, `node:sqlite`, `node:child_process`), and nearly
all of its logic (tasks, dictation, English wrong-answers, English Paper 2, Science,
mistake bank, audit log, admin panel) is platform-neutral. The main obstacles are one
macOS-only shell command for TTS fallback, the process-supervisor choice, and the
Node version floor.

---

## 1. What is already portable

| Area | Status | Notes |
|---|---|---|
| Runtime modules | ✅ | Only `node:*` built-ins; no `package.json`, no npm deps. |
| Database | ✅ | `node:sqlite` (`DatabaseSync`) — an embedded SQLite, works on all OSes. Not using `libsql`/platform binaries. |
| Paths | ✅ | Every file path uses `path.join(__dirname, ...)`, so OS separators are handled. |
| Directory creation | ✅ | `fs.mkdirSync(dir, { recursive: true })` for audio / image dirs — cross-platform. |
| HTTP server | ✅ | `node:http` — pure Node, no OS dependency. |
| Static file serving | ✅ | `fs.readFileSync` / streaming of sprites, images, audio — platform-neutral. |
| JSON / SQL / migration | ✅ | `CREATE TABLE IF NOT EXISTS` + guarded `ALTER TABLE ... catch {}` — no OS dependency. |
| Env config | ✅ | `PORT`, `ADMIN_PIN`, `KID_PIN`, `DB_PATH`, `TTS_SERVICE_URL`, `SAY_VOICE_*` — read from `process.env`. |

In other words, **the entire API surface, database schema, and admin panel work on
Windows and Linux unmodified.**

---

## 2. macOS-specific pieces

### 2.1 TTS fallback uses the macOS `say` command (the one real blocker)

`server.js` has a hardcoded call to macOS's text-to-speech CLI:

```js
const SAY_VOICE_ZH = process.env.SAY_VOICE_ZH || "Tingting"; // built-in zh_CN voice
const SAY_VOICE_EN = process.env.SAY_VOICE_EN || "Samantha"; // built-in en_US voice

function synthesizeWithSay(text, voice, outFile) {
  execFileSync("say", ["-v", voice, "-o", outFile, "--file-format=WAVE",
                       "--data-format=LEI16@22050", text], { timeout: 15000 });
}
```

`say` exists **only on macOS**. `Windows` and `Linux` do not have it. This is the
**single place** that would throw (`ENOENT: say`) on the fallback path.

- The **primary** TTS path is a private neural service (`TTS_SERVICE_URL`, default
  `http://127.0.0.1:3091`, i.e. Qwen3-TTS) — that is a plain HTTP call and is already
  platform-neutral.
- The `say` fallback only kicks in when that service is down or busy. So on a
  non-macOS host the 🔊 button **works whenever the TTS service is up**, and only
  breaks if the service is unavailable (the fallback would then fail).

There is currently **no `process.platform` branch** anywhere in `server.js` — the code
assumes macOS for the TTS fallback.

### 2.2 Process supervision (deployment concern, not code)

| Host | Supervisor | How |
|---|---|---|
| macOS | `launchd` | `~/Library/LaunchAgents/com.kidreminder.server.plist` + `launchctl bootstrap` |
| Linux | `systemd` | a `.service` unit with `Restart=always` |
| Windows | Task Scheduler / NSSM | a scheduled task or a service wrapper |

The **code does not change** here — only how you start/keep it alive. The launchd plist
contains only env vars (`ADMIN_PIN`, `KID_PIN`, `PORT`) plus stdout/stderr paths; the
equivalent is trivial to express in a systemd unit or a Windows service.

### 2.3 Deployment tools in docs reference macOS (`launchctl`, `scp`, `robot@<mini>`)

`backend-setup.md` and the README assume the Mac Mini host. These are documentation
references; the deploy steps themselves (`scp server.js`, restart, new tables on
startup) are OS-agnostic except for the launchd command.

---

## 3. Version floor: `node:sqlite`

`node:sqlite` is a built-in module that changed stability across Node releases:

- **Node 22.5+** — available, but experimental (may require `--experimental-sqlite`).
- **Node 23.4+ / 24.x** — available without a flag (stable enough for this use).

The current host runs **Node v24.19.0**. A Windows/Linux host must therefore use
**Node ≥ 23.4 (ideally 24 LTS)** so `const { DatabaseSync } = require("node:sqlite")`
works with no flag. This is a version requirement, **not** a platform issue.

---

## 4. What would need to change to be truly cross-platform

To make the service run cleanly on Windows/Linux, only the TTS fallback needs a
platform branch. Suggested approach:

1. **Detect the OS and pick a fallback voice provider.**
   - `process.platform === "darwin"` → keep `say` (current behaviour).
   - `process.platform === "win32"` → PowerShell `System.Speech`
     (e.g. `Add-Type -AssemblyName System.Speech; ...`).
   - `process.platform === "linux"` → `espeak-ng` if installed, otherwise skip the
     fallback.
   - If no fallback is available, **fail gracefully** (log + return a silent stub)
     instead of throwing `ENOENT`; make the 🔊 button simply report "no audio".

2. **Make the voice names configurable / optional** so a non-macOS host does not
   depend on `Tingting` / `Samantha` (Apple voices).

3. **Don't gate the whole service on the TTS fallback.** The fallback is best-effort;
   the core app should start and run even if no local TTS is present.

> The above touches only `synthesizeWithSay` / `synthesizeToFile` (a few lines) — the
> API, schema, and admin UI stay untouched.

---

## 5. Recommendation

- **Keep the Mac Mini as the primary host.** It already runs the backend, the private
  TTS service, and is reachable by the kid's Mac app on the LAN, so nothing needs to
  move.
- **Windows/Linux is a viable fallback** if you ever need to host elsewhere (e.g. a
  home server, a NAS, a container), with these prerequisites:
  - Node **24 LTS** (or ≥ 23.4) with `node:sqlite`.
  - A reachable `TTS_SERVICE_URL`, or a platform-appropriate TTS fallback (section 4).
  - `systemd` (Linux) or a service wrapper (Windows) instead of launchd.
- No data migration is needed — the SQLite file (`kidreminder.db`) is fully portable;
  just copy it alongside `server.js` and `admin.html`.

---

## 6. Summary table

| Item | macOS (current) | Windows | Linux |
|---|---|---|---|
| `node:http` / `node:fs` / `node:path` | ✅ | ✅ | ✅ |
| `node:sqlite` DB | ✅ (Node 24) | ✅ (need Node ≥ 23.4) | ✅ (need Node ≥ 23.4) |
| Admin panel (`admin.html`) | ✅ | ✅ | ✅ |
| TTS primary (HTTP service) | ✅ | ✅ | ✅ |
| TTS fallback (`say`) | ✅ | ❌ (no `say`; needs PowerShell) | ❌ (no `say`; needs `espeak-ng`) |
| Auto-start | launchd | Task Scheduler / NSSM | systemd |
| Zero npm deps | ✅ | ✅ | ✅ |

**Bottom line:** runnable on Windows/Linux today for everything except the macOS `say`
TTS fallback; a few-line change to that fallback makes the deployment fully
cross-platform.
