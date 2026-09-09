# English Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the kid a real, graded English spelling-dictation flow (hear a word + sentence, write it down, get graded, weakest-word-first selection) — full feature parity with the existing Chinese 听写 module, reusing its backend tables/endpoints instead of building a parallel system.

**Architecture:** `vocab_words` already has a `language` column reserved for exactly this ("'zh' now; 'en' later for English dictation"). The backend stays **one shared pipeline** (schema, TTS synthesis, session generation, grading) parameterized by `language`, generalized in place rather than duplicated — this is the DRY path the schema comment was written for. The **UI stays split**: a new `EnglishDictationView`/`Runner`/`SessionDetail` trio in the macOS app (mirrors the Chinese trio closely, but simpler — no custom lists, no pinyin/character), and a new admin word-bank tab in `admin.html` (English words need `topic`/`sentence`, not `character`/`pinyin`/`lesson`). The existing admin grading dialog is extended in place to handle both languages, since grading is mechanically identical for both.

**Tech Stack:** Node.js (`node:sqlite`, zero dependencies) backend; vanilla JS/HTML admin panel; SwiftUI macOS app (Swift Package Manager, no Xcode project).

**Spec:** No separate spec doc — this plan's own Architecture section is the design; it was worked out interactively with the user in the conversation that produced this plan (confirmed: reuse `vocab_words`'s `language='en'` slot, not a parallel table set).

## Global Constraints

- **Backward compatibility is non-negotiable.** Every existing Chinese 听写 call (`POST /api/dictation/sessions` with `{}`, `GET/POST/PATCH /api/vocab` without a `language` param) must keep behaving exactly as it does today. Every generalized endpoint defaults to `language: "zh"` when the param is absent.
- **No test framework exists in this repo** (confirmed: no `Tests/`, no `pytest`/`jest`/`XCTest` anywhere). Verification is manual: run the backend against a **scratch copy** of the live DB (never the live DB directly), `curl` the endpoints, inspect with `sqlite3`; for Swift, `swift build` must succeed. Deploy to the Mac Mini only after local verification passes, and only in the final task.
- **Mac Mini deploy details** (from project memory): backend lives at `robot@192.168.0.12:/Users/robot/kidreminder/`, managed by launchd as `com.kidreminder.server`, restarted via `launchctl kickstart -k gui/$(id -u)/com.kidreminder.server`. Always `cp server.js server.js.bak-<label>-$(date +%Y%m%d-%H%M%S)` (and same for `admin.html`) immediately before overwriting, and diff row counts on `vocab_words`/`dictation_sessions` before/after.
- **Seed content scope (deliberate, not a placeholder):** Task 12 seeds **40** curated English words with hand-written, dictation-appropriate example sentences (English only, no Chinese, doesn't give away the spelling) — a solid starter set, not the full ~189-word PSLE spelling list from the earlier artifact (those entries' "tips" are pedagogical explanations, not clean dictation sentences, and mix Chinese/English — wrong shape for this feature). The admin word-bank tab built in Task 7 is how the parent adds more later.

---

## File Structure

