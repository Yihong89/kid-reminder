# Science Practice Session Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Science practice sessions the same resume fix just shipped for English Paper (epaper, 2026-09-10/11): a kid who force-quits or crashes mid-session no longer strands an ungradeable `in_progress` session forever. `POST /api/science/sessions` resumes an existing `in_progress` session (scoped the same way the source is scoped) instead of always creating a new one, and reports which items are already answered so the runner can skip straight past them.

**Architecture:** Mirrors the epaper fix's shape, adapted to science's simpler model:
- Science has **no** mcq/oeq split (every item goes through one `/submit` path with mark points) and **no** grouped "steps" (the runner is a flat `index: Int` over `items`, no section-grouping like epaper's paper-mode). So "answered" is a single predicate (`auto_score IS NOT NULL` on `science_session_items`, no join needed) and the resume-step calculation has no groupable-steps complexity to account for.
- Science has **no** skip button (`ScienceRunnerView` only ever calls `advance(to: index + 1)` after a graded submit, or finishes on the last item) — so unlike epaper, "first unanswered" and "furthest reached" produce identical results here. This plan still specifies "furthest reached" (one past the last answered item) for consistency with the already-reviewed epaper implementation and so a future skip feature wouldn't reintroduce the bug epaper's final review caught.
- Science's `POST /api/science/sessions` takes its source as **query params** (`?paper=<key>` / `?mode=mistakes`), not a JSON body like epaper — the resume lookup reads `url.searchParams` accordingly. No macOS `APIClient` change is needed: `startScienceSession` already sends these params and only needs the response's new `answered` field decoded.
- **The legacy `weakest` mode is deliberately excluded from resume.** It has no stable identity to resume against — it's a random N-question pool drawn fresh from whichever questions currently look weakest (`ORDER BY score ratio ASC, RANDOM() LIMIT size*3` then a random slice), not offered in the app UI anymore ("kept for admin/testing" per the existing code comment). Resuming it would mean re-serving a snapshot of a pool that no longer reflects current weakness, for a mode nothing in the shipped app actually creates. Only `paper` (scoped by `paper_key`) and `mistakes` (scoped by mode alone) get resume, exactly mirroring epaper's own scope decision.
- A small admin-UI addition (`admin.html`) gives the parent the same manual "mark as gradeable" escape hatch `sciSessionRow()` currently lacks, for the one case resume can't cover: the kid abandons paper A and starts paper B while A is still `in_progress`.

**Tech Stack:** Node.js (`node:sqlite`, zero dependencies) backend; vanilla JS/HTML admin panel; SwiftUI macOS app (Swift Package Manager, no Xcode project).

**Spec:** No separate spec doc — this plan's Architecture section is the design, and it is a direct application of the epaper resume plan/fix (`docs/superpowers/plans/2026-09-10-epaper-resume.md`, already shipped in commits `65f7dfe..06d1276` on `main`) to `science_sessions`, which has the identical create-always/strand-forever pattern (flagged as follow-up work in that plan's final review, 2026-09-11).

## Global Constraints

