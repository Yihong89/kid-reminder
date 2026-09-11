# English Paper Session Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make English Paper (epaper) practice sessions resumable, so a kid who force-quits or crashes mid-paper doesn't strand an ungradeable, unrecoverable session — mirroring the resume logic Chinese 听写 already has, but going further: since redoing 75 questions is far more expensive than redoing 30 dictation words, the resumed session also reports which items are already answered, so the runner can jump straight to the first unanswered question instead of restarting from question 1.

**Architecture:** `POST /api/epaper/sessions` gains a resume check (same shape as dictation's, scoped by `paper_key` for paper mode / by mode alone for mistakes mode) that runs before the existing fresh-session-creation path. Both paths now tag every returned item with `answered: Bool`. The macOS runner (`EnglishPaperRunnerView`) uses that flag to compute which step to open on load instead of always `0`. A small admin-UI addition (`admin.html`) gives the parent a manual "mark as gradeable" escape hatch for the one case resume can't cover on its own: the kid abandons paper A and starts a *different* paper B while A is still `in_progress` (resume is intentionally scoped to the same `paper_key`, so it won't reattach to A).

**Tech Stack:** Node.js (`node:sqlite`, zero dependencies) backend; vanilla JS/HTML admin panel; SwiftUI macOS app (Swift Package Manager, no Xcode project).

**Spec:** No separate spec doc. This plan's Architecture section is the design, worked out in the conversation that produced it, directly motivated by a real production incident (2026-09-10): a kid's paper attempt (65/75 questions answered) was abandoned mid-session by an accidental app quit near the end, and three more empty/partial attempts piled up on top of it before anyone noticed — all four stuck `in_progress` and ungradeable until a parent manually called `/complete` on each one via the API.

## Global Constraints

- **Backward compatibility is non-negotiable** for every other epaper/dictation code path this plan doesn't touch. In particular: dictation's own resume logic (`POST /api/dictation/sessions`) is untouched — this plan only touches the epaper handler. The response shape for `POST /api/epaper/sessions` stays `{ sessionId, mode, items }`; the only change is one new field (`answered`) on each item, which is purely additive — any client code that doesn't read it is unaffected.
- **No test framework exists in this repo.** Verification is manual: run the backend against a **scratch copy** of the live DB (never the live DB directly — see project memory on the import-script naming incident for why), `curl` the endpoints, inspect with `sqlite3`; for Swift, `swift build` must succeed. **Do not deploy to the Mac Mini or push to `main` as part of executing this plan** — the human partner asked for the plan only, deployment happens in a later, separate step they'll explicitly ask for (the same two-phase pattern used for the English Dictation feature: write + locally verify now, deploy later on request).
- **Scoped-resume is a deliberate limitation, not a gap.** A paper-mode resume only reattaches to an `in_progress` session with the *same* `paper_key`. If the kid abandons paper A and starts paper B, A stays orphaned — Task 4's admin button is the intentional manual fallback for that case, not a bug to fix by, say, auto-completing every other in-progress session whenever a new one starts (that would silently grade a paper the kid might come back to five minutes later).
- **Mistakes-mode resume is scoped by mode alone** (there's exactly one relevant "current mistake set" concept, no per-paper distinction — same as how dictation's resume works, since dictation also has no per-paper concept).
- Today's four already-stranded sessions (ids 42-45, already manually completed via the API in this same conversation) are **not** this plan's concern — this plan prevents the *next* occurrence, it doesn't touch historical data.

---

## File Structure

- **Modify:** `backend/server.js` — `POST /api/epaper/sessions` gains resume-lookup + `answered` field on every returned item (both the resumed path and the fresh-creation path).
- **Modify:** `macos-app/Sources/KidReminder/Models.swift` — `EpaperSessionItem` gains `let answered: Bool`.
- **Modify:** `macos-app/Sources/KidReminder/EnglishPaperRunnerView.swift` — `start()` opens at the first step containing an unanswered item instead of always step `0`.
- **Modify:** `backend/admin.html` — `epaperSessionRow()` gains a "✅ 标记可批改" button on `in_progress` rows, calling the existing `/complete` endpoint (no new backend route needed for this — it already exists and is exactly what a parent needs here).

---

### Task 1: Backend — resume lookup + `answered` field in `POST /api/epaper/sessions`

**Files:**
- Modify: `backend/server.js:2617-2669` (the entire `POST /api/epaper/sessions` handler)

**Interfaces:**
- Consumes: existing tables `epaper_sessions`, `epaper_session_items`, `epaper_questions`, `epaper_item_points` — no schema change needed, every column this reads already exists.
- Produces: `POST /api/epaper/sessions` response items each gain `answered: Bool`. Resume path returns HTTP `200` (mirrors dictation's convention: `200` = resumed existing, `201` = created new — fresh-creation path keeps returning `201`, unchanged).

- [ ] **Step 1: Replace the handler**

Find the entire current handler (search for `pathname === "/api/epaper/sessions"` under the `POST` branch — there are two `/api/epaper/sessions` matches in the file, one `GET` and one `POST`; this is the `POST` one):

```js
    // --- start a practice set (open; the kid app calls this) ---------------------
    if (method === "POST" && pathname === "/api/epaper/sessions") {
      const body = await readBody(req);
      const paperKey = String(body.paperKey || "");
      const mistakesMode = body.mistakes === true;
      let qids, mode;
      if (paperKey) {
        const rows = db.prepare(
          "SELECT id FROM epaper_questions WHERE paper_key = ? ORDER BY paper_seq ASC"
        ).all(paperKey);
        if (!rows.length) return sendJSON(404, { error: "paper not found" });
        qids = rows.map((r) => r.id);
        mode = "paper";
      } else if (mistakesMode) {
        // Pick the 15 weakest (lowest correct_count) rather than dumping the
        // whole bank into one session — family found the full bank (which had
        // grown past 30 questions) too long to finish in one sitting
        // (2026-09-09). RANDOM() breaks ties among equally-weak questions so
        // the same 15 aren't picked every time; the Fisher-Yates below still
        // separately shuffles the *presentation* order of whichever 15 got picked.
        const rows = db.prepare(
          "SELECT id FROM epaper_questions WHERE in_mistake_bank = 1 ORDER BY correct_count ASC, RANDOM() ASC LIMIT 15"
        ).all();
        if (!rows.length) return sendJSON(400, { error: "错题本是空的，继续保持！" });
        qids = rows.map((r) => r.id);
        for (let i = qids.length - 1; i > 0; i--) {   // Fisher-Yates
          const j = Math.floor(Math.random() * (i + 1));
          [qids[i], qids[j]] = [qids[j], qids[i]];
        }
        mode = "mistakes";
      } else {
        return sendJSON(400, { error: "paperKey or mistakes is required" });
      }

      const sessionId = db.prepare("INSERT INTO epaper_sessions (mode, paper_key) VALUES (?, ?)")
        .run(mode, paperKey).lastInsertRowid;
      const items = [];
      qids.forEach((qid, idx) => {
        const itemId = db.prepare(
          "INSERT INTO epaper_session_items (session_id, question_id, seq) VALUES (?, ?, ?)"
        ).run(sessionId, qid, idx + 1).lastInsertRowid;
        const q = db.prepare("SELECT * FROM epaper_questions WHERE id = ?").get(qid);
        items.push({
          itemId: Number(itemId), seq: idx + 1, questionId: qid, section: q.section,
          questionType: q.question_type, context: q.context, passage: q.passage || "",
          prompt: q.prompt,
          options: q.options ? JSON.parse(q.options) : null, marks: q.marks, image: q.image,
        });
      });
      // correct_answer/explanation deliberately withheld until submit, same as
      // science withholds model_answer.
      return sendJSON(201, { sessionId: Number(sessionId), mode, items });
    }
```

Replace with:

```js
    // --- start a practice set (open; the kid app calls this) ---------------------
    // Resumes an existing in_progress session that matches the requested source
    // first (paper mode: same paper_key; mistakes mode: any in-progress mistakes
    // session) instead of always creating a new one — without this, a kid who
    // force-quits mid-paper leaves that session stranded in_progress forever
    // (ungradeable: the admin row for in_progress sessions isn't clickable), and
    // every subsequent "开始" press creates ANOTHER orphaned session on top of
    // it. Confirmed happening in production (2026-09-10): one paper attempt
    // abandoned at 65/75 answered spawned three more abandoned attempts before
    // anyone noticed, all stuck un-gradeable until a parent manually completed
    // them via the API. Mirrors dictation's existing resume logic (see
    // POST /api/dictation/sessions above) but goes further: dictation just
    // replays its word list from the top on resume (cheap — 30 words, and
    // re-submitting an already-answered word is idempotent); a 75-question
    // paper is too expensive to redo, so every resumed item also reports
    // whether it's already been answered, and the client
    // (EnglishPaperRunnerView) uses that to jump straight to the first
    // unanswered step instead of restarting from question 1.
    if (method === "POST" && pathname === "/api/epaper/sessions") {
      const body = await readBody(req);
      const paperKey = String(body.paperKey || "");
      const mistakesMode = body.mistakes === true;

      let existing;
      if (paperKey) {
        existing = db.prepare(
          "SELECT id FROM epaper_sessions WHERE status = 'in_progress' AND mode = 'paper' AND paper_key = ? ORDER BY created_at DESC LIMIT 1"
        ).get(paperKey);
      } else if (mistakesMode) {
        existing = db.prepare(
          "SELECT id FROM epaper_sessions WHERE status = 'in_progress' AND mode = 'mistakes' ORDER BY created_at DESC LIMIT 1"
        ).get();
      }
      if (existing) {
        const rows = db.prepare(`
          SELECT i.id itemId, i.seq, i.question_id questionId, q.section, q.question_type questionType,
                 q.context, q.passage, q.prompt, q.options, q.marks, q.image,
                 i.final_correct finalCorrect,
                 (SELECT COUNT(*) FROM epaper_item_points ip WHERE ip.item_id = i.id) pointCount
            FROM epaper_session_items i JOIN epaper_questions q ON q.id = i.question_id
           WHERE i.session_id = ? ORDER BY i.seq`).all(existing.id);
        const existingSession = db.prepare("SELECT mode FROM epaper_sessions WHERE id = ?").get(existing.id);
        const items = rows.map((it) => ({
          itemId: it.itemId, seq: it.seq, questionId: it.questionId, section: it.section,
          questionType: it.questionType, context: it.context, passage: it.passage || "",
          prompt: it.prompt, options: it.options ? JSON.parse(it.options) : null, marks: it.marks,
          image: it.image,
          // oeq "answered" = at least one mark point was auto-scored at submit
          // time (see the /submit handler below); mcq/fill_blank "answered" =
          // final_correct has been set. Both are set exactly once, at first
          // submit — matches how /submit's own idempotency check works.
          answered: it.questionType === "oeq" ? it.pointCount > 0 : it.finalCorrect !== null,
        }));
        return sendJSON(200, { sessionId: existing.id, mode: existingSession.mode, items });
      }

      let qids, mode;
      if (paperKey) {
        const rows = db.prepare(
          "SELECT id FROM epaper_questions WHERE paper_key = ? ORDER BY paper_seq ASC"
        ).all(paperKey);
        if (!rows.length) return sendJSON(404, { error: "paper not found" });
        qids = rows.map((r) => r.id);
        mode = "paper";
      } else if (mistakesMode) {
        // Pick the 15 weakest (lowest correct_count) rather than dumping the
        // whole bank into one session — family found the full bank (which had
        // grown past 30 questions) too long to finish in one sitting
        // (2026-09-09). RANDOM() breaks ties among equally-weak questions so
        // the same 15 aren't picked every time; the Fisher-Yates below still
        // separately shuffles the *presentation* order of whichever 15 got picked.
        const rows = db.prepare(
          "SELECT id FROM epaper_questions WHERE in_mistake_bank = 1 ORDER BY correct_count ASC, RANDOM() ASC LIMIT 15"
        ).all();
        if (!rows.length) return sendJSON(400, { error: "错题本是空的，继续保持！" });
        qids = rows.map((r) => r.id);
        for (let i = qids.length - 1; i > 0; i--) {   // Fisher-Yates
          const j = Math.floor(Math.random() * (i + 1));
          [qids[i], qids[j]] = [qids[j], qids[i]];
        }
        mode = "mistakes";
      } else {
        return sendJSON(400, { error: "paperKey or mistakes is required" });
      }

      const sessionId = db.prepare("INSERT INTO epaper_sessions (mode, paper_key) VALUES (?, ?)")
        .run(mode, paperKey).lastInsertRowid;
      const items = [];
      qids.forEach((qid, idx) => {
        const itemId = db.prepare(
          "INSERT INTO epaper_session_items (session_id, question_id, seq) VALUES (?, ?, ?)"
        ).run(sessionId, qid, idx + 1).lastInsertRowid;
        const q = db.prepare("SELECT * FROM epaper_questions WHERE id = ?").get(qid);
        items.push({
          itemId: Number(itemId), seq: idx + 1, questionId: qid, section: q.section,
          questionType: q.question_type, context: q.context, passage: q.passage || "",
          prompt: q.prompt,
          options: q.options ? JSON.parse(q.options) : null, marks: q.marks, image: q.image,
          answered: false,
        });
      });
      // correct_answer/explanation deliberately withheld until submit, same as
      // science withholds model_answer.
      return sendJSON(201, { sessionId: Number(sessionId), mode, items });
    }
```

- [ ] **Step 2: Verify against a scratch copy of the live DB**

```bash
mkdir -p /tmp/epaper-resume-test
scp -q robot@192.168.0.12:/Users/robot/kidreminder/kidreminder.db /tmp/epaper-resume-test/kidreminder.db
cd backend
lsof -i :2099 -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2}' | xargs -r kill
DB_PATH=/tmp/epaper-resume-test/kidreminder.db PORT=2099 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5
curl -s http://127.0.0.1:2099/api/health

# Start a fresh paper session, confirm every item has answered:false
curl -s -X POST -H "Content-Type: application/json" -d '{"paperKey":"aitong-2025"}' http://127.0.0.1:2099/api/epaper/sessions \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('sessionId', d['sessionId'], 'status 201-shaped, all unanswered:', all(not it['answered'] for it in d['items']))"

# Answer the first mcq item, then call start again with the SAME paperKey —
# expect the SAME sessionId back (resumed, not a new one), and that item's
# answered:true
```

Expected: fresh creation still returns 30/75-item sessions exactly as before, all `answered: false`. After answering one item and re-POSTing with the same `paperKey`, the response's `sessionId` matches the first call's (proving resume, not re-creation), and the answered item now reports `answered: true` while the rest stay `false`. Also verify starting a *different* `paperKey` while the first session is still `in_progress` creates a genuinely new session (not the wrong resume) — its own `answered` values should all be `false`. Then verify the pre-existing Chinese dictation resume path is completely untouched (`curl -s -X POST -d '{}' http://127.0.0.1:2099/api/dictation/sessions` still behaves exactly as before — this plan didn't touch that handler, but confirm nothing in the shared file broke it).

Clean up every session you create during this verification (`DELETE /api/epaper/sessions/:id` with `X-Admin-Pin: 1234`) so the scratch DB stays clean, then kill the scratch server (`lsof -i :2099 -sTCP:LISTEN`, then `kill <pid>` — not `%1`, this may run in a fresh shell).

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "feat(epaper): resume an in-progress session instead of always creating a new one"
```

---

### Task 2: macOS — `EpaperSessionItem` gains `answered: Bool`

**Files:**
- Modify: `macos-app/Sources/KidReminder/Models.swift:340-353`

**Interfaces:**
- Produces: `EpaperSessionItem.answered: Bool` — decoded from Task 1's new response field. Every existing usage of `EpaperSessionItem` (in `EnglishPaperRunnerView.swift`) keeps compiling unchanged; only Task 3 reads the new field.

- [ ] **Step 1: Add the field**

Find:

```swift
struct EpaperSessionItem: Codable, Identifiable {
    let itemId: Int
    let seq: Int
    let questionId: Int
    let section: String
    let questionType: String   // "mcq" | "fill_blank" | "oeq"
    let context: String
    let passage: String?       // full comprehension passage for this paper's oeq run
    let prompt: String
    let options: [String]?     // mcq only
    let marks: Int
    let image: String
    var id: Int { itemId }
}
```

Replace with:

```swift
struct EpaperSessionItem: Codable, Identifiable {
    let itemId: Int
    let seq: Int
    let questionId: Int
    let section: String
    let questionType: String   // "mcq" | "fill_blank" | "oeq"
    let context: String
    let passage: String?       // full comprehension passage for this paper's oeq run
    let prompt: String
    let options: [String]?     // mcq only
    let marks: Int
    let image: String
    /// True if this item already has a stored answer — only meaningful on a
    /// resumed session (see POST /api/epaper/sessions); always false on a
    /// freshly created one. Lets the runner jump straight to the first
    /// unanswered step instead of restarting from question 1.
    let answered: Bool
    var id: Int { itemId }
}
```

- [ ] **Step 2: Build**

```bash
cd macos-app
swift build 2>&1 | tail -30
```

Expected: `Build complete!` with no new errors. (A build error here would mean some other file constructs an `EpaperSessionItem` literal directly instead of only decoding it from JSON — check for that if the build fails; as of this plan being written, no such call site exists.)

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/KidReminder/Models.swift
git commit -m "feat(macos): add answered field to EpaperSessionItem"
```

---

### Task 3: macOS — `EnglishPaperRunnerView` resumes at the first unanswered step

**Files:**
- Modify: `macos-app/Sources/KidReminder/EnglishPaperRunnerView.swift:474-491` (`start()`)

**Interfaces:**
- Consumes: `EpaperSessionItem.answered` (Task 2), the existing private `steps: [[EpaperSessionItem]]` computed property (unchanged, already defined at line 49).
- Produces: `private func resumeStepIndex() -> Int` — new helper, used only by `start()`.

- [ ] **Step 1: Replace `start()` and add the helper**

Find:

```swift
    private func start() async {
        phase = .loading
        do {
            let s: EpaperSession
            switch source {
            case .paper(let key, _): s = try await api.startEpaperSession(paper: key)
            case .mistakes: s = try await api.startEpaperSession(mistakes: true)
            }
            guard !s.items.isEmpty else { phase = .error("这里还没有题目。"); return }
            session = s
            stepPhase = .answering
            typed = ""
            groupAnswers = [:]
            phase = .running(step: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
```

Replace with:

```swift
    private func start() async {
        phase = .loading
        do {
            let s: EpaperSession
            switch source {
            case .paper(let key, _): s = try await api.startEpaperSession(paper: key)
            case .mistakes: s = try await api.startEpaperSession(mistakes: true)
            }
            guard !s.items.isEmpty else { phase = .error("这里还没有题目。"); return }
            session = s
            stepPhase = .answering
            typed = ""
            groupAnswers = [:]
            phase = .running(step: resumeStepIndex())
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// The first step containing any unanswered item — so resuming an
    /// interrupted paper picks up where the kid left off instead of
    /// restarting from question 1. On a freshly created session every item's
    /// `answered` is false, so this always evaluates to 0, same as before.
    /// Falls back to the last step if every item is somehow already answered
    /// (e.g. the kid answered everything but the app closed before "完成"
    /// registered) so they can still reach the finish button.
    private func resumeStepIndex() -> Int {
        let allSteps = steps
        return allSteps.firstIndex { $0.contains { !$0.answered } } ?? max(0, allSteps.count - 1)
    }
```

- [ ] **Step 2: Build**

```bash
cd macos-app
swift build 2>&1 | tail -30
```

Expected: `Build complete!` with no new errors.

- [ ] **Step 3: Manual verification against the scratch server from Task 1**

There's no automated test for the runner UI. Verify by hand:

1. Restart the scratch server from Task 1's Step 2 if it's not still running.
2. Run the built app (`open macos-app/build/KidReminder.app` after `./build.sh`, or run via `swift run` for a debug build) pointed at `127.0.0.1:2099` in Settings.
3. Start a paper, answer the first 3-4 questions, then force-quit the app (Cmd+Q or kill the process) without clicking "完成".
4. Reopen the app, start the *same* paper again.
5. Confirm it opens directly at question 4-ish (not question 1), and that the sidebar/progress indicator ("第 N 题 / 共 M 题") reflects the resumed position.
6. Finish the paper normally and confirm `/complete` still works and the session shows up correctly in `admin.html`.

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/KidReminder/EnglishPaperRunnerView.swift
git commit -m "feat(macos): resume English paper sessions at the first unanswered step"
```

---

### Task 4: Admin UI — "标记可批改" button on in-progress session rows

**Files:**
- Modify: `backend/admin.html:2089-2126` (`epaperSessionRow`)

**Interfaces:**
- Consumes: the **existing** `POST /api/epaper/sessions/:id/complete` endpoint — no backend change needed for this task, it's the exact endpoint used to manually recover today's incident.
- Produces: no new function — one new conditional button + its click handler, inside the existing `epaperSessionRow`.

- [ ] **Step 1: Add the button**

Find:

```js
  function epaperSessionRow(s, paperLabels) {
    const row = document.createElement("div");
    row.className = "card sci-session";
    const title = s.mode === "mistakes"
      ? "📕 错题本复习"
      // Fall back to the raw paper_key if the paper was since removed from the
      // bank (history still references it) or for old rows with no paper_key.
      : `📘 ${paperLabels[s.paper_key] || s.paper_key || "英语试卷练习"}`;
    const when = new Date((s.completed_at || s.created_at).replace(" ", "T") + "Z");
    let badge, sub;
    if (s.status === "pending_review") {
      badge = '<div class="badge cnt">🔔 待批改</div>';
      sub = `完成于 ${when.toLocaleString()}`;
    } else if (s.status === "reviewed") {
      badge = `<div class="badge">✅ ${s.score_earned}/${s.marks_total}</div>`;
      sub = `完成于 ${when.toLocaleString()}`;
    } else {
      badge = '<div class="badge parent">⏳ 进行中</div>';
      sub = "孩子还没有做完这次练习";
      row.style.opacity = ".6";
    }
    row.innerHTML = `
      <div class="icon">📘</div>
      <div class="info">
        <div class="count">${title}</div>
        <div class="when">${sub}</div>
      </div>
      ${badge}
      <button class="del" title="删除这条记录">🗑</button>`;
    if (s.status !== "in_progress") row.onclick = () => openEpaperGradeDialog(s.id);
    row.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm("删除这条英语试卷练习记录？")) return;
      try { await api(`/api/epaper/sessions/${s.id}`, { method: "DELETE" }); refreshEpaper(); }
      catch (err) { showErr(err.message); }
    };
    return row;
  }
```

Replace with:

```js
  function epaperSessionRow(s, paperLabels) {
    const row = document.createElement("div");
    row.className = "card sci-session";
    const title = s.mode === "mistakes"
      ? "📕 错题本复习"
      // Fall back to the raw paper_key if the paper was since removed from the
      // bank (history still references it) or for old rows with no paper_key.
      : `📘 ${paperLabels[s.paper_key] || s.paper_key || "英语试卷练习"}`;
    const when = new Date((s.completed_at || s.created_at).replace(" ", "T") + "Z");
    let badge, sub;
    if (s.status === "pending_review") {
      badge = '<div class="badge cnt">🔔 待批改</div>';
      sub = `完成于 ${when.toLocaleString()}`;
    } else if (s.status === "reviewed") {
      badge = `<div class="badge">✅ ${s.score_earned}/${s.marks_total}</div>`;
      sub = `完成于 ${when.toLocaleString()}`;
    } else {
      badge = '<div class="badge parent">⏳ 进行中</div>';
      sub = "孩子还没有做完这次练习";
      row.style.opacity = ".6";
    }
    // "标记可批改" only makes sense for in_progress rows: the same recovery
    // the app itself now does automatically on resume (see the 2026-09-10
    // resume fix), exposed here as a manual escape hatch for the one case
    // resume can't cover — the kid switched to a *different* paper while this
    // one was still open, so the app's own resume (scoped to the same
    // paper_key) never reattaches to it and it would otherwise sit stuck
    // in_progress forever, same as the incident that motivated this button.
    const forceCompleteBtn = s.status === "in_progress"
      ? '<button class="ghost force-complete" title="标记为可批改（孩子不会再继续做这份了）">✅ 标记可批改</button>'
      : "";
    row.innerHTML = `
      <div class="icon">📘</div>
      <div class="info">
        <div class="count">${title}</div>
        <div class="when">${sub}</div>
      </div>
      ${badge}
      ${forceCompleteBtn}
      <button class="del" title="删除这条记录">🗑</button>`;
    if (s.status !== "in_progress") row.onclick = () => openEpaperGradeDialog(s.id);
    if (s.status === "in_progress") {
      row.querySelector(".force-complete").onclick = async (e) => {
        e.stopPropagation();
        if (!confirm("确认孩子不会再继续做这份了吗？会把已经答的题目标记为可批改。")) return;
        try { await api(`/api/epaper/sessions/${s.id}/complete`, { method: "POST" }); refreshEpaper(); }
        catch (err) { showErr(err.message); }
      };
    }
    row.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm("删除这条英语试卷练习记录？")) return;
      try { await api(`/api/epaper/sessions/${s.id}`, { method: "DELETE" }); refreshEpaper(); }
      catch (err) { showErr(err.message); }
    };
    return row;
  }