- **Modify:** `backend/server.js` — schema migration; TTS synthesis generalized by language; session creation/resume generalized; vocab CRUD generalized; history list gets a `language` filter; route docstring updated.
- **Modify:** `backend/admin.html` — new "英语听写词库" tab (list/search/add/edit/delete, mirrors the existing 生词库 tab); existing 听写记录 tab/grading dialog extended to display both languages gracefully.
- **Modify:** `macos-app/Sources/KidReminder/APIClient.swift` — `startEnglishDictation()`, `language` param added to `dictationSessions(status:)`.
- **Create:** `macos-app/Sources/KidReminder/EnglishDictationView.swift` — history list + "🎲 开始英语听写" button (single column; no custom-list column, out of scope).
- **Create:** `macos-app/Sources/KidReminder/EnglishDictationRunnerView.swift` — plays through one graded 30-word set (mirrors `DictationRunnerView`'s `.random` path only).
- **Create:** `macos-app/Sources/KidReminder/EnglishDictationSessionDetailView.swift` — per-word ✓/✗ review (mirrors `DictationSessionDetailView`, no pinyin/character line).
- **Modify:** `macos-app/Sources/KidReminder/ContentView.swift` — new sidebar entry "英语听写".
- **Modify:** `macos-app/build.sh` — version bump, per this repo's convention of one bump commit + matching git tag per macOS-app-touching release.
- **Create:** `tools/english-dictation/seed-words.js` — one-off script that `POST`s the 40 starter words to a running server's `/api/vocab` (admin-pin authenticated), so the feature has real content to test end-to-end.

---

### Task 1: Schema migration — `topic` on `vocab_words`, `language` on `dictation_sessions`

**Files:**
- Modify: `backend/server.js:674` (existing `ALTER TABLE vocab_words ADD COLUMN correct_count...` line — add the two new migrations directly after it)

**Interfaces:**
- Produces: `vocab_words.topic` (TEXT, default `''`) — English-only free-text grouping tag (e.g. "Silent Letters"); Chinese rows leave it blank, they already have `lesson`/`lesson_index`.
- Produces: `dictation_sessions.language` (TEXT, default `'zh'`) — set once at session creation (Task 3); lets history/grading filter and display by language without joining through items.

- [ ] **Step 1: Add the two migration lines**

In `backend/server.js`, find this existing line (search for `ALTER TABLE vocab_words ADD COLUMN correct_count`):

```js
try { db.exec("ALTER TABLE vocab_words ADD COLUMN correct_count INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ }
```

Add immediately after it:

```js
// English dictation (2026-09): vocab_words.language already had an 'en' slot reserved
// ("'zh' now; 'en' later for English dictation") — these two migrations are what turn
// that reservation into a real, working second language sharing the same tables.
try { db.exec("ALTER TABLE vocab_words ADD COLUMN topic TEXT NOT NULL DEFAULT ''"); } catch { /* exists */ }
try { db.exec("ALTER TABLE dictation_sessions ADD COLUMN language TEXT NOT NULL DEFAULT 'zh'"); } catch { /* exists */ }
```

- [ ] **Step 2: Verify against a scratch copy of the live DB**

```bash
mkdir -p /tmp/endict-test
scp -q robot@192.168.0.12:/Users/robot/kidreminder/kidreminder.db /tmp/endict-test/kidreminder.db
cd backend
DB_PATH=/tmp/endict-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5
curl -s http://127.0.0.1:2099/api/health
sqlite3 /tmp/endict-test/kidreminder.db "SELECT COUNT(*) FROM pragma_table_info('vocab_words') WHERE name='topic';"
sqlite3 /tmp/endict-test/kidreminder.db "SELECT COUNT(*) FROM pragma_table_info('dictation_sessions') WHERE name='language';"
sqlite3 /tmp/endict-test/kidreminder.db "SELECT COUNT(*), SUM(correct_count) FROM vocab_words;"
```

Expected: health check returns `{"ok":true,...}`; both `pragma_table_info` counts return `1`; the `vocab_words` count/sum matches what it was on the live DB before this change (no data touched, only schema added). Keep this server running — Task 2 reuses it. Leave the DB copy in place too.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "feat(dictation): add vocab_words.topic + dictation_sessions.language columns"
```

---

### Task 2: Generalize TTS audio synthesis by language

**Files:**
- Modify: `backend/server.js:212-250` (`ensureDictationAudio`, `precacheDictationAudio`, `deleteDictationAudio`)
- Modify: `backend/server.js:1600-1618` (`GET /dictation-audio/:id.wav` handler)

**Interfaces:**
- Consumes: `TTS_INSTRUCT`, `TTS_INSTRUCT_EN`, `SAY_VOICE_ZH`, `SAY_VOICE_EN`, `synthesizeToFile(file, text, instruct, sayVoice)` — all already defined (lines 90-101, 111-122).
- Produces: `ensureDictationAudio(wordId, word, sentence, language)` — new 4th parameter, **required** (no default — every call site is updated in this task, so a missing 4th arg is a bug to catch loudly, not paper over).

- [ ] **Step 1: Change `ensureDictationAudio`'s signature and body**

Find (around line 212):

```js
async function ensureDictationAudio(wordId, word, sentence) {
  const file = path.join(DICTATION_AUDIO_DIR, `${wordId}.wav`);
  if (fs.existsSync(file)) return file;
  if (inFlightDictationAudio.has(wordId)) return inFlightDictationAudio.get(wordId);
  const promise = (async () => {
    const text = `${word}。${sentence}`;
    await synthesizeToFile(file, text, TTS_INSTRUCT, SAY_VOICE_ZH);
    return file;
  })();
  inFlightDictationAudio.set(wordId, promise);
  try {
    return await promise;
  } finally {
    inFlightDictationAudio.delete(wordId);
  }
}
```

Replace with:

```js
async function ensureDictationAudio(wordId, word, sentence, language) {
  const file = path.join(DICTATION_AUDIO_DIR, `${wordId}.wav`);
  if (fs.existsSync(file)) return file;
  if (inFlightDictationAudio.has(wordId)) return inFlightDictationAudio.get(wordId);
  const promise = (async () => {
    const isEn = language === "en";
    // Chinese uses the full-width period as a natural pause between word and example
    // sentence; English dictation reads the same way but with a regular period+space —
    // ASCII punctuation here, not the zh one, or the TTS mispronounces the pause.
    const text = isEn ? `${word}. ${sentence}` : `${word}。${sentence}`;
    await synthesizeToFile(file, text, isEn ? TTS_INSTRUCT_EN : TTS_INSTRUCT, isEn ? SAY_VOICE_EN : SAY_VOICE_ZH);
    return file;
  })();
  inFlightDictationAudio.set(wordId, promise);
  try {
    return await promise;
  } finally {
    inFlightDictationAudio.delete(wordId);
  }
}
```

- [ ] **Step 2: Update `precacheDictationAudio` to fetch and pass `language`**

Find (around line 234):

```js
function precacheDictationAudio(wordIds) {
  const getWord = db.prepare("SELECT word, sentence FROM vocab_words WHERE id = ?");
  (async () => {
    for (const wordId of wordIds) {
      const word = getWord.get(wordId);
      if (!word) continue;
      try {
        await ensureDictationAudio(wordId, word.word, word.sentence);
      } catch (err) {
        console.error(`[kid-reminder] precache failed for word ${wordId}: ${err.message}`);
      }
    }
  })();
}
```

Replace with:

```js
function precacheDictationAudio(wordIds) {
  const getWord = db.prepare("SELECT word, sentence, language FROM vocab_words WHERE id = ?");
  (async () => {
    for (const wordId of wordIds) {
      const word = getWord.get(wordId);
      if (!word) continue;
      try {
        await ensureDictationAudio(wordId, word.word, word.sentence, word.language);
      } catch (err) {
        console.error(`[kid-reminder] precache failed for word ${wordId}: ${err.message}`);
      }
    }
  })();
}
```

- [ ] **Step 3: Update the `/dictation-audio/:id.wav` handler**

Find (around line 1601):

```js
    if (method === "GET" && pathname.startsWith("/dictation-audio/")) {
      const file = path.basename(pathname);
      const m = file.match(/^(\d+)\.wav$/);
      if (!m) return sendJSON(404, { error: "not found" });
      const wordId = Number(m[1]);
      const word = db.prepare("SELECT word, sentence FROM vocab_words WHERE id = ?").get(wordId);
      if (!word) return sendJSON(404, { error: "word not found" });
      let filePath;
      try {
        filePath = await ensureDictationAudio(wordId, word.word, word.sentence);
      } catch (err) {
```

Replace the two `SELECT`/call lines:

```js
      const word = db.prepare("SELECT word, sentence, language FROM vocab_words WHERE id = ?").get(wordId);
      if (!word) return sendJSON(404, { error: "word not found" });
      let filePath;
      try {
        filePath = await ensureDictationAudio(wordId, word.word, word.sentence, word.language);
      } catch (err) {
```

- [ ] **Step 4: Restart the scratch server and verify a Chinese word's audio still works**

```bash
kill %1 2>/dev/null; sleep 0.5
cd backend
DB_PATH=/tmp/endict-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5
sqlite3 /tmp/endict-test/kidreminder.db "SELECT id, word, language FROM vocab_words WHERE language='zh' LIMIT 1;"
# use the id printed above in place of <ID>:
curl -s -o /tmp/endict-test/word.wav -w "%{http_code}\n" "http://127.0.0.1:2099/dictation-audio/<ID>.wav"
file /tmp/endict-test/word.wav   # expect: RIFF (little-endian) data, WAVE audio
```

Expected: HTTP `200`, and `file` reports a valid WAV. This confirms the existing Chinese path is unbroken (English can't be verified yet — no English words exist until Task 12).

- [ ] **Step 5: Commit**

```bash
git add backend/server.js
git commit -m "feat(dictation): synthesize dictation audio in the correct language"
```

---

### Task 3: Generalize dictation session creation + resume

**Files:**
- Modify: `backend/server.js:1620-1663` (`POST /api/dictation/sessions`)

**Interfaces:**
- Consumes: request body `{ language?: "zh" | "en" }` — optional, defaults to `"zh"`.
- Produces: unchanged response shape `{ sessionId, items: [{seq, wordId}] }` — callers that don't send `language` see byte-identical behavior to before.

- [ ] **Step 1: Replace the handler**

Find (around line 1621):

```js
    if (method === "POST" && pathname === "/api/dictation/sessions") {
      // Resume an existing in_progress session instead of always starting a new one —
      // the app's dictation view is torn down and rebuilt whenever the kid switches
      // sidebar tabs (or if it gets stuck and they navigate away to recover), which used
      // to silently abandon the in-flight session and spawn a fresh one every time,
      // permanently losing progress. Replaying already-heard words from the top is a
      // minor annoyance; losing the set entirely is not.
      const existing = db.prepare("SELECT id FROM dictation_sessions WHERE status = 'in_progress' ORDER BY created_at DESC LIMIT 1").get();
      if (existing) {
        const items = db.prepare("SELECT seq, word_id AS wordId FROM dictation_items WHERE session_id = ? ORDER BY seq").all(existing.id);
        if (items.length) {
          precacheDictationAudio(items.map((i) => i.wordId));
          return sendJSON(200, { sessionId: existing.id, items });
        }
      }

      // Word selection: weakest first (lowest correct_count), lower grade level breaks
      // ties, and RANDOM() as the final tiebreaker so words tied on both don't always
      // come out in the same order. SQLite evaluates ORDER BY expressions once per row
      // before sorting, so RANDOM() here really is one fixed value per word for this
      // query, not re-rolled per comparison. 30 words per dictation set.
      const wordIds = db
        .prepare(
          `SELECT id FROM vocab_words WHERE language = 'zh'
           ORDER BY correct_count ASC, level ASC, RANDOM() ASC LIMIT 30`
        )
        .all()
        .map((r) => r.id);
      if (wordIds.length === 0) return sendJSON(400, { error: "vocab bank is empty" });

      // shuffle the overall dictation order
      for (let i = wordIds.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [wordIds[i], wordIds[j]] = [wordIds[j], wordIds[i]]; }

      const info = db.prepare("INSERT INTO dictation_sessions DEFAULT VALUES").run();
      const sessionId = Number(info.lastInsertRowid);
      const insertItem = db.prepare("INSERT INTO dictation_items (session_id, word_id, seq) VALUES (?, ?, ?)");
      const items = wordIds.map((wordId, i) => {
        insertItem.run(sessionId, wordId, i + 1);
        return { seq: i + 1, wordId };
      });
      precacheDictationAudio(wordIds);
      return sendJSON(201, { sessionId, items });
    }
```

Replace with:

```js
    if (method === "POST" && pathname === "/api/dictation/sessions") {
      const body = await readBody(req);
      const language = body.language === "en" ? "en" : "zh";

      // Resume an existing in_progress session instead of always starting a new one —
      // the app's dictation view is torn down and rebuilt whenever the kid switches
      // sidebar tabs (or if it gets stuck and they navigate away to recover), which used
      // to silently abandon the in-flight session and spawn a fresh one every time,
      // permanently losing progress. Replaying already-heard words from the top is a
      // minor annoyance; losing the set entirely is not. Scoped to `language` too — a
      // resume must not hand an English session's words back to the Chinese screen (or
      // vice versa) just because it happened to be the most recent in_progress row.
      const existing = db.prepare("SELECT id FROM dictation_sessions WHERE status = 'in_progress' AND language = ? ORDER BY created_at DESC LIMIT 1").get(language);
      if (existing) {
        const items = db.prepare("SELECT seq, word_id AS wordId FROM dictation_items WHERE session_id = ? ORDER BY seq").all(existing.id);
        if (items.length) {
          precacheDictationAudio(items.map((i) => i.wordId));
          return sendJSON(200, { sessionId: existing.id, items });
        }
      }

      // Word selection: weakest first (lowest correct_count), lower grade level breaks
      // ties, and RANDOM() as the final tiebreaker so words tied on both don't always
      // come out in the same order. SQLite evaluates ORDER BY expressions once per row
      // before sorting, so RANDOM() here really is one fixed value per word for this
      // query, not re-rolled per comparison. 30 words per dictation set.
      const wordIds = db
        .prepare(
          `SELECT id FROM vocab_words WHERE language = ?
           ORDER BY correct_count ASC, level ASC, RANDOM() ASC LIMIT 30`
        )
        .all(language)
        .map((r) => r.id);
      if (wordIds.length === 0) {
        return sendJSON(400, { error: language === "en" ? "英语听写词库还是空的，请先在网页端添加单词" : "vocab bank is empty" });
      }

      // shuffle the overall dictation order
      for (let i = wordIds.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [wordIds[i], wordIds[j]] = [wordIds[j], wordIds[i]]; }

      const info = db.prepare("INSERT INTO dictation_sessions (language) VALUES (?)").run(language);
      const sessionId = Number(info.lastInsertRowid);
      const insertItem = db.prepare("INSERT INTO dictation_items (session_id, word_id, seq) VALUES (?, ?, ?)");
      const items = wordIds.map((wordId, i) => {
        insertItem.run(sessionId, wordId, i + 1);
        return { seq: i + 1, wordId };
      });
      precacheDictationAudio(wordIds);
      return sendJSON(201, { sessionId, items });
    }
```

- [ ] **Step 2: Verify the existing Chinese flow is untouched**

```bash
kill %1 2>/dev/null; sleep 0.5
cd backend
DB_PATH=/tmp/endict-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5
curl -s -X POST -H "Content-Type: application/json" -d '{}' http://127.0.0.1:2099/api/dictation/sessions | python3 -m json.tool
```

Expected: `201`-shaped JSON with `sessionId` and 30 `items`, exactly as before (no `language` in the request body — old client behavior).

- [ ] **Step 3: Verify the new English path fails cleanly (no English words exist yet)**

```bash
curl -s -X POST -H "Content-Type: application/json" -d '{"language":"en"}' http://127.0.0.1:2099/api/dictation/sessions
```

Expected: `{"error":"英语听写词库还是空的，请先在网页端添加单词"}` — proves the `language` branch is wired up correctly (it'll start returning real sessions once Task 12 seeds words).

- [ ] **Step 4: Commit**

```bash
git add backend/server.js
git commit -m "feat(dictation): scope session creation/resume by language"
```

---

### Task 4: Generalize the `/api/vocab` word-bank CRUD endpoints

**Files:**
- Modify: `backend/server.js:1496-1598` (`GET /api/vocab`, `POST /api/vocab`, `PATCH /api/vocab/:id`)

**Interfaces:**
- Consumes: `GET /api/vocab?language=en` (optional filter, default: all languages — unchanged from today since today only `zh` rows exist); `POST /api/vocab` body gains optional `language` (default `"zh"`) and, for `language: "en"`, a new `topic` field; `PATCH /api/vocab/:id` body gains optional `topic`.
- Produces: `POST`/`PATCH` still return `{ id }` / `{ ok: true }` respectively — unchanged shapes.

- [ ] **Step 1: Add `language` filtering + `topic` search to `GET /api/vocab`**

Find (around line 1496):

```js
    if (method === "GET" && pathname === "/api/vocab") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const search = (url.searchParams.get("search") || "").trim();
      const level = url.searchParams.get("level") || "";
      const category = url.searchParams.get("category") || "";
      const limit = Math.max(1, Math.min(200, parseInt(url.searchParams.get("limit") || "50", 10) || 50));
      const offset = Math.max(0, parseInt(url.searchParams.get("offset") || "0", 10) || 0);

      const where = [];
      const params = [];
      if (search) {
        where.push("(character LIKE ? OR word LIKE ? OR pinyin LIKE ? OR sentence LIKE ?)");
        const like = `%${search}%`;
        params.push(like, like, like, like);
      }
      if (level) { where.push("level = ?"); params.push(level); }
      if (category) { where.push("category = ?"); params.push(category); }
      const whereSql = where.length ? `WHERE ${where.join(" AND ")}` : "";
```

Replace with:

```js
    if (method === "GET" && pathname === "/api/vocab") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const search = (url.searchParams.get("search") || "").trim();
      const level = url.searchParams.get("level") || "";
      const category = url.searchParams.get("category") || "";
      const language = url.searchParams.get("language") || "";
      const limit = Math.max(1, Math.min(200, parseInt(url.searchParams.get("limit") || "50", 10) || 50));
      const offset = Math.max(0, parseInt(url.searchParams.get("offset") || "0", 10) || 0);

      const where = [];
      const params = [];
      if (search) {
        where.push("(character LIKE ? OR word LIKE ? OR pinyin LIKE ? OR sentence LIKE ? OR topic LIKE ?)");
        const like = `%${search}%`;
        params.push(like, like, like, like, like);
      }
      if (level) { where.push("level = ?"); params.push(level); }
      if (category) { where.push("category = ?"); params.push(category); }
      if (language) { where.push("language = ?"); params.push(language); }
      const whereSql = where.length ? `WHERE ${where.join(" AND ")}` : "";
```

(The rest of this handler — the two `db.prepare(...)` calls below — is unchanged; it already interpolates `whereSql`/`params` generically.)

- [ ] **Step 2: Branch `POST /api/vocab` by language**

Find the entire existing handler (around line 1523):

```js
    if (method === "POST" && pathname === "/api/vocab") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      const character = String(body.character || "").trim();
      const word = String(body.word || "").trim();
      const pinyin = String(body.pinyin || "").trim();
      const sentence = String(body.sentence || "").trim();
      const level = String(body.level || "").trim();
      const lessonIndex = parseInt(body.lessonIndex, 10);
      const lesson = String(body.lesson || "").trim();
      const category = ["read", "write"].includes(body.category) ? body.category : "write";
      if (!character || !word || !pinyin || !sentence || !level || !lesson || !Number.isInteger(lessonIndex)) {
        return sendJSON(400, { error: "character, word, pinyin, sentence, level, lessonIndex, lesson are required" });
      }
      const correctCount = Number.isFinite(Number(body.correctCount)) ? Math.round(Number(body.correctCount)) : 0;
      try {
        const info = db
          .prepare(
            `INSERT INTO vocab_words (language, level, lesson_index, lesson, category, character, word, pinyin, sentence, correct_count, source)
             VALUES ('zh', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual')`
          )
          .run(level, lessonIndex, lesson, category, character, word, pinyin, sentence, correctCount);
        return sendJSON(201, { id: Number(info.lastInsertRowid) });
      } catch (err) {
        if (String(err.message).includes("UNIQUE")) return sendJSON(409, { error: "this character+word already exists for that level/lesson/category" });
        throw err;
      }
    }
```

Replace with:

```js
    if (method === "POST" && pathname === "/api/vocab") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      const language = body.language === "en" ? "en" : "zh";
      const word = String(body.word || "").trim();
      const sentence = String(body.sentence || "").trim();
      const level = String(body.level || "").trim();
      const correctCount = Number.isFinite(Number(body.correctCount)) ? Math.round(Number(body.correctCount)) : 0;

      if (language === "en") {
        // English dictation words have no character/pinyin/lesson concept — `topic` is
        // the free-text grouping tag instead (e.g. "Silent Letters"), and lesson_index/
        // lesson/category/character/pinyin are all stored blank/zero (NOT NULL columns
        // shared with the zh rows, so they need *some* value, just an unused one).
        const topic = String(body.topic || "").trim();
        if (!word || !sentence || !level) {
          return sendJSON(400, { error: "word, sentence, level are required" });
        }
        try {
          const info = db
            .prepare(
              `INSERT INTO vocab_words (language, level, lesson_index, lesson, category, character, word, pinyin, sentence, topic, correct_count, source)
               VALUES ('en', ?, 0, '', '', '', ?, '', ?, ?, ?, 'manual')`
            )
            .run(level, word, sentence, topic, correctCount);
          return sendJSON(201, { id: Number(info.lastInsertRowid) });
        } catch (err) {
          if (String(err.message).includes("UNIQUE")) return sendJSON(409, { error: "this word already exists for that level" });
          throw err;
        }
      }

      const character = String(body.character || "").trim();
      const pinyin = String(body.pinyin || "").trim();
      const lessonIndex = parseInt(body.lessonIndex, 10);
      const lesson = String(body.lesson || "").trim();
      const category = ["read", "write"].includes(body.category) ? body.category : "write";
      if (!character || !word || !pinyin || !sentence || !level || !lesson || !Number.isInteger(lessonIndex)) {
        return sendJSON(400, { error: "character, word, pinyin, sentence, level, lessonIndex, lesson are required" });
      }
      try {
        const info = db
          .prepare(
            `INSERT INTO vocab_words (language, level, lesson_index, lesson, category, character, word, pinyin, sentence, correct_count, source)
             VALUES ('zh', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual')`
          )
          .run(level, lessonIndex, lesson, category, character, word, pinyin, sentence, correctCount);
        return sendJSON(201, { id: Number(info.lastInsertRowid) });
      } catch (err) {
        if (String(err.message).includes("UNIQUE")) return sendJSON(409, { error: "this character+word already exists for that level/lesson/category" });
        throw err;
      }
    }
```

- [ ] **Step 3: Branch `PATCH /api/vocab/:id`'s category validation by the row's own language, and add `topic`**

Find (around line 1559, the `if (method === "PATCH")` block inside the `vocabMatch` handler):

```js
      if (method === "PATCH") {
        const body = await readBody(req);
        const sets = [];
        const vals = [];
        const strField = (key, col) => { if (body[key] !== undefined) { sets.push(`${col} = ?`); vals.push(String(body[key]).trim()); } };
        strField("character", "character");
        strField("word", "word");
        strField("pinyin", "pinyin");
        strField("sentence", "sentence");
        strField("level", "level");
        strField("lesson", "lesson");
        if (body.lessonIndex !== undefined) { sets.push("lesson_index = ?"); vals.push(parseInt(body.lessonIndex, 10) || 0); }
        if (body.category !== undefined && ["read", "write"].includes(body.category)) { sets.push("category = ?"); vals.push(body.category); }
        if (body.correctCount !== undefined) { sets.push("correct_count = ?"); vals.push(Math.round(Number(body.correctCount)) || 0); }
        if (!sets.length) return sendJSON(400, { error: "nothing to update" });
        vals.push(id);
        try {
          const info = db.prepare(`UPDATE vocab_words SET ${sets.join(", ")} WHERE id = ?`).run(...vals);
          if (!info.changes) return sendJSON(404, { error: "word not found" });
          // text changed -> stale cached audio, regenerate lazily next time it's needed
          if (body.word !== undefined || body.sentence !== undefined) deleteDictationAudio(id);
          return sendJSON(200, { ok: true });
        } catch (err) {
          if (String(err.message).includes("UNIQUE")) return sendJSON(409, { error: "this character+word already exists for that level/lesson/category" });
          throw err;
        }
      }
```

Replace with:

```js
      if (method === "PATCH") {
        const existing = db.prepare("SELECT language FROM vocab_words WHERE id = ?").get(id);
        if (!existing) return sendJSON(404, { error: "word not found" });
        const body = await readBody(req);
        const sets = [];
        const vals = [];
        const strField = (key, col) => { if (body[key] !== undefined) { sets.push(`${col} = ?`); vals.push(String(body[key]).trim()); } };
        strField("character", "character");
        strField("word", "word");
        strField("pinyin", "pinyin");
        strField("sentence", "sentence");
        strField("level", "level");
        strField("lesson", "lesson");
        strField("topic", "topic");
        if (body.lessonIndex !== undefined) { sets.push("lesson_index = ?"); vals.push(parseInt(body.lessonIndex, 10) || 0); }
        if (body.category !== undefined) {
          // zh keeps the fixed 识读/识写 enum; en has no such enum, any tag is fine.
          if (existing.language === "zh") {
            if (["read", "write"].includes(body.category)) { sets.push("category = ?"); vals.push(body.category); }
          } else {
            sets.push("category = ?"); vals.push(String(body.category).trim());
          }
        }
        if (body.correctCount !== undefined) { sets.push("correct_count = ?"); vals.push(Math.round(Number(body.correctCount)) || 0); }
        if (!sets.length) return sendJSON(400, { error: "nothing to update" });
        vals.push(id);
        try {
          const info = db.prepare(`UPDATE vocab_words SET ${sets.join(", ")} WHERE id = ?`).run(...vals);
          if (!info.changes) return sendJSON(404, { error: "word not found" });
          // text changed -> stale cached audio, regenerate lazily next time it's needed
          if (body.word !== undefined || body.sentence !== undefined) deleteDictationAudio(id);
          return sendJSON(200, { ok: true });
        } catch (err) {
          if (String(err.message).includes("UNIQUE")) return sendJSON(409, { error: "this word already exists for that level/lesson/category" });
          throw err;
        }
      }
```

- [ ] **Step 4: Verify both languages end-to-end against the scratch server**

```bash
kill %1 2>/dev/null; sleep 0.5
cd backend
DB_PATH=/tmp/endict-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5

# existing zh path unchanged: level/category still required, still works
curl -s -X POST -H "Content-Type: application/json" -H "X-Admin-Pin: 1234" \
  -d '{"character":"测","word":"测试","pinyin":"cè shì","sentence":"这是一次测试。","level":"P5","lesson":"测试课","lessonIndex":1}' \
  http://127.0.0.1:2099/api/vocab

# new en path: minimal fields, gets a topic
curl -s -X POST -H "Content-Type: application/json" -H "X-Admin-Pin: 1234" \
  -d '{"language":"en","word":"handkerchief","sentence":"She folded the handkerchief neatly.","level":"P6","topic":"Silent Letters"}' \
  http://127.0.0.1:2099/api/vocab

# filter works
curl -s -H "X-Admin-Pin: 1234" "http://127.0.0.1:2099/api/vocab?language=en" | python3 -m json.tool
curl -s -H "X-Admin-Pin: 1234" "http://127.0.0.1:2099/api/vocab?language=zh&search=测试" | python3 -m json.tool
```

Expected: both `POST`s return `{"id": <n>}` (201 status); the `language=en` filter returns exactly the one English word with `"topic":"Silent Letters"`; the `language=zh&search=测试` filter returns the Chinese test word. Then clean up the two test rows:

```bash
curl -s -X DELETE -H "X-Admin-Pin: 1234" "http://127.0.0.1:2099/api/vocab/<zh-id>"
curl -s -X DELETE -H "X-Admin-Pin: 1234" "http://127.0.0.1:2099/api/vocab/<en-id>"
```

- [ ] **Step 5: Update the route docstring header**

In `backend/server.js`, find (near the top, in the big comment block):

```js
//   GET  /api/vocab                       -> search/list dictation word bank [X-Admin-Pin]
//   POST /api/vocab                       -> add a word                      [X-Admin-Pin]
//   PATCH /api/vocab/:id                  -> edit a word                     [X-Admin-Pin]
//   DELETE /api/vocab/:id                 -> delete a word                   [X-Admin-Pin]
```

Replace with:

```js
//   GET  /api/vocab                       -> search/list dictation word bank (?language=zh|en) [X-Admin-Pin]
//   POST /api/vocab                       -> add a word (body.language: "zh"|"en", default zh) [X-Admin-Pin]
//   PATCH /api/vocab/:id                  -> edit a word                     [X-Admin-Pin]
//   DELETE /api/vocab/:id                 -> delete a word                   [X-Admin-Pin]
```

And find:

```js
//   POST /api/dictation/sessions          -> resume in_progress, else generate new (kid app)
```

Replace with:

```js
//   POST /api/dictation/sessions          -> resume in_progress, else generate new (kid app; body.language: "zh"|"en", default zh)
```

- [ ] **Step 6: Commit**

```bash
git add backend/server.js
git commit -m "feat(dictation): branch /api/vocab CRUD by language, add topic field"
```

---

### Task 5: Add a `language` filter to the dictation history list endpoint

**Files:**
- Modify: `backend/server.js:1685-1702` (`GET /api/dictation/sessions`)

**Interfaces:**
- Consumes: `GET /api/dictation/sessions?status=graded&language=en` — `language` is optional (omit = all languages, unchanged from today).
- Produces: each session row now includes `language` (was already implicitly `'zh'` for every existing row via the Task 1 migration's default).

- [ ] **Step 1: Replace the handler**

Find:

```js
    if (method === "GET" && pathname === "/api/dictation/sessions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const status = url.searchParams.get("status") || "";
      const where = status ? "WHERE status = ?" : "";
      const rows = db
        .prepare(
          `SELECT s.id, s.status, s.created_at, s.completed_at, s.graded_at,
                  COUNT(i.id) itemCount,
                  SUM(CASE WHEN i.result = 'correct' THEN 1 ELSE 0 END) correctCount,
                  SUM(CASE WHEN i.result = 'incorrect' THEN 1 ELSE 0 END) incorrectCount
           FROM dictation_sessions s LEFT JOIN dictation_items i ON i.session_id = s.id
           ${where} GROUP BY s.id ORDER BY s.created_at DESC`
        )
        .all(...(status ? [status] : []));
      return sendJSON(200, { sessions: rows });
    }
```

Replace with:

```js
    if (method === "GET" && pathname === "/api/dictation/sessions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const status = url.searchParams.get("status") || "";
      const language = url.searchParams.get("language") || "";
      const where = [];
      const args = [];
      if (status) { where.push("s.status = ?"); args.push(status); }
      if (language) { where.push("s.language = ?"); args.push(language); }
      const whereSql = where.length ? `WHERE ${where.join(" AND ")}` : "";
      const rows = db
        .prepare(
          `SELECT s.id, s.status, s.language, s.created_at, s.completed_at, s.graded_at,
                  COUNT(i.id) itemCount,
                  SUM(CASE WHEN i.result = 'correct' THEN 1 ELSE 0 END) correctCount,
                  SUM(CASE WHEN i.result = 'incorrect' THEN 1 ELSE 0 END) incorrectCount
           FROM dictation_sessions s LEFT JOIN dictation_items i ON i.session_id = s.id
           ${whereSql} GROUP BY s.id ORDER BY s.created_at DESC`
        )
        .all(...args);
      return sendJSON(200, { sessions: rows });
    }
```

- [ ] **Step 2: Verify**

```bash
kill %1 2>/dev/null; sleep 0.5
cd backend
DB_PATH=/tmp/endict-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5
curl -s -H "X-Admin-Pin: 1234" "http://127.0.0.1:2099/api/dictation/sessions" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['sessions']), 'sessions; languages seen:', {s.get('language') for s in d['sessions']})"
curl -s -H "X-Admin-Pin: 1234" "http://127.0.0.1:2099/api/dictation/sessions?language=en" | python3 -m json.tool
```

Expected: the unfiltered call returns every existing session (all `language: "zh"`, proving the migration's default backfilled correctly); the `language=en` call returns an empty `sessions: []` (no English sessions exist yet). Then stop the scratch server: `kill %1`.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "feat(dictation): add language filter to session history list"
```