- **Backward compatibility is non-negotiable** for every other science/epaper/dictation code path this plan doesn't touch. The response shape for `POST /api/science/sessions` stays `{ sessionId, mode, items }`; the only change is one new field (`answered`) on each item, purely additive.
- **No test framework exists in this repo.** Verification is manual: run the backend against a **scratch copy** of the live DB (never the live DB directly — see project memory on the import-script naming incident for why), `curl` the endpoints, inspect with `sqlite3`; for Swift, `swift build` must succeed.
- **Scoped-resume is a deliberate limitation, not a gap** (see Architecture) — `weakest` mode never resumes; only `paper` (by `paper_key`) and `mistakes` (by mode alone) do. This mirrors epaper exactly.
- **Deploy this time is authorized, not deferred.** Unlike the epaper plan (which explicitly deferred deploy/push to a later, separate request), this human partner has already asked this session to deploy and publish once implementation and review are done. Do not stop after the local build — proceed to deploy `backend/server.js` + `backend/admin.html` to the Mac Mini and publish a GitHub Release with the built app, same as was just done for the epaper fix, **in that order** (backend deploy strictly before the release is published — a released app with a non-optional `answered` field talking to a not-yet-updated backend would hard-fail decoding `ScienceSessionItem`, exactly the ordering risk epaper's final review flagged and this plan inherits).

---

## File Structure

- **Modify:** `backend/server.js` — `POST /api/science/sessions` gains resume-lookup + `answered` field on every returned item (both the resumed path and the fresh-creation path). Handler is at the `pathname === "/api/science/sessions"` POST branch (search for `// --- start a practice set (open; the kid app calls this) ---` above `science_sessions`, not the epaper one of the same comment text).
- **Modify:** `macos-app/Sources/KidReminder/Models.swift` — `ScienceSessionItem` gains `let answered: Bool`.
- **Modify:** `macos-app/Sources/KidReminder/ScienceRunnerView.swift` — `start()` opens at the resume index instead of always index `0`.
- **Modify:** `backend/admin.html` — `sciSessionRow()` gains a "✅ 标记可批改" button on `in_progress` rows, calling the existing `/api/science/sessions/:id/complete` endpoint (no new backend route needed).

---

### Task 1: Backend — resume lookup + `answered` field in `POST /api/science/sessions`

**Files:**
- Modify: `backend/server.js` — the `POST /api/science/sessions` handler (currently spans from `if (method === "POST" && pathname === "/api/science/sessions") {` through its closing `}` before the `/submit` handler; roughly 80 lines including the three-mode branch and the session/item insert loop).

**Interfaces:**
- Consumes: existing tables `science_sessions`, `science_session_items`, `science_questions` — no schema change needed, every column this reads already exists (`science_sessions.status`, `.mode`, `.paper_key`, `.created_at`; `science_session_items.auto_score`).
- Produces: `POST /api/science/sessions` response items each gain `answered: Bool`. Resume path returns HTTP `200` (fresh-creation path keeps returning `201` — same convention as epaper/dictation).

- [ ] **Step 1: Replace the handler**

Find the entire current handler:

```js
    // --- start a practice set (open; the kid app calls this) ------------------
    // Three modes:
    //   ?paper=<paper_key>  一张完整卷子，按卷子本身的题号顺序
    //   ?mode=mistakes      错题本，随机顺序
    //   (neither)           legacy weakest-first pool — kept for admin/testing,
    //                       the app UI no longer offers this path
    if (method === "POST" && pathname === "/api/science/sessions") {
      const paperKey = url.searchParams.get("paper") || "";
      const mistakesMode = url.searchParams.get("mode") === "mistakes";
      let qids, mode, school = "", year = null;

      if (paperKey) {
        const rows = db.prepare(`
          SELECT id, school, year FROM science_questions
           WHERE paper_key = ? AND answer_mode != 'drawing'
           ORDER BY paper_seq ASC`).all(paperKey);
        if (!rows.length) return sendJSON(404, { error: "paper not found" });
        qids = rows.map((r) => r.id);
        mode = "paper";
        school = rows[0].school; year = rows[0].year;
      } else if (mistakesMode) {
        // Pick the 15 weakest rather than dumping the whole bank into one
        // session — same reasoning and same day as the epaper equivalent of
        // this change (2026-09-09): a bank that's grown past 30+ questions is
        // too long to finish in one sitting. science_questions has no
        // correct_count column (unlike epaper/vocab_words — see the comment on
        // score_total above), so "weakest" reuses the same score-ratio
        // expression the legacy pool below already uses: unattempted counts as
        // weakest (CASE WHEN attempts = 0), otherwise average marks earned per
        // attempt, ascending. RANDOM() breaks ties before the LIMIT.
        const rows = db.prepare(`
          SELECT id FROM science_questions
           WHERE in_mistake_bank = 1 AND answer_mode != 'drawing'
           ORDER BY (CASE WHEN attempts = 0 THEN 0
                          ELSE CAST(score_total AS REAL) / (attempts * marks) END) ASC,
                    RANDOM() ASC
           LIMIT 15`).all();
        if (!rows.length) return sendJSON(400, { error: "错题本是空的，继续保持！" });
        qids = rows.map((r) => r.id);
        for (let i = qids.length - 1; i > 0; i--) {         // Fisher-Yates — 随机顺序
          const j = Math.floor(Math.random() * (i + 1));
          [qids[i], qids[j]] = [qids[j], qids[i]];
        }
        mode = "mistakes";
      } else {
        // Legacy weakest-first pool, unchanged from the original implementation.
        const size = Math.min(10, Math.max(1, parseInt(url.searchParams.get("size") || "5", 10) || 5));
        const pool = db.prepare(`
          SELECT id FROM science_questions
           WHERE answer_mode != 'drawing'
           ORDER BY (CASE WHEN attempts = 0 THEN 0
                          ELSE CAST(score_total AS REAL) / (attempts * marks) END) ASC,
                    RANDOM() ASC
           LIMIT ?`).all(size * 3).map((r) => r.id);
        if (!pool.length) return sendJSON(400, { error: "science question bank is empty" });
        for (let i = pool.length - 1; i > 0; i--) {
          const j = Math.floor(Math.random() * (i + 1));
          [pool[i], pool[j]] = [pool[j], pool[i]];
        }
        qids = pool.slice(0, size);
        mode = "weakest";
      }

      const sessionId = db.prepare(
        "INSERT INTO science_sessions (status, mode, paper_key, school, year) VALUES ('in_progress', ?, ?, ?, ?)"
      ).run(mode, paperKey, school, year).lastInsertRowid;
      const items = [];
      qids.forEach((qid, idx) => {
        const itemId = db.prepare(
          "INSERT INTO science_session_items (session_id, question_id, seq) VALUES (?, ?, ?)"
        ).run(sessionId, qid, idx + 1).lastInsertRowid;
        const q = db.prepare("SELECT * FROM science_questions WHERE id = ?").get(qid);
        items.push({
          itemId: Number(itemId), seq: idx + 1, questionId: qid,
          theme: q.theme, topic: q.topic, questionType: q.question_type,
          answerMode: q.answer_mode, marks: q.marks,
          context: q.context, prompt: q.prompt, image: q.image,
        });
      });
      // model_answer and mark points are deliberately withheld until submit.
      return sendJSON(201, { sessionId: Number(sessionId), mode, items });
    }
```

Replace with:

```js
    // --- start a practice set (open; the kid app calls this) ------------------
    // Three modes:
    //   ?paper=<paper_key>  一张完整卷子，按卷子本身的题号顺序
    //   ?mode=mistakes      错题本，随机顺序
    //   (neither)           legacy weakest-first pool — kept for admin/testing,
    //                       the app UI no longer offers this path
    //
    // Resumes an existing in_progress session that matches the requested source
    // first (paper mode: same paper_key; mistakes mode: any in-progress mistakes
    // session) instead of always creating a new one — same fix as epaper's
    // 2026-09-10 resume change, for the identical create-always/strand-forever
    // failure mode (a kid who force-quits mid-session leaves it stuck
    // in_progress and ungradeable, and every subsequent attempt piles another
    // orphaned session on top). The legacy `weakest` pool is deliberately NOT
    // resumed: it has no stable identity (a random snapshot of "currently
    // weakest" questions, re-drawn every time, not offered in the app UI
    // anymore) so there is nothing meaningful to reattach to.
    if (method === "POST" && pathname === "/api/science/sessions") {
      const paperKey = url.searchParams.get("paper") || "";
      const mistakesMode = url.searchParams.get("mode") === "mistakes";

      let existing;
      if (paperKey) {
        existing = db.prepare(
          "SELECT id FROM science_sessions WHERE status = 'in_progress' AND mode = 'paper' AND paper_key = ? ORDER BY created_at DESC LIMIT 1"
        ).get(paperKey);
      } else if (mistakesMode) {
        existing = db.prepare(
          "SELECT id FROM science_sessions WHERE status = 'in_progress' AND mode = 'mistakes' ORDER BY created_at DESC LIMIT 1"
        ).get();
      }
      if (existing) {
        const rows = db.prepare(`
          SELECT i.id itemId, i.seq, i.question_id questionId, q.theme, q.topic,
                 q.question_type questionType, q.answer_mode answerMode, q.marks,
                 q.context, q.prompt, q.image, i.auto_score autoScore
            FROM science_session_items i JOIN science_questions q ON q.id = i.question_id
           WHERE i.session_id = ? ORDER BY i.seq`).all(existing.id);
        const existingSession = db.prepare("SELECT mode FROM science_sessions WHERE id = ?").get(existing.id);
        const items = rows.map((it) => ({
          itemId: it.itemId, seq: it.seq, questionId: it.questionId, theme: it.theme,
          topic: it.topic, questionType: it.questionType, answerMode: it.answerMode,
          marks: it.marks, context: it.context, prompt: it.prompt, image: it.image,
          // "answered" = auto_score has been written, which /submit does exactly
          // once, at first submit (its own idempotency check below reads the
          // same column). No mcq/oeq split to account for here, unlike epaper —
          // science has exactly one grading tier.
          answered: it.autoScore !== null,
        }));
        return sendJSON(200, { sessionId: existing.id, mode: existingSession.mode, items });
      }

      let qids, mode, school = "", year = null;

      if (paperKey) {
        const rows = db.prepare(`
          SELECT id, school, year FROM science_questions
           WHERE paper_key = ? AND answer_mode != 'drawing'
           ORDER BY paper_seq ASC`).all(paperKey);
        if (!rows.length) return sendJSON(404, { error: "paper not found" });
        qids = rows.map((r) => r.id);
        mode = "paper";
        school = rows[0].school; year = rows[0].year;
      } else if (mistakesMode) {
        // Pick the 15 weakest rather than dumping the whole bank into one
        // session — same reasoning and same day as the epaper equivalent of
        // this change (2026-09-09): a bank that's grown past 30+ questions is
        // too long to finish in one sitting. science_questions has no
        // correct_count column (unlike epaper/vocab_words — see the comment on
        // score_total above), so "weakest" reuses the same score-ratio
        // expression the legacy pool below already uses: unattempted counts as
        // weakest (CASE WHEN attempts = 0), otherwise average marks earned per
        // attempt, ascending. RANDOM() breaks ties before the LIMIT.
        const rows = db.prepare(`
          SELECT id FROM science_questions
           WHERE in_mistake_bank = 1 AND answer_mode != 'drawing'
           ORDER BY (CASE WHEN attempts = 0 THEN 0
                          ELSE CAST(score_total AS REAL) / (attempts * marks) END) ASC,
                    RANDOM() ASC
           LIMIT 15`).all();
        if (!rows.length) return sendJSON(400, { error: "错题本是空的，继续保持！" });
        qids = rows.map((r) => r.id);
        for (let i = qids.length - 1; i > 0; i--) {         // Fisher-Yates — 随机顺序
          const j = Math.floor(Math.random() * (i + 1));
          [qids[i], qids[j]] = [qids[j], qids[i]];
        }
        mode = "mistakes";
      } else {
        // Legacy weakest-first pool, unchanged from the original implementation.
        const size = Math.min(10, Math.max(1, parseInt(url.searchParams.get("size") || "5", 10) || 5));
        const pool = db.prepare(`
          SELECT id FROM science_questions
           WHERE answer_mode != 'drawing'
           ORDER BY (CASE WHEN attempts = 0 THEN 0
                          ELSE CAST(score_total AS REAL) / (attempts * marks) END) ASC,
                    RANDOM() ASC
           LIMIT ?`).all(size * 3).map((r) => r.id);
        if (!pool.length) return sendJSON(400, { error: "science question bank is empty" });
        for (let i = pool.length - 1; i > 0; i--) {
          const j = Math.floor(Math.random() * (i + 1));
          [pool[i], pool[j]] = [pool[j], pool[i]];
        }
        qids = pool.slice(0, size);
        mode = "weakest";
      }

      const sessionId = db.prepare(
        "INSERT INTO science_sessions (status, mode, paper_key, school, year) VALUES ('in_progress', ?, ?, ?, ?)"
      ).run(mode, paperKey, school, year).lastInsertRowid;
      const items = [];
      qids.forEach((qid, idx) => {
        const itemId = db.prepare(
          "INSERT INTO science_session_items (session_id, question_id, seq) VALUES (?, ?, ?)"
        ).run(sessionId, qid, idx + 1).lastInsertRowid;
        const q = db.prepare("SELECT * FROM science_questions WHERE id = ?").get(qid);
        items.push({
          itemId: Number(itemId), seq: idx + 1, questionId: qid,
          theme: q.theme, topic: q.topic, questionType: q.question_type,
          answerMode: q.answer_mode, marks: q.marks,
          context: q.context, prompt: q.prompt, image: q.image,
          answered: false,
        });
      });
      // model_answer and mark points are deliberately withheld until submit.
      return sendJSON(201, { sessionId: Number(sessionId), mode, items });
    }
```

- [ ] **Step 2: Verify against a scratch copy of the live DB**

```bash
mkdir -p /tmp/science-resume-test
scp -q robot@192.168.0.12:/Users/robot/kidreminder/kidreminder.db /tmp/science-resume-test/kidreminder.db
cd backend
lsof -i :2098 -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2}' | xargs -r kill
DB_PATH=/tmp/science-resume-test/kidreminder.db PORT=2098 ADMIN_PIN=1234 KID_PIN=4321 node server.js &
sleep 1.5
curl -s http://127.0.0.1:2098/api/health
```

Pick any real `paper_key` from `SELECT DISTINCT paper_key FROM science_questions WHERE paper_key != ''` on the scratch DB. Then:

1. Start a fresh paper session (`curl -X POST 'http://127.0.0.1:2098/api/science/sessions?paper=<key>'`) — confirm `201` and every item has `answered: false`.
2. Submit the first item's answer, then call the same start URL again — expect the **same** `sessionId` back (`200`, not `201`), and that item's `answered: true` while the rest stay `false`.
3. Start a *different* `paper_key` while the first is still `in_progress` — confirm it creates a genuinely new session (its own `answered` all `false`), proving resume doesn't cross paper_key.
4. Repeat the same resume check for `mode=mistakes` (needs `in_mistake_bank = 1` rows — check `SELECT COUNT(*) FROM science_questions WHERE in_mistake_bank = 1` first; if zero, `UPDATE science_questions SET in_mistake_bank = 1 WHERE id IN (SELECT id FROM science_questions LIMIT 3)` on the **scratch DB only**, never the live one).
5. Confirm the legacy pool (`curl -X POST http://127.0.0.1:2098/api/science/sessions` with no query params) is NOT affected by resume — two consecutive calls with no `in_progress` session lookup applicable should each create a fresh session (`201` both times), even if an unrelated `paper`/`mistakes` session is `in_progress` at the same time.
6. Confirm the epaper and dictation resume paths are completely untouched (`curl -s -X POST -d '{}' http://127.0.0.1:2098/api/dictation/sessions` and an epaper equivalent still behave exactly as before — this plan didn't touch either handler, but confirm nothing in the shared file broke them).

Clean up every session you create (`DELETE /api/science/sessions/:id` with `X-Admin-Pin: 1234`) so the scratch DB stays clean, then kill the scratch server.

- [ ] **Step 3: Commit**

```bash
git add backend/server.js
git commit -m "feat(science): resume an in-progress session instead of always creating a new one"
```

---

### Task 2: macOS — `ScienceSessionItem` gains `answered: Bool`

**Files:**
- Modify: `macos-app/Sources/KidReminder/Models.swift` — the `ScienceSessionItem` struct.

**Interfaces:**
- Produces: `ScienceSessionItem.answered: Bool` — decoded from Task 1's new response field. Every existing usage of `ScienceSessionItem` (in `ScienceRunnerView.swift`) keeps compiling unchanged; only Task 3 reads the new field.

- [ ] **Step 1: Add the field**

Find:

```swift
struct ScienceSessionItem: Codable, Identifiable {
    let itemId: Int
    let seq: Int
    let questionId: Int
    let theme: String
    let topic: String
    let questionType: String
    let answerMode: ScienceAnswerMode
    let marks: Int
    let context: String
    let prompt: String
    let image: String
    var id: Int { itemId }
}
```

Replace with:

```swift
struct ScienceSessionItem: Codable, Identifiable {
    let itemId: Int
    let seq: Int
    let questionId: Int
    let theme: String
    let topic: String
    let questionType: String
    let answerMode: ScienceAnswerMode
    let marks: Int
    let context: String
    let prompt: String
    let image: String
    /// True if this item already has a stored answer — only meaningful on a
    /// resumed session (see POST /api/science/sessions); always false on a
    /// freshly created one. Lets the runner skip straight past already-
    /// answered items instead of restarting from question 1.
    let answered: Bool
    var id: Int { itemId }
}
```

- [ ] **Step 2: Build**

```bash
cd macos-app
swift build 2>&1 | tail -30
```

Expected: `Build complete!` with no new errors.

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/KidReminder/Models.swift
git commit -m "feat(macos): add answered field to ScienceSessionItem"
```

---

### Task 3: macOS — `ScienceRunnerView` resumes at the furthest-reached index

**Files:**
- Modify: `macos-app/Sources/KidReminder/ScienceRunnerView.swift` — `start()`.

**Interfaces:**
- Consumes: `ScienceSessionItem.answered` (Task 2), `session?.items` (existing, unchanged).
- Produces: `private func resumeIndex() -> Int` — new helper, used only by `start()`.

- [ ] **Step 1: Replace `start()` and add the helper**

Find:

```swift
    private func start() async {
        phase = .loading
        autoSoFar = 0; marksSoFar = 0
        do {
            let s: ScienceSession
            switch source {
            case .paper(let key, _):
                s = try await api.startScienceSession(paper: key)
            case .mistakes:
                s = try await api.startScienceSession(mistakes: true)
            }
            guard !s.items.isEmpty else { phase = .error("这里还没有题目。"); return }
            session = s
            itemPhase = .answering
            typed = ""
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
```

Replace with:

```swift
    private func start() async {
        phase = .loading
        autoSoFar = 0; marksSoFar = 0
        do {
            let s: ScienceSession
            switch source {
            case .paper(let key, _):
                s = try await api.startScienceSession(paper: key)
            case .mistakes:
                s = try await api.startScienceSession(mistakes: true)
            }
            guard !s.items.isEmpty else { phase = .error("这里还没有题目。"); return }
            session = s
            itemPhase = .answering
            typed = ""
            phase = .running(index: resumeIndex())
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// The index just past the furthest answered item — so resuming an
    /// interrupted session picks up where the kid left off instead of
    /// restarting from question 1. On a freshly created session every item's
    /// `answered` is false, so this always evaluates to 0, same as before.
    /// There is no skip button in this runner (unlike EnglishPaperRunnerView),
    /// so "furthest reached" and "first unanswered" are equivalent here today —
    /// this is written the same way as the epaper fix anyway, both for
    /// consistency and so a future skip feature here wouldn't reintroduce the
    /// bug that shape caused there. Falls back to the last item's index if
    /// every item is somehow already answered, so "完成" is still reachable.
    private func resumeIndex() -> Int {
        let items = session?.items ?? []
        guard let lastAnswered = items.lastIndex(where: { $0.answered }) else { return 0 }
        return min(lastAnswered + 1, items.count - 1)
    }
```

- [ ] **Step 2: Build**

```bash
cd macos-app
swift build 2>&1 | tail -30
```

Expected: `Build complete!` with no new errors.

- [ ] **Step 3: Manual verification against the scratch server from Task 1**

No GUI automation is expected to be available to whoever executes this step — if so, substitute a logical hand-trace of `resumeIndex()` for: fresh session (expect 0), partial progress (expect index of next unanswered item), and all-answered (expect `items.count - 1`), and say so explicitly in the report rather than claiming a manual walkthrough that didn't happen. If GUI automation IS available, verify by hand: start a paper, answer 3-4 questions, force-quit before "完成", reopen and start the same paper, confirm it resumes at the right question.

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/KidReminder/ScienceRunnerView.swift
git commit -m "feat(macos): resume Science practice sessions at the furthest-reached index"
```

---

### Task 4: Admin UI — "标记可批改" button on in-progress science session rows

**Files:**
- Modify: `backend/admin.html` — `sciSessionRow()`.

**Interfaces:**
- Consumes: the **existing** `POST /api/science/sessions/:id/complete` endpoint — no backend change needed for this task.
- Produces: no new function — one new conditional button + its click handler, inside the existing `sciSessionRow`.

- [ ] **Step 1: Add the button**

Find:

```js
  function sciSessionRow(s) {
    const row = document.createElement("div");
    row.className = "card sci-session";
    const title = s.mode === "mistakes" ? "📕 错题本复习"
      : s.school ? `📄 ${escapeHtml(s.school)} ${s.year || ""}` : "🔬 科学练习";
    const when = new Date((s.completed_at || s.created_at).replace(" ", "T") + "Z");
    let badge, sub;
    if (s.status === "pending_review") {
      badge = '<div class="badge cnt">🔔 待批改</div>';
      sub = `完成于 ${when.toLocaleString()}`;
    } else if (s.status === "reviewed") {
      badge = `<div class="badge">✅ ${s.finalTotal}/${s.marksTotal}</div>`;
      sub = `完成于 ${when.toLocaleString()}`;
    } else {
      badge = '<div class="badge parent">⏳ 进行中</div>';
      sub = "孩子还没有做完这次练习";
      row.style.opacity = ".6";
    }
    row.innerHTML = `
      <div class="icon">🔬</div>
      <div class="info">
        <div class="count">${title}</div>
        <div class="when">${sub}</div>
      </div>
      ${badge}
      <button class="del" title="删除这条记录">🗑</button>`;
    if (s.status !== "in_progress") row.onclick = () => openScienceGradeDialog(s.id);
    row.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm("删除这条科学练习记录？")) return;
      try { await api(`/api/science/sessions/${s.id}`, { method: "DELETE" }); refreshScience(); }
      catch (err) { showErr(err.message); }
    };
    return row;
  }
```

Replace with:

```js
  function sciSessionRow(s) {
    const row = document.createElement("div");
    row.className = "card sci-session";
    const title = s.mode === "mistakes" ? "📕 错题本复习"
      : s.school ? `📄 ${escapeHtml(s.school)} ${s.year || ""}` : "🔬 科学练习";
    const when = new Date((s.completed_at || s.created_at).replace(" ", "T") + "Z");
    let badge, sub;
    if (s.status === "pending_review") {
      badge = '<div class="badge cnt">🔔 待批改</div>';
      sub = `完成于 ${when.toLocaleString()}`;
    } else if (s.status === "reviewed") {
      badge = `<div class="badge">✅ ${s.finalTotal}/${s.marksTotal}</div>`;
      sub = `完成于 ${when.toLocaleString()}`;
    } else {
      badge = '<div class="badge parent">⏳ 进行中</div>';
      sub = "孩子还没有做完这次练习";
      row.style.opacity = ".6";
    }
    // "标记可批改" only makes sense for in_progress rows: the same recovery
    // the app itself now does automatically on resume (mirrors the epaper fix,
    // 2026-09-10/11), exposed here as a manual escape hatch for the one case
    // resume can't cover — the kid switched to a *different* paper while this
    // one was still open, so the app's own resume (scoped to the same
    // paper_key) never reattaches to it and it would otherwise sit stuck
    // in_progress forever.
    const forceCompleteBtn = s.status === "in_progress"
      ? '<button class="ghost force-complete" title="标记为可批改（孩子不会再继续做这份了）">✅ 标记可批改</button>'
      : "";
    row.innerHTML = `
      <div class="icon">🔬</div>
      <div class="info">
        <div class="count">${title}</div>
        <div class="when">${sub}</div>
      </div>
      ${badge}
      ${forceCompleteBtn}
      <button class="del" title="删除这条记录">🗑</button>`;
    if (s.status !== "in_progress") row.onclick = () => openScienceGradeDialog(s.id);
    if (s.status === "in_progress") {
      row.querySelector(".force-complete").onclick = async (e) => {
        e.stopPropagation();
        if (!confirm("确认孩子不会再继续做这份了吗？会把已经答的题目标记为可批改。")) return;
        try { await api(`/api/science/sessions/${s.id}/complete`, { method: "POST" }); refreshScience(); }
        catch (err) { showErr(err.message); }
      };
    }
    row.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm("删除这条科学练习记录？")) return;
      try { await api(`/api/science/sessions/${s.id}`, { method: "DELETE" }); refreshScience(); }
      catch (err) { showErr(err.message); }
    };
    return row;
  }
```

- [ ] **Step 2: Manual verification**

With the Task 1 scratch server running:

1. Open `http://127.0.0.1:2098/admin`, go to "科学练习批改".
2. Create an in-progress session directly (`curl -X POST 'http://127.0.0.1:2098/api/science/sessions?paper=<key>'`, don't complete it) and confirm it shows up dimmed with "⏳ 进行中" **and** the new "✅ 标记可批改" button, and that clicking the row itself still does nothing.
3. Click "✅ 标记可批改", confirm the dialog, and confirm the row updates to "🔔 待批改" and is now clickable.
4. Confirm a `reviewed`/`pending_review` row never shows this button.

If GUI automation is unavailable, substitute a code read-through of the conditional gating (template + handler-wiring) plus a direct `curl` call to `/api/science/sessions/:id/complete` proving the button's one dependency behaves as assumed — same substitution epaper's Task 4 used — and say so explicitly.

- [ ] **Step 3: Commit**

```bash
git add backend/admin.html
git commit -m "feat(admin): add a manual 'mark as gradeable' button for stuck in-progress science sessions"
```

---

### Task 5: Version bump, build, deploy, and release

**Files:**
- Modify: `macos-app/build.sh` (version bump)

**Interfaces:** None beyond packaging what Tasks 1-4 built.

- [ ] **Step 1: Bump the macOS app version**

Patch-bump `CFBundleShortVersionString` in `macos-app/build.sh` by one from whatever it currently is (check with `grep CFBundleShortVersionString macos-app/build.sh` — expected to be `1.18.2` going in, so `1.18.3`, but verify rather than assume in case something else shipped in between).

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

- [ ] **Step 4: Merge, push, deploy, and release (authorized this run — see Global Constraints)**

Unlike the epaper plan, do NOT stop here. In order:

1. Merge the feature branch to `main` locally, verify (`node --check backend/server.js`, `swift build`), push.
2. **Backend first:** back up the live `server.js`/`admin.html` on the Mac Mini (`cp X X.bak-preresume-sci-$(date +%Y%m%d-%H%M%S)`), scp the new `backend/server.js` + `backend/admin.html` over, `node --check` the remote copy, restart the `com.kidreminder.server` launchd service, verify `/api/health` and a science-session request both work.
3. **Then, only after the backend is confirmed healthy:** zip the built `.app` (`ditto -c -k --sequesterRsrc --keepParent KidReminder.app KidReminder.zip`) and `gh release create v<X.Y.Z>` with that zip, following this repo's existing release-notes convention (short Chinese description of the fix).

---

## Self-Review

**Spec coverage:** Every element of the Architecture section is implemented: resume lookup + `answered` field scoped to `paper`/`mistakes` only (Task 1), Swift model support (Task 2), resume-aware runner (Task 3), the manual admin fallback (Task 4), full deploy (Task 5). This is a deliberate, scoped mirror of the already-shipped and already-reviewed epaper fix, adapted only where science's actual code differs (query-param source selection, single grading tier, no groupable steps, no skip button, an extra `weakest` mode that's explicitly excluded from resume).

**Placeholder scan:** No task step says "add appropriate X" without showing the actual code.

**Type consistency:** `answered: Bool` is introduced once on the wire (Task 1's JSON response, both branches), decoded once (Task 2's `ScienceSessionItem`), consumed once (Task 3's `resumeIndex()`). `existingSession.mode` in Task 1 is read fresh from the DB for the same reason as epaper's equivalent line — the outer-scope `mode` variable isn't declared yet at the point the resume branch returns.