```

- [ ] **Step 2: Manual verification**

No automated test for the admin page. With the Task 1 scratch server running:

1. Open `http://127.0.0.1:2099/admin`, go to "英语试卷批改".
2. Create an in-progress session directly (`curl -X POST -d '{"paperKey":"aitong-2025"}' ...`, don't complete it) and confirm it shows up dimmed with "⏳ 进行中" **and** the new "✅ 标记可批改" button, and that clicking the row itself still does nothing (not clickable, same as before).
3. Click "✅ 标记可批改", confirm the dialog, and confirm the row updates to "🔔 待批改" and is now clickable (opens the grading dialog).
4. Confirm a `reviewed`/`pending_review` row never shows this button (only `in_progress` rows do).

- [ ] **Step 3: Commit**

```bash
git add backend/admin.html
git commit -m "feat(admin): add a manual 'mark as gradeable' button for stuck in-progress English paper sessions"
```

---

### Task 5: Version bump and packaging (build only — do not deploy or push)

**Files:**
- Modify: `macos-app/build.sh` (version bump)

**Interfaces:** None — this task only packages what Tasks 1-4 built; it does not deploy or publish anything (see Global Constraints).

- [ ] **Step 1: Bump the macOS app version**

Check the current value (`grep CFBundleShortVersionString macos-app/build.sh`) and bump the patch version by one (this is a bug-fix-sized change to existing behavior, not a new feature — matches this repo's convention of patch bumps for fixes, e.g. 1.18.0 → 1.18.1 for the English-dictation word-count fix).

- [ ] **Step 2: Build the release .app**

```bash
cd macos-app
./build.sh
```

Expected: ends with `=== done: build/KidReminder.app ===`.

- [ ] **Step 3: Commit the version bump**

```bash
git add macos-app/build.sh
git commit -m "macos-app: bump version to <X.Y.Z>"
```

- [ ] **Step 4: Stop here**

Per Global Constraints, do **not** run `git push`, do **not** deploy `server.js`/`admin.html` to the Mac Mini, and do **not** tag or create a GitHub release. Report the plan as fully implemented and locally verified, and wait for explicit deploy approval — same two-phase pattern as the English Dictation feature (plan + local build now, deploy later on request).

---

## Self-Review

**Spec coverage:** Every element of the Architecture section is implemented: resume lookup + `answered` field (Task 1), Swift model support (Task 2), resume-aware runner (Task 3), the manual admin fallback for the one case resume can't cover on its own (Task 4). The two Global Constraints about scope (scoped-per-paper-key resume, not touching today's already-fixed stranded sessions) are honored by construction — no task tries to do more than that.

**Placeholder scan:** No task step says "add appropriate X" without showing the actual code. The one deliberately-out-of-scope item (auto-handling the "switched to a different paper" case) is named explicitly in Global Constraints as a scope decision, with Task 4 as its stated mitigation — not a silent gap.

**Type consistency:** `answered: Bool` is introduced once on the wire (Task 1's JSON response, both the resume and fresh-creation branches), decoded once (Task 2's `EpaperSessionItem`), and consumed once (Task 3's `resumeStepIndex()`, reading `$0.answered` off the same `EpaperSessionItem` type `steps` was already built from at line 49). `existingSession.mode` in Task 1 is read fresh from the DB rather than reusing the outer-scope `mode` variable, because that variable isn't declared yet at the point the resume branch returns — avoids a scoping bug where a naive implementation might reference `mode` before its `let` declaration.