---

### Task 6: Admin UI — new "英语听写词库" word-bank tab

**Files:**
- Modify: `backend/admin.html` (tab button, panel view, dialog, JS — mirrors the existing 生词库 tab exactly, minus character/pinyin/lesson, plus topic)

**Interfaces:**
- Consumes: `GET /api/vocab?language=en&...`, `POST /api/vocab` (with `language:"en"`), `PATCH /api/vocab/:id`, `DELETE /api/vocab/:id` — all from Task 4.
- Produces: a new tab in the existing tab-bar/panel/FAB/dialog system, following the exact same wiring pattern as `tabVocab`/`vocabView`/`fabAddVocab`/`vocabDialog`.

- [ ] **Step 1: Add the tab button**

Find (near line 267-274, the tab-bar `<button>` list):

```html
        <button class="tab" id="tabVocab" hidden>📚 生词库</button>
```

Add immediately after it:

```html
        <button class="tab" id="tabEnVocab" hidden>🔤 英语听写词库</button>
```

- [ ] **Step 2: Add the panel view**

Find the end of the existing `vocabView` block (search for `<div id="vocabView" hidden>` and its closing, right before `<!-- English wrong-answer bank view -->`):

```html
        <div class="vocab-pager">
          <button id="vocabPrev">‹ 上一页</button>
          <span id="vocabPageLabel"></span>
          <button id="vocabNext">下一页 ›</button>
        </div>
      </div>
    </div>

    <!-- English wrong-answer bank view -->
```

Insert a new panel block between the closing `</div></div>` and the `<!-- English wrong-answer bank view -->` comment:

```html
    <!-- English dictation word bank -->
    <div id="enVocabView" hidden>
      <div class="card">
        <div class="vocab-filters">
          <input type="text" id="enVocabSearch" placeholder="搜索单词 / 例句 / 分类…" />
          <select id="enVocabLevelFilter">
            <option value="">全部年级</option>
            <option value="P1">P1</option><option value="P2">P2</option><option value="P3">P3</option>
            <option value="P4">P4</option><option value="P5">P5</option><option value="P6">P6</option>
          </select>
        </div>
        <div class="vocab-summary" id="enVocabSummary"></div>
        <div class="vocab-list" id="enVocabList"></div>
        <div class="vocab-pager">
          <button id="enVocabPrev">‹ 上一页</button>
          <span id="enVocabPageLabel"></span>
          <button id="enVocabNext">下一页 ›</button>
        </div>
      </div>
    </div>

```

- [ ] **Step 3: Add the FAB button**

Find (near line 461-464):

```html
<button id="fabAddVocab" title="添加生词" hidden>＋</button>
```

Add immediately after it:

```html
<button id="fabAddEnVocab" title="添加英语单词" hidden>＋</button>
```

And in the CSS selector list that styles these FABs (search for `#fabAdd, #fabAddVocab, #fabAddEnglish, #fabAddList`), add `#fabAddEnVocab` to both rules:

```css
  #fabAdd, #fabAddVocab, #fabAddEnVocab, #fabAddEnglish, #fabAddList { position:fixed; right:22px; bottom:22px; width:60px; height:60px; border-radius:50%;
```

```css
  #fabAdd:hover, #fabAddVocab:hover, #fabAddEnVocab:hover, #fabAddEnglish:hover, #fabAddList:hover { filter:brightness(1.08); }
```

- [ ] **Step 4: Add the add/edit dialog**

Find the end of the existing `vocabDialog`:

```html
<dialog id="vocabDialog">
  ...
</dialog>

<dialog id="engDialog">
```

Insert a new dialog between them:

```html
<dialog id="enVocabDialog">
  <h3 id="enVocabDlgTitle">➕ 添加英语单词</h3>
  <div class="add">
    <input type="text" id="evDlgWord" placeholder="单词（如：handkerchief）" maxlength="60" style="flex:1 1 auto" />
  </div>
  <div class="add">
    <input type="text" id="evDlgSentence" placeholder="例句（英文，听写会读这句话）" maxlength="200" style="flex:1 1 auto" />
  </div>
  <div class="add">
    <select id="evDlgLevel">
      <option value="P1">P1</option><option value="P2">P2</option><option value="P3">P3</option>
      <option value="P4">P4</option><option value="P5">P5</option><option value="P6">P6</option>
    </select>
    <input type="text" id="evDlgTopic" placeholder="分类（如：Silent Letters，选填）" style="flex:1 1 auto" />
    <label>正确数 <input type="number" id="evDlgCorrectCount" value="0" style="width:70px" /></label>
  </div>
  <div class="msg err" id="enVocabDlgErr"></div>
  <div class="row">
    <button class="ghost" id="evDlgCancel">Cancel</button>
    <button class="primary" id="evDlgSave">Save</button>
  </div>
</dialog>

```

- [ ] **Step 5: Wire up the tab in `setTab()`**

Find the `setTab` function (search for `function setTab(t) {`) and its `tabVocab`/`vocabView` lines:

```js
    $("#tabVocab").classList.toggle("active", t === "vocab");
```
```js
    $("#vocabView").hidden = t !== "vocab";
```
```js
    $("#fabAddVocab").hidden = t !== "vocab" || role !== "admin";
```
```js
    else if (t === "vocab") { vocabOffset = 0; refreshVocab(); }
```

Add the matching `enVocab` line directly after each one respectively:

```js
    $("#tabEnVocab").classList.toggle("active", t === "enVocab");
```
```js
    $("#enVocabView").hidden = t !== "enVocab";
```
```js
    $("#fabAddEnVocab").hidden = t !== "enVocab" || role !== "admin";
```
```js
    else if (t === "enVocab") { enVocabOffset = 0; refreshEnVocab(); }
```

Also find this line inside `setTab`:

```js
    const noTaskFab = ["vocab", "dictation", "english", "engRecords", "dictationLists", "science", "scienceMistakes", "epaper", "epaperMistakes"].includes(t);
```

Replace with:

```js
    const noTaskFab = ["vocab", "enVocab", "dictation", "english", "engRecords", "dictationLists", "science", "scienceMistakes", "epaper", "epaperMistakes"].includes(t);
```

- [ ] **Step 6: Add the JS logic — state vars, refresh/row/dialog functions, event wiring**

Find the existing vocab state variables (search for `let vocabOffset`, likely near other `let ...Offset` declarations at the top of the `<script>` block) and add alongside them:

```js
  let enVocabOffset = 0, enVocabLimit = 50, enVocabTotal = 0, enVocabEditingId = null;
```

Find the end of the existing vocab section — right after this block (search for `$("#vocabNext").onclick`):

```js
  $("#vocabPrev").onclick = () => { vocabOffset = Math.max(0, vocabOffset - vocabLimit); refreshVocab(); };
  $("#vocabNext").onclick = () => { vocabOffset = vocabOffset + vocabLimit; refreshVocab(); };
```

Insert the whole new English word-bank section immediately after it:

```js

  // ---- English dictation word bank ----------------------------------------
  function enVocabFilters() {
    return {
      search: $("#enVocabSearch").value.trim(),
      level: $("#enVocabLevelFilter").value,
    };
  }

  async function refreshEnVocab() {
    try {
      const f = enVocabFilters();
      const qs = new URLSearchParams({
        language: "en",
        ...(f.search ? { search: f.search } : {}),
        ...(f.level ? { level: f.level } : {}),
        limit: enVocabLimit,
        offset: enVocabOffset,
      });
      const data = await api(`/api/vocab?${qs.toString()}`);
      enVocabTotal = data.total;
      const el = $("#enVocabList");
      el.innerHTML = "";
      if (!data.words.length) {
        el.innerHTML = '<div class="empty">没有符合条件的单词</div>';
      } else {
        for (const w of data.words) el.appendChild(enVocabRow(w));
      }
      const from = enVocabTotal === 0 ? 0 : enVocabOffset + 1;
      const to = Math.min(enVocabOffset + enVocabLimit, enVocabTotal);
      $("#enVocabSummary").textContent = `共 ${enVocabTotal} 条 · 显示 ${from}–${to}`;
      $("#enVocabPageLabel").textContent = `第 ${Math.floor(enVocabOffset / enVocabLimit) + 1} / ${Math.max(1, Math.ceil(enVocabTotal / enVocabLimit))} 页`;
      $("#enVocabPrev").disabled = enVocabOffset <= 0;
      $("#enVocabNext").disabled = enVocabOffset + enVocabLimit >= enVocabTotal;
    } catch (e) { showErr(e.message); }
  }

  function enVocabRow(w) {
    const row = document.createElement("div");
    row.className = "card vocab-row";
    const cntClass = w.correct_count > 0 ? "pos" : w.correct_count < 0 ? "neg" : "";
    row.innerHTML = `
      <div class="main">
        <div class="word-line">${escapeHtml(w.word)}</div>
        <div class="sentence">${escapeHtml(w.sentence)}</div>
      </div>
      <div class="badge">${escapeHtml(w.level)}${w.topic ? " · " + escapeHtml(w.topic) : ""}</div>
      <div class="meta">
        <span class="cnt ${cntClass}">正确数 ${w.correct_count}</span>
        <span>
          <button class="edit" title="编辑">✏️</button>
          <button class="del" title="删除">🗑</button>
        </span>
      </div>`;
    row.querySelector(".edit").onclick = () => openEnVocabDialog(w);
    row.querySelector(".del").onclick = async () => {
      if (!confirm(`删除「${w.word}」？`)) return;
      try { await api(`/api/vocab/${w.id}`, { method: "DELETE" }); refreshEnVocab(); }
      catch (e) { showErr(e.message); }
    };
    return row;
  }

  function openEnVocabDialog(w) {
    enVocabEditingId = w ? w.id : null;
    $("#enVocabDlgTitle").textContent = w ? "✏️ 编辑单词" : "➕ 添加英语单词";
    $("#evDlgWord").value = w ? w.word : "";
    $("#evDlgSentence").value = w ? w.sentence : "";
    $("#evDlgLevel").value = w ? w.level : ($("#enVocabLevelFilter").value || "P6");
    $("#evDlgTopic").value = w ? w.topic : "";
    $("#evDlgCorrectCount").value = w ? w.correct_count : 0;
    $("#enVocabDlgErr").textContent = "";
    $("#enVocabDialog").showModal();
    $("#evDlgWord").focus();
  }

  $("#fabAddEnVocab").onclick = () => openEnVocabDialog(null);
  $("#evDlgCancel").onclick = () => $("#enVocabDialog").close();
  $("#evDlgSave").onclick = async () => {
    const payload = {
      language: "en",
      word: $("#evDlgWord").value.trim(),
      sentence: $("#evDlgSentence").value.trim(),
      level: $("#evDlgLevel").value,
      topic: $("#evDlgTopic").value.trim(),
      correctCount: Number($("#evDlgCorrectCount").value) || 0,
    };
    if (!payload.word || !payload.sentence) {
      $("#enVocabDlgErr").textContent = "单词和例句都是必填的";
      return;
    }
    try {
      if (enVocabEditingId) await api(`/api/vocab/${enVocabEditingId}`, { method: "PATCH", body: JSON.stringify(payload) });
      else await api("/api/vocab", { method: "POST", body: JSON.stringify(payload) });
      $("#enVocabDialog").close();
      refreshEnVocab();
    } catch (e) { $("#enVocabDlgErr").textContent = e.message; }
  };
  $("#enVocabSearch").addEventListener("keydown", (e) => { if (e.key === "Enter") { enVocabOffset = 0; refreshEnVocab(); } });
  $("#enVocabLevelFilter").onchange = () => { enVocabOffset = 0; refreshEnVocab(); };
  $("#enVocabPrev").onclick = () => { enVocabOffset = Math.max(0, enVocabOffset - enVocabLimit); refreshEnVocab(); };
  $("#enVocabNext").onclick = () => { enVocabOffset = enVocabOffset + enVocabLimit; refreshEnVocab(); };
```

- [ ] **Step 7: Wire the tab click handler and role-visibility**

Find (near the bottom of the script, search for `$("#tabVocab").onclick`):

```js
    $("#tabVocab").onclick = () => setTab("vocab");
    $("#tabVocab").hidden = role !== "admin"; // 生词库：仅家长可见
```

Add immediately after:

```js
    $("#tabEnVocab").onclick = () => setTab("enVocab");
    $("#tabEnVocab").hidden = role !== "admin"; // 英语听写词库：仅家长可见
```

Find (search for `$("#fabAddVocab").hidden = true;` inside whatever function hides all FABs on role change/logout):

```js
    $("#fabAddVocab").hidden = true;
```

Add immediately after:

```js
    $("#fabAddEnVocab").hidden = true;
```

- [ ] **Step 8: Manual verification**

There's no automated test for the admin page. Verify by hand:

1. Start (or reuse) the scratch server from Task 4's verification: `DB_PATH=/tmp/endict-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node backend/server.js`
2. Open `http://127.0.0.1:2099/admin` in a browser, enter PIN `1234`.
3. Confirm a new "🔤 英语听写词库" tab appears next to "📚 生词库".
4. Click it — should show "没有符合条件的单词" (empty state) if Task 4's test rows were cleaned up.
5. Click the ＋ FAB, fill in word "test", sentence "This is a test.", level P6, topic "Testing" → Save. Confirm the row appears with a "P6 · Testing" badge and "正确数 0".
6. Click ✏️ on that row, change the sentence, Save — confirm it updates in place.
7. Click 🗑, confirm — row disappears.
8. Switch back to "📚 生词库" — confirm it's completely unaffected (still shows only Chinese words, filters still work).

- [ ] **Step 9: Commit**

```bash
git add backend/admin.html
git commit -m "feat(admin): add English dictation word-bank tab"
```

---

### Task 7: Admin UI — make the shared history/grading dialog language-aware

**Files:**
- Modify: `backend/admin.html` (`dictSessionRow`, `gradeItemRow` — both in the existing 听写记录 section)

**Interfaces:**
- Consumes: `session.language` and `item.character`/`item.pinyin` possibly being `""` (English rows) from the endpoints touched in Tasks 4-5.
- Produces: no API change — purely a rendering adjustment so one shared history/grading UI reads correctly for both languages instead of duplicating it.

- [ ] **Step 1: Add a language badge + icon to `dictSessionRow`**

Find:

```js
  function dictSessionRow(s) {
    const row = document.createElement("div");
    row.className = "card dict-session";
    const when = new Date((s.completed_at || s.created_at).replace(" ", "T") + "Z");
    let badge, sub;
    if (s.status === "pending_grading") {
      badge = '<div class="badge cnt">🔔 待批改</div>';
      sub = `完成于 ${when.toLocaleString()}`;
    } else if (s.status === "graded") {
      badge = `<div class="badge">✅ ${s.correctCount}/${s.itemCount} 对</div>`;
      sub = `完成于 ${when.toLocaleString()}`;
    } else {
      badge = '<div class="badge parent">⏳ 进行中</div>';
      sub = "孩子还没有做完这次听写";
      row.style.opacity = ".6";
    }
    row.innerHTML = `
      <div class="icon">📝</div>
      <div class="info">
        <div class="count">${s.itemCount} 个词</div>
        <div class="when">${sub}</div>
      </div>
      ${badge}
      <button class="del" title="删除这条听写记录">🗑</button>`;
```

Replace with:

```js
  function dictSessionRow(s) {
    const row = document.createElement("div");
    row.className = "card dict-session";
    const when = new Date((s.completed_at || s.created_at).replace(" ", "T") + "Z");
    const isEn = s.language === "en";
    let badge, sub;
    if (s.status === "pending_grading") {
      badge = '<div class="badge cnt">🔔 待批改</div>';
      sub = `完成于 ${when.toLocaleString()}`;
    } else if (s.status === "graded") {
      badge = `<div class="badge">✅ ${s.correctCount}/${s.itemCount} 对</div>`;
      sub = `完成于 ${when.toLocaleString()}`;
    } else {
      badge = '<div class="badge parent">⏳ 进行中</div>';
      sub = "孩子还没有做完这次听写";
      row.style.opacity = ".6";
    }
    row.innerHTML = `
      <div class="icon">${isEn ? "🔤" : "📝"}</div>
      <div class="info">
        <div class="count">${isEn ? '<span class="lang-tag">EN</span> ' : ""}${s.itemCount} 个词</div>
        <div class="when">${sub}</div>
      </div>
      ${badge}
      <button class="del" title="删除这条听写记录">🗑</button>`;
```

- [ ] **Step 2: Make `gradeItemRow` skip the empty character/pinyin gracefully**

Find:

```js
  function gradeItemRow(it, readOnly) {
    const row = document.createElement("div");
    row.className = "grade-item";
    row.innerHTML = `
      <div class="seq">${it.seq}</div>
      <div class="char">${escapeHtml(it.character)}</div>
      <div class="info">
        <div class="word-line">${escapeHtml(it.word)}<span class="pinyin">${escapeHtml(it.pinyin)}</span></div>
        <div class="sentence">${escapeHtml(it.sentence)}</div>
      </div>
      <div class="grade-toggle">
        <button class="ok" title="写对了" ${readOnly ? "disabled" : ""}>✓</button>
        <button class="bad" title="写错了" ${readOnly ? "disabled" : ""}>✗</button>
      </div>`;
```

Replace with:

```js
  function gradeItemRow(it, readOnly) {
    const row = document.createElement("div");
    row.className = "grade-item";
    // English rows have no character/pinyin (see Task 4's schema notes) — the server
    // sends them as empty strings, not null, so this is a plain truthiness check.
    const charHtml = it.character ? `<div class="char">${escapeHtml(it.character)}</div>` : "";
    const pinyinHtml = it.pinyin ? `<span class="pinyin">${escapeHtml(it.pinyin)}</span>` : "";
    row.innerHTML = `
      <div class="seq">${it.seq}</div>
      ${charHtml}
      <div class="info">
        <div class="word-line">${escapeHtml(it.word)}${pinyinHtml}</div>
        <div class="sentence">${escapeHtml(it.sentence)}</div>
      </div>
      <div class="grade-toggle">
        <button class="ok" title="写对了" ${readOnly ? "disabled" : ""}>✓</button>
        <button class="bad" title="写错了" ${readOnly ? "disabled" : ""}>✗</button>
      </div>`;
```

- [ ] **Step 3: Add the `.lang-tag` CSS**

Find the `.grade-item .word-line .pinyin` rule (used as the anchor point):

```css
  .grade-item .word-line .pinyin { font-weight:400; color:var(--muted); font-size:12px; margin-left:6px; }
```

Add immediately after:

```css
  .lang-tag { display:inline-block; font-size:10px; font-weight:700; letter-spacing:.03em; background:#eff6ff; color:#1d4ed8; border-radius:5px; padding:1px 5px; margin-right:4px; vertical-align:1px; }
```

- [ ] **Step 4: Manual verification**

This needs a real graded/pending English session, which doesn't exist until Task 12 seeds words and Task 10's macOS runner is used once. Defer full visual verification to the end-to-end check in Task 13; for now, confirm the file still parses and the *existing Chinese* grading flow is visually unchanged:

1. With the scratch server running, open `http://127.0.0.1:2021/admin` (or `:2099` if still using the scratch port), go to "听写记录".
2. Confirm existing Chinese sessions still render exactly as before (📝 icon, no stray "EN" tag, character+pinyin still shown in the grade dialog).

- [ ] **Step 5: Commit**

```bash
git add backend/admin.html
git commit -m "feat(admin): make dictation history/grading language-aware"
```

---

### Task 8: macOS — `APIClient.swift` additions

**Files:**
- Modify: `macos-app/Sources/KidReminder/APIClient.swift`

**Interfaces:**
- Produces: `func startEnglishDictation() async throws -> DictationSession` — POSTs `{"language":"en"}`.
- Produces: `func dictationSessions(status: String? = nil, language: String? = nil) async throws -> [DictationSessionSummary]` — extends the existing method; every current call site (which passes only `status:`) keeps compiling and behaving identically since `language` defaults to `nil` (omitted from the query string).

- [ ] **Step 1: Extend `dictationSessions`**

Find:

```swift
    /// Session history — used by DictationHistoryView so the kid can review their own
    /// graded results. `status` filters (e.g. "graded"); omit for full history.
    func dictationSessions(status: String? = nil) async throws -> [DictationSessionSummary] {
        var path = "/api/dictation/sessions"
        if let status { path += "?status=\(status)" }
        let data = try await request(path)
        return try JSONDecoder().decode(DictationSessionListResponse.self, from: data).sessions
    }
```

Replace with:

```swift
    /// Session history — used by DictationHistoryView so the kid can review their own
    /// graded results. `status` filters (e.g. "graded"); `language` filters "zh"/"en"
    /// (used by EnglishDictationView; the Chinese DictationView omits it, same as
    /// before this parameter existed). Omit both for full history.
    func dictationSessions(status: String? = nil, language: String? = nil) async throws -> [DictationSessionSummary] {
        var items: [URLQueryItem] = []
        if let status { items.append(URLQueryItem(name: "status", value: status)) }
        if let language { items.append(URLQueryItem(name: "language", value: language)) }
        var comps = URLComponents()
        comps.queryItems = items
        let path = "/api/dictation/sessions" + (comps.percentEncodedQuery.map { "?\($0)" } ?? "")
        let data = try await request(path)
        return try JSONDecoder().decode(DictationSessionListResponse.self, from: data).sessions
    }
```

- [ ] **Step 2: Add `startEnglishDictation()`**

Find (`startDictation()`, to insert right after):

```swift
    func startDictation() async throws -> DictationSession {
        let data = try await request("/api/dictation/sessions", method: "POST", body: Data("{}".utf8))
        return try JSONDecoder().decode(DictationSession.self, from: data)
    }
```

Add immediately after:

```swift

    /// Same endpoint as `startDictation()`, scoped to the English word bank
    /// (`vocab_words.language = 'en'`) via the request body.
    func startEnglishDictation() async throws -> DictationSession {
        let data = try await request("/api/dictation/sessions", method: "POST", body: Data(#"{"language":"en"}"#.utf8))
        return try JSONDecoder().decode(DictationSession.self, from: data)
    }
```

- [ ] **Step 3: Build**

```bash
cd macos-app
swift build 2>&1 | tail -30
```

Expected: `Build complete!` with no new errors (pre-existing warnings in unrelated files are fine — this repo has some already, e.g. in `CalendarView.swift`/`DictationAudioPlayer.swift`).

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/KidReminder/APIClient.swift
git commit -m "feat(macos): add English dictation API client methods"
```

---

### Task 9: macOS — `EnglishDictationSessionDetailView.swift`

**Files:**
- Create: `macos-app/Sources/KidReminder/EnglishDictationSessionDetailView.swift`

**Interfaces:**
- Consumes: `APIClient.dictationSessionDetail(id:) -> DictationSessionDetail` (existing, unchanged — `DictationSessionDetailItem.character`/`.pinyin` will just be `""` for English rows, per Task 4).
- Produces: `struct EnglishDictationSessionDetailView: View { let sessionId: Int }` — used by `EnglishDictationView` (Task 11).

- [ ] **Step 1: Create the file**

This mirrors `DictationSessionDetailView.swift` (read in full during planning) with the character/pinyin line removed and copy changed to "英语听写详情":

```swift
import SwiftUI

/// One graded English dictation session's per-word ✓/✗ breakdown — the English
/// counterpart to `DictationSessionDetailView`, minus the character/pinyin line
/// (English `vocab_words` rows store those as empty strings; this view just
/// never renders them, rather than showing blank UI for an empty string).
struct EnglishDictationSessionDetailView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let sessionId: Int

    private enum LoadState {
        case loading
        case loaded(DictationSessionDetail)
        case error(String)
    }
    @State private var state: LoadState = .loading

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle(title)
            .frame(minWidth: 420, minHeight: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
    }

    private var title: String {
        guard case .loaded(let detail) = state else { return "英语听写详情" }
        let correct = detail.items.filter { $0.result == "correct" }.count
        return "英语听写详情（\(correct)/\(detail.items.count) 对）"
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case .error(let message):
            ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .loaded(let detail):
            List(detail.items) { item in
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: DictationSessionDetailItem) -> some View {
        let isCorrect = item.result == "correct"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.word).font(.headline)
                Text(item.sentence).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isCorrect ? .green : .red)
                .font(.title3)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        do {
            let detail = try await api.dictationSessionDetail(id: sessionId)
            state = .loaded(detail)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd macos-app && swift build 2>&1 | tail -30
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/KidReminder/EnglishDictationSessionDetailView.swift
git commit -m "feat(macos): add EnglishDictationSessionDetailView"
```

---

### Task 10: macOS — `EnglishDictationRunnerView.swift`

**Files:**
- Create: `macos-app/Sources/KidReminder/EnglishDictationRunnerView.swift`

**Interfaces:**
- Consumes: `APIClient.startEnglishDictation()`, `APIClient.dictationAudioURL(wordId:)` (existing, unchanged), `APIClient.completeDictation(sessionId:)` (existing, unchanged), `DictationAudioPlayer` (existing, unchanged — reused as-is).
- Produces: `struct EnglishDictationRunnerView: View {}` — zero parameters (always the graded weakest-first set; no custom-list source, unlike `DictationRunnerView`).

- [ ] **Step 1: Create the file**

This mirrors `DictationRunnerView.swift`'s `.random` path only — no `DictationSource`-equivalent enum, since there's exactly one source:

```swift
import SwiftUI

/// 🔤 The English dictation runner — always the graded 30-word weakest-first set
/// (no custom-list equivalent yet, unlike the Chinese `DictationRunnerView`). The
/// app reads each word + example sentence aloud via server-side TTS (English
/// voice — see `ensureDictationAudio`'s language branch); the screen never shows
/// the word text, same rule as the Chinese version.
struct EnglishDictationRunnerView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var player = DictationAudioPlayer()

    private enum Phase: Equatable {
        case loading
        case running(index: Int)
        case finishing
        case done
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var clips: [URL] = []
    @State private var sessionId: Int?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("🔤 英语听写")
            .padding()
            .frame(minWidth: 460, minHeight: 460)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { player.stop(); dismiss() }
                }
            }
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("正在生成听写表…")
        case .running(let index):
            runningView(index: index)
        case .finishing:
            ProgressView("正在提交…")
        case .done:
            doneView
        case .error(let message):
            ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
                description: Text(message))
        }
    }

    // MARK: - running

    private func runningView(index: Int) -> some View {
        let total = clips.count
        let isLast = index >= total - 1
        return VStack(spacing: 22) {
            progressHeader(index: index, total: total)

            Spacer(minLength: 0)

            Group {
                if player.isLoading {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: player.isPlaying ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
            }
            .frame(height: 72)

            Text(player.isLoading ? "准备中，马上就好…" : player.isPlaying ? "正在朗读…" : "写完了吗？")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Button("🔁 重听") { playCurrent(index: index) }
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                Button(isLast ? "✅ 完成" : "➡️ 下一题") {
                    if isLast { Task { await finish() } }
                    else { advance(to: index + 1) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(player.isBusy)
        }
        .task(id: index) { if index == 0 { playCurrent(index: index) } }
    }

    private func progressHeader(index: Int, total: Int) -> some View {
        VStack(spacing: 8) {
            Text("第 \(index + 1) 题 / 共 \(total) 题")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: Double(index + 1), total: Double(max(total, 1)))
                .frame(maxWidth: 320)
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("听写完成！").font(.title2).bold()
            Text("已经提交给家长了，等家长批改后正确数就会更新。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("关闭") { player.stop(); dismiss() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - actions

    private func load() async {
        do {
            let session = try await api.startEnglishDictation()
            guard !session.items.isEmpty else {
                phase = .error("英语听写词库还是空的，请先在网页端添加单词。"); return
            }
            sessionId = session.sessionId
            clips = session.items.compactMap { api.dictationAudioURL(wordId: $0.wordId) }
            guard !clips.isEmpty else {
                phase = .error("没能准备好朗读内容，请检查服务器地址。"); return
            }
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func playCurrent(index: Int) {
        guard clips.indices.contains(index) else { return }
        player.play(url: clips[index])
    }

    private func advance(to index: Int) {
        phase = .running(index: index)
        playCurrent(index: index)
    }

    private func finish() async {
        player.stop()
        guard let sessionId else { phase = .done; return }
        phase = .finishing
        do {
            try await api.completeDictation(sessionId: sessionId)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd macos-app && swift build 2>&1 | tail -30
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/KidReminder/EnglishDictationRunnerView.swift
git commit -m "feat(macos): add EnglishDictationRunnerView"
```

---

### Task 11: macOS — `EnglishDictationView.swift` + sidebar wiring

**Files:**
- Create: `macos-app/Sources/KidReminder/EnglishDictationView.swift`
- Modify: `macos-app/Sources/KidReminder/ContentView.swift`

**Interfaces:**
- Consumes: `EnglishDictationRunnerView()`, `EnglishDictationSessionDetailView(sessionId:)` (Tasks 9-10), `APIClient.dictationSessions(status:language:)` (Task 8).
- Produces: `struct EnglishDictationView: View {}`, registered as `SidebarItem.englishDictation`.

- [ ] **Step 1: Create `EnglishDictationView.swift`**

Single-column version of `DictationView.swift` (no 自定义听写表 column — out of scope, see Global Constraints):

```swift
import SwiftUI

/// 🔤 英语听写 — the browser screen. Single column (unlike the Chinese `DictationView`,
/// which also has a 自定义听写表 column — that's out of scope for English v1, see the
/// plan this was built from). Actually *doing* a dictation happens in
/// `EnglishDictationRunnerView`, presented as a sheet.
struct EnglishDictationView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var sessions: [DictationSessionSummary] = []
    @State private var historyError: String?
    @State private var loadingHistory = true

    private enum SheetDestination: Identifiable {
        case run
        case sessionDetail(Int)

        var id: String {
            switch self {
            case .run: return "run"
            case .sessionDetail(let id): return "session-\(id)"
            }
        }
    }
    @State private var activeSheet: SheetDestination?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("英语听写")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $activeSheet) { sheet in
                sheetContent(for: sheet)
            }
    }

    @ViewBuilder
    private func sheetContent(for sheet: SheetDestination) -> some View {
        switch sheet {
        case .run:
            NavigationStack { EnglishDictationRunnerView() }
        case .sessionDetail(let id):
            NavigationStack { EnglishDictationSessionDetailView(sessionId: id) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if settings.host.isEmpty || settings.pin.isEmpty {
            ContentUnavailableView("Not connected",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Enter the server address and PIN in Settings."))
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                historyColumn
            }
            .task { await loadHistory() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("🔤").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("英语听写").font(.title3.bold())
                Text("会挑 30 个最需要练习的单词，App 念出来，写在纸上就好。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("🎲 开始英语听写") { activeSheet = .run }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("📋 听写记录")
            Group {
                if loadingHistory {
                    centered { ProgressView() }
                } else if let historyError {
                    centered {
                        ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                            description: Text(historyError))
                    }
                } else if sessions.isEmpty {
                    centered {
                        ContentUnavailableView("还没有批改好的听写", systemImage: "checkmark.circle",
                            description: Text("做完听写后，等家长在网页端批改，结果就会显示在这里。"))
                    }
                } else {
                    List(sessions) { session in
                        Button { activeSheet = .sessionDetail(session.id) } label: {
                            historyRow(session)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func historyRow(_ s: DictationSessionSummary) -> some View {
        let total = s.itemCount ?? 0
        let correct = s.correctCount ?? 0
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.completedAt ?? s.createdAt).font(.subheadline)
                Text("\(total) 个词").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("✅ \(correct)/\(total)")
                .font(.callout).bold()
                .monospacedDigit()
                .foregroundStyle(total > 0 && correct == total ? .green : .primary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func columnHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Graded sessions only — same rule as the Chinese DictationView: grading happens
    /// in the parent's web admin, and an ungraded session's detail would reveal word
    /// text this feature is built to keep off the kid's screen until then.
    private func loadHistory() async {
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            sessions = try await api.dictationSessions(status: "graded", language: "en")
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Register the sidebar entry**

In `macos-app/Sources/KidReminder/ContentView.swift`, find:

```swift
enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today"
    case calendar = "Calendar"
    case countdown = "Countdown"
    case stickers = "Stickers"
    case dictation = "听写"
    case english = "英语错题"
    case science = "科学"
    case englishPaper = "英语试卷"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: return "checklist"
        case .calendar: return "calendar"
        case .countdown: return "timer"
        case .stickers: return "star.circle.fill"
        case .dictation: return "speaker.wave.2.fill"
        case .english: return "text.book.closed.fill"
        case .science: return "flask.fill"
        case .englishPaper: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}
```

Replace with:

```swift
enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today"
    case calendar = "Calendar"
    case countdown = "Countdown"
    case stickers = "Stickers"
    case dictation = "听写"
    case englishDictation = "英语听写"
    case english = "英语错题"
    case science = "科学"
    case englishPaper = "英语试卷"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: return "checklist"
        case .calendar: return "calendar"
        case .countdown: return "timer"
        case .stickers: return "star.circle.fill"
        case .dictation: return "speaker.wave.2.fill"
        case .englishDictation: return "textformat.abc"
        case .english: return "text.book.closed.fill"
        case .science: return "flask.fill"
        case .englishPaper: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}
```

Then find:

```swift
            case .dictation: DictationView()
            case .english: EnglishPracticeView()
```

Replace with:

```swift
            case .dictation: DictationView()
            case .englishDictation: EnglishDictationView()
            case .english: EnglishPracticeView()
```

- [ ] **Step 3: Build**

```bash
cd macos-app && swift build 2>&1 | tail -30
```

Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/KidReminder/EnglishDictationView.swift macos-app/Sources/KidReminder/ContentView.swift
git commit -m "feat(macos): add EnglishDictationView + sidebar entry"
```

---

### Task 12: Seed 40 starter English dictation words

**Files:**
- Create: `tools/english-dictation/seed-words.js`

**Interfaces:**
- Consumes: `POST /api/vocab` (Task 4) via plain `fetch`, same pattern as this repo's other `tools/*/import*.js` scripts — no DB driver dependency, works against local scratch server or the live Mac Mini identically.
- Produces: 40 `vocab_words` rows with `language = 'en'`.

- [ ] **Step 1: Create the script**

```js
#!/usr/bin/env node
// One-off: seed the English dictation word bank with a curated 40-word starter set.
// Run against a scratch DB first (see the plan this came from), then against the
// live Mac Mini once verified. Idempotent-ish: re-running will 409 on duplicates
// (same word+level), which this script just logs and skips.
//
// Usage: HOST=127.0.0.1 PORT=2099 ADMIN_PIN=1234 node tools/english-dictation/seed-words.js

const HOST = process.env.HOST || "127.0.0.1";
const PORT = process.env.PORT || "2021";
const ADMIN_PIN = process.env.ADMIN_PIN;
if (!ADMIN_PIN) {
  console.error("ADMIN_PIN env var is required");
  process.exit(1);
}

const WORDS = [
  ["handkerchief", "She folded the handkerchief neatly and put it in her pocket.", "Silent Letters"],
  ["knowledge", "Reading gives you a lot of useful knowledge.", "Silent Letters"],
  ["foreign", "My uncle works for a foreign company in Japan.", "Silent Letters"],
  ["vehicle", "The fire engine is a very large vehicle.", "Silent Letters"],
  ["scissors", "Please use the scissors carefully when you cut the paper.", "Silent Letters"],
  ["receipt", "Keep the receipt in case you need to return the item.", "Silent Letters"],
  ["island", "Sentosa is a small island near Singapore.", "Silent Letters"],
  ["listen", "You need to listen carefully during the exam instructions.", "Silent Letters"],
  ["climb", "The children love to climb the tree in the park.", "Silent Letters"],
  ["Wednesday", "Our school holds assembly every Wednesday morning.", "Silent Letters"],
  ["necessary", "It is necessary to bring an umbrella when it rains.", "Double Letters"],
  ["occurred", "The accident occurred just before the traffic light.", "Double Letters"],
  ["beginning", "The story has an exciting beginning.", "Double Letters"],
  ["embarrassed", "He felt embarrassed when he forgot his lines.", "Double Letters"],
  ["committee", "The committee will meet on Friday to plan the event.", "Double Letters"],
  ["accommodate", "The hotel can accommodate up to two hundred guests.", "Double Letters"],
  ["disappear", "The magician made the coin disappear.", "Double Letters"],
  ["immediately", "Please come to the office immediately.", "Double Letters"],
  ["successful", "Her presentation was very successful.", "Double Letters"],
  ["recommend", "I would recommend this book to every student.", "Double Letters"],
  ["separate", "Please keep your wet clothes in a separate bag.", "Tricky Vowels"],
  ["definitely", "I will definitely finish my homework tonight.", "Tricky Vowels"],
  ["business", "My father runs a small business near our house.", "Tricky Vowels"],
  ["government", "The government announced a new policy today.", "Tricky Vowels"],
  ["environment", "We should all take care of the environment.", "Tricky Vowels"],
  ["February", "My birthday is in February.", "Tricky Vowels"],
  ["guarantee", "The shop cannot guarantee that the toy will not break.", "Tricky Vowels"],
  ["rhythm", "The drummer kept a steady rhythm throughout the song.", "Tricky Vowels"],
  ["responsible", "Every pupil is responsible for keeping the classroom clean.", "Word Endings"],
  ["existence", "Scientists are still studying the existence of new planets.", "Word Endings"],
  ["maintenance", "The lift is closed today for maintenance.", "Word Endings"],
  ["believe", "I believe you can do well if you try your best.", "ie vs ei"],
  ["receive", "You will receive your results next Monday.", "ie vs ei"],
  ["weird", "It felt weird to be back in school after the holidays.", "ie vs ei"],
  ["neighbour", "Our neighbour waters our plants when we go on holiday.", "ie vs ei"],
  ["unnecessary", "Try not to make unnecessary noise in the library.", "Prefixes"],
  ["disappoint", "He did not want to disappoint his parents.", "Prefixes"],
  ["irregular", "This verb has an irregular past tense.", "Prefixes"],
  ["though", "It was raining, though the sky looked bright.", "-ough Family"],
  ["through", "The ball rolled through the small gap in the fence.", "-ough Family"],
];

async function main() {
  let created = 0, skipped = 0, failed = 0;
  for (const [word, sentence, topic] of WORDS) {
    const res = await fetch(`http://${HOST}:${PORT}/api/vocab`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Admin-Pin": ADMIN_PIN },
      body: JSON.stringify({ language: "en", word, sentence, level: "P6", topic }),
    });
    if (res.status === 201) {
      created++;
    } else if (res.status === 409) {
      skipped++;
      console.log(`skip (already exists): ${word}`);
    } else {
      failed++;
      console.error(`FAILED (${res.status}): ${word} — ${await res.text()}`);
    }
  }
  console.log(`\ncreated=${created} skipped=${skipped} failed=${failed}`);
  process.exit(failed ? 1 : 0);
}

main();
```

- [ ] **Step 2: Run against the scratch server**

```bash
kill %1 2>/dev/null; sleep 0.5   # stop any leftover scratch server from earlier tasks
cd backend
DB_PATH=/tmp/endict-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5
cd ..
HOST=127.0.0.1 PORT=2099 ADMIN_PIN=1234 node tools/english-dictation/seed-words.js
```

Expected: `created=40 skipped=0 failed=0`.

- [ ] **Step 3: Verify a full session can now be generated**

```bash
curl -s -X POST -H "Content-Type: application/json" -d '{"language":"en"}' http://127.0.0.1:2099/api/dictation/sessions | python3 -c "import json,sys; d=json.load(sys.stdin); print('sessionId', d['sessionId'], 'items', len(d['items']))"
```

Expected: `sessionId <n> items 30` (30, not 40 — the query caps at `LIMIT 30`, same as Chinese). Then fetch one clip to confirm English TTS voice branch fires without error:

```bash
sqlite3 /tmp/endict-test/kidreminder.db "SELECT id FROM vocab_words WHERE language='en' LIMIT 1;"
curl -s -o /tmp/endict-test/en-word.wav -w "%{http_code}\n" "http://127.0.0.1:2099/dictation-audio/<ID>.wav"
file /tmp/endict-test/en-word.wav
```

Expected: `200`, valid WAV file. Then stop the scratch server: `kill %1`.

- [ ] **Step 4: Commit**

```bash
git add tools/english-dictation/seed-words.js
git commit -m "tools: seed 40 starter English dictation words"
```

---

### Task 13: Version bump, deploy, and end-to-end verification

**Files:**
- Modify: `macos-app/build.sh` (version bump)

**Interfaces:** None — this is the release/deploy task.

- [ ] **Step 1: Bump the macOS app version**

In `macos-app/build.sh`, find `CFBundleShortVersionString` and bump the minor version per this repo's convention (check the current value first — e.g. `git log --oneline -5 -- macos-app/build.sh` or `grep CFBundleShortVersionString macos-app/build.sh` — bump from whatever X.Y.Z is currently there to X.(Y+1).0, matching how this repo bumped 1.15→1.16 for the last feature-sized addition).

- [ ] **Step 2: Build the release .app**

```bash
cd macos-app
./build.sh
```

Expected: ends with `=== done: build/KidReminder.app ===`.

- [ ] **Step 3: Commit the version bump**

```bash
git add macos-app/build.sh
git commit -m "macos-app: bump version to <X.Y.0>"
```

- [ ] **Step 4: Deploy the backend to the Mac Mini**

```bash
ssh robot@192.168.0.12 'cd /Users/robot/kidreminder && cp server.js server.js.bak-endict-$(date +%Y%m%d-%H%M%S) && cp admin.html admin.html.bak-endict-$(date +%Y%m%d-%H%M%S)'
scp backend/server.js backend/admin.html robot@192.168.0.12:/Users/robot/kidreminder/
ssh robot@192.168.0.12 '/Users/robot/nodejs/bin/node --check /Users/robot/kidreminder/server.js && echo "syntax ok"'
ssh robot@192.168.0.12 "sqlite3 /Users/robot/kidreminder/kidreminder.db 'SELECT COUNT(*), SUM(correct_count) FROM vocab_words;'"  # note this BEFORE restart
ssh robot@192.168.0.12 'launchctl kickstart -k gui/$(id -u)/com.kidreminder.server && sleep 1.5 && curl -s http://127.0.0.1:2021/api/health'
ssh robot@192.168.0.12 "sqlite3 /Users/robot/kidreminder/kidreminder.db \"SELECT COUNT(*) FROM pragma_table_info('vocab_words') WHERE name='topic';\""
ssh robot@192.168.0.12 "sqlite3 /Users/robot/kidreminder/kidreminder.db 'SELECT COUNT(*), SUM(correct_count) FROM vocab_words;'"  # confirm unchanged after restart
```

Expected: syntax ok; health check `{"ok":true,...}`; `topic` column exists; row count/sum identical before and after (schema-only change, no data touched).

- [ ] **Step 5: Seed the live word bank**

```bash
HOST=192.168.0.12 PORT=2021 ADMIN_PIN=<the real admin pin> node tools/english-dictation/seed-words.js
```

Expected: `created=40 skipped=0 failed=0`.

- [ ] **Step 6: Install the app and do one real end-to-end pass**

1. Copy `macos-app/build/KidReminder.app` to the kid's MacBook (or run it locally if testing on this Mac, per how prior features in this project were spot-checked).
2. Open the app, go to the new "英语听写" sidebar tab.
3. Click "🎲 开始英语听写" — confirm it generates a 30-word set and starts reading the first word + sentence aloud in an English voice (not Chinese).
4. Click through a few words, then "✅ 完成".
5. In `admin.html` → "听写记录", confirm the new session shows a 🔤 icon and "EN" tag, in "🔔 待批改" status.
6. Open it, grade a few words ✓/✗, submit.
7. Back in the app, confirm the graded session appears in "英语听写" → "听写记录" with the right ✅ X/Y count, and its detail view shows word+sentence with no blank pinyin line.
8. In `admin.html` → "🔤 英语听写词库", confirm the graded words' "正确数" updated (+1 for correct, -1 for incorrect).
9. Switch to "📚 生词库" and "📝 听写记录" (the Chinese tabs) — confirm both are completely unaffected by everything above.

- [ ] **Step 7: Tag the release**

```bash
git push origin main
git tag -a v<X.Y.0> -m "v<X.Y.0> -- English dictation"
git push origin v<X.Y.0>
gh release create v<X.Y.0> --title "v<X.Y.0> — 英语听写" --notes "英文单词听写：家长在网页端建英语单词库（单词+例句+分类），孩子在 App 里听写、系统自动批改队列，家长批改后正确率自动统计，跟中文听写体验一致。" macos-app/build/KidReminder.zip
```

(Zip the app first if the release step needs the asset: `cd macos-app/build && rm -f KidReminder.zip && zip -qr KidReminder.zip KidReminder.app`.)

---

## Self-Review

**Spec coverage:** Every element of the Architecture section is implemented: schema reuse (Task 1), TTS language branch (Task 2), session scoping (Task 3), CRUD generalization (Task 4), history filtering (Task 5), admin word-bank UI (Task 6), admin history/grading language-awareness (Task 7), macOS client methods (Task 8), macOS UI trio (Tasks 9-11), real content (Task 12), and a real deploy + end-to-end pass (Task 13). Backward compatibility is explicitly verified at the end of every backend task (Tasks 1-5) before moving on.

**Placeholder scan:** No task step says "add appropriate X" without showing the actual code/command. The one deliberately-scoped-down item (40 words instead of the full ~189-word spelling list) is called out explicitly in Global Constraints as a scope decision, not left as an implicit gap.

**Type consistency:** `ensureDictationAudio(wordId, word, sentence, language)`'s signature is introduced once (Task 2) and every call site update in that same task uses the new 4-arg form. `dictationSessions(status:language:)` is introduced once (Task 8) and consumed with matching argument labels in Task 11. `startEnglishDictation() -> DictationSession` reuses the existing `DictationSession`/`DictationItemRef` Codable types verbatim — no new Swift model types were needed anywhere in this plan, which was confirmed during planning (English `vocab_words` rows return `character`/`pinyin`/`lesson` as empty strings, not nulls, so the existing non-optional `String` fields on `DictationSessionDetailItem` decode fine unchanged).
