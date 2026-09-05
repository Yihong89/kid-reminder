#!/usr/bin/env node
// Kid Reminder - simple backend server (Node.js, zero dependencies)
//
// Storage: SQLite via built-in node:sqlite
// API:
//   GET  /api/health                      -> { ok, today }
//   GET  /api/tasks                       -> today's task list (kid's app)
//   POST /api/tasks                       -> create task            [X-Admin-Pin]
//   PATCH /api/tasks/:id                  -> edit task              [X-Admin-Pin]
//   DELETE /api/tasks/:id                 -> delete task            [X-Admin-Pin]
//   POST /api/tasks/:id/toggle            -> mark done / not done   (kid's app)
//   POST /api/verify                      -> check admin PIN
//   GET  / , /admin                       -> parent web admin panel
//   GET  /api/vocab                       -> search/list dictation word bank [X-Admin-Pin]
//   POST /api/vocab                       -> add a word                      [X-Admin-Pin]
//   PATCH /api/vocab/:id                  -> edit a word                     [X-Admin-Pin]
//   DELETE /api/vocab/:id                 -> delete a word                   [X-Admin-Pin]
//   POST /api/dictation/sessions          -> resume in_progress, else generate new (kid app)
//   POST /api/dictation/sessions/:id/complete -> kid finished, awaiting grading
//   GET  /api/dictation/sessions          -> list sessions (?status=)        [X-Admin-Pin or X-Kid-Pin]
//   GET  /api/dictation/sessions/:id      -> session detail w/ answers       [X-Admin-Pin or X-Kid-Pin]
//   DELETE /api/dictation/sessions/:id    -> delete a session (any status)   [X-Admin-Pin]
//   POST /api/dictation/sessions/:id/grade -> submit ✓/✗ per item            [X-Admin-Pin]
//   GET  /dictation-audio/:id.wav         -> TTS audio for a word (dsh-sister Qwen3-TTS, cached)
//   GET  /api/dictation-lists             -> list custom 听写表 (freeform, no grading)   [X-Admin-Pin or X-Kid-Pin]
//   POST /api/dictation-lists             -> create a custom list                        [X-Admin-Pin or X-Kid-Pin]
//   GET  /api/dictation-lists/:id         -> list detail w/ items                        [X-Admin-Pin or X-Kid-Pin]
//   PATCH /api/dictation-lists/:id        -> rename a list                               [X-Admin-Pin or X-Kid-Pin]
//   DELETE /api/dictation-lists/:id       -> delete a list (+ its items/audio)            [X-Admin-Pin or X-Kid-Pin]
//   POST /api/dictation-lists/:id/items   -> add a word+sentence to a list                [X-Admin-Pin or X-Kid-Pin]
//   PATCH /api/dictation-lists/:id/items/:itemId   -> edit a word                         [X-Admin-Pin or X-Kid-Pin]
//   DELETE /api/dictation-lists/:id/items/:itemId  -> remove a word                       [X-Admin-Pin or X-Kid-Pin]
//   GET  /custom-dictation-audio/:id.wav  -> TTS audio for a custom list item (cached)
//   GET  /api/english/questions           -> search/list question bank        [X-Admin-Pin]
//   POST /api/english/questions           -> add a question (app or web)      [X-Admin-Pin or X-Kid-Pin]
//   PATCH /api/english/questions/:id      -> edit a question                  [X-Admin-Pin]
//   DELETE /api/english/questions/:id     -> delete a question                [X-Admin-Pin]
//   POST /api/english/sessions            -> generate a practice set          (kid app)
//   POST /api/english/sessions/:id/items/:itemId/submit   -> auto-graded answer
//   POST /api/english/sessions/:id/items/:itemId/override -> flip a verdict once
//   POST /api/english/sessions/:id/complete -> mark a practice set finished
//   GET  /api/english/sessions             -> list practice-set history (?status=) [X-Admin-Pin]
//   GET  /api/english/sessions/:id         -> practice-set detail w/ answers       [X-Admin-Pin]
//   DELETE /api/english/sessions/:id       -> delete a practice-set record         [X-Admin-Pin]
//   GET  /english-audio/:id.wav           -> TTS audio for a spelling question (cached)
//
// Env vars: PORT (default 2021), ADMIN_PIN (default 1234), DB_PATH,
//           TTS_SERVICE_URL (default http://127.0.0.1:3091), TTS_INSTRUCT (voice style),
//           SAY_VOICE_ZH / SAY_VOICE_EN (macOS `say` fallback voices, used when the
//           Qwen3 TTS service is busy/unavailable after one retry)

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { DatabaseSync } = require("node:sqlite");

const PORT = parseInt(process.env.PORT || "2021", 10);
const ADMIN_PIN = process.env.ADMIN_PIN || "1234";
const KID_PIN = process.env.KID_PIN || "4321"; // unlock the kid view (change before deploying)
const DB_PATH = process.env.DB_PATH || path.join(__dirname, "kidreminder.db");
const ADMIN_HTML_PATH = path.join(__dirname, "admin.html");
const SPRITES_DIR = path.join(__dirname, "sprites");
// Science question crops, produced offline by tools/science-oeq/crop_questions.py.
// Read-only like sprites/ — nothing in the server ever writes here, so there is
// no upload path to secure.
const SCIENCE_IMAGES_DIR = path.join(__dirname, "science-images");
const DICTATION_AUDIO_DIR = path.join(__dirname, "dictation-audio");
const ENGLISH_AUDIO_DIR = path.join(__dirname, "english-audio");
const CUSTOM_DICTATION_AUDIO_DIR = path.join(__dirname, "custom-dictation-audio");
fs.mkdirSync(DICTATION_AUDIO_DIR, { recursive: true });
fs.mkdirSync(ENGLISH_AUDIO_DIR, { recursive: true });
fs.mkdirSync(CUSTOM_DICTATION_AUDIO_DIR, { recursive: true });
fs.mkdirSync(SCIENCE_IMAGES_DIR, { recursive: true });

// ---------------------------------------------------------------- TTS (dsh-sister's Qwen3-TTS, loopback-only)
// Reuses the existing dsh-sister-tts service (Qwen3-TTS-VoiceDesign on MLX) rather than
// macOS's built-in `say` — much more natural, but slower (single dedicated generation
// thread, shared with dsh-sister) and billed per request, so results are cached forever
// per word_id (see ensureDictationAudio). Uses /tts-stream, not the plain /tts endpoint:
// per the service's own docs, streaming starts producing audio in ~1s instead of paying a
// multi-second fixed per-call cost before any audio exists at all — worth it even though we
// wait for the full stream here, because it's the faster generation path for short clips.
const TTS_SERVICE_URL = process.env.TTS_SERVICE_URL || "http://127.0.0.1:3091";
const TTS_INSTRUCT = process.env.TTS_INSTRUCT ||
  "温柔知性、成熟大方的大姐姐嗓音，语速适中、吐字清晰标准，语气温暖有耐心，" +
  "像在陪伴弟弟妹妹认真学习时耐心引导、适时给予鼓励的感觉，不要撒娇卖萌。";
const TTS_INSTRUCT_EN = process.env.TTS_INSTRUCT_EN ||
  "清晰标准的英语女声朗读，语速适中偏慢、发音清楚、每个单词吐字分明，" +
  "像老师在念听写单词和例句一样，方便孩子听音辨词、练习拼写。";

// Fallback when the Qwen3 service is unavailable/backlogged (shared with dsh-sister,
// so it does get busy): macOS's built-in `say` — much lower quality, but instant and
// always available, so the kid gets *some* audio instead of a dead 🔊 button.
const SAY_VOICE_ZH = process.env.SAY_VOICE_ZH || "Tingting"; // built-in zh_CN voice
const SAY_VOICE_EN = process.env.SAY_VOICE_EN || "Samantha"; // built-in en_US voice
function synthesizeWithSay(text, voice, outFile) {
  execFileSync("say", ["-v", voice, "-o", outFile, "--file-format=WAVE", "--data-format=LEI16@22050", text], {
    timeout: 15000,
  });
}

// Tries the Qwen3 service (with one retry after a brief pause), falling back to `say`
// if both attempts fail — so a busy/unavailable TTS backend still yields *some* audio
// for the 🔊 button instead of a dead one. Writes the result straight to `file`.
async function synthesizeToFile(file, text, instruct, sayVoice) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.writeFileSync(file, await synthesizeSpeech(text, instruct));
      return;
    } catch (err) {
      if (attempt === 0) await new Promise((r) => setTimeout(r, 2000));
      else console.error(`[kid-reminder] Qwen3 TTS failed twice (${err.message}), falling back to say`);
    }
  }
  synthesizeWithSay(text, sayVoice, file);
}

// Minimal canonical-PCM-WAV reader. The TTS service writes plain libsndfile PCM_16 WAVs
// (no exotic chunks), so a straightforward RIFF walk is enough — no library needed.
function parseWav(buf) {
  if (buf.toString("ascii", 0, 4) !== "RIFF" || buf.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error("not a RIFF/WAVE file");
  }
  let offset = 12;
  let fmt = null, data = null;
  while (offset + 8 <= buf.length) {
    const id = buf.toString("ascii", offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    const body = buf.subarray(offset + 8, offset + 8 + size);
    if (id === "fmt ") {
      fmt = { channels: body.readUInt16LE(2), sampleRate: body.readUInt32LE(4), bitsPerSample: body.readUInt16LE(14) };
    } else if (id === "data") {
      data = body;
    }
    offset += 8 + size + (size % 2); // chunks are word-aligned
  }
  if (!fmt || !data) throw new Error("wav chunk missing fmt/data");
  return { ...fmt, data };
}

// Builds one canonical 16-bit PCM WAV from raw sample bytes (the inverse of parseWav).
function buildWav({ sampleRate, channels, bitsPerSample, data }) {
  const blockAlign = channels * (bitsPerSample / 8);
  const header = Buffer.alloc(44);
  header.write("RIFF", 0, "ascii");
  header.writeUInt32LE(36 + data.length, 4);
  header.write("WAVE", 8, "ascii");
  header.write("fmt ", 12, "ascii");
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * blockAlign, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(bitsPerSample, 34);
  header.write("data", 36, "ascii");
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

// Calls /tts-stream (Server-Sent Events: `data: {"audio": "<base64 wav segment>", "isFinal": bool}`
// per ~2s segment) and stitches the segments back into one complete WAV.
async function synthesizeSpeech(text, instruct = TTS_INSTRUCT) {
  const url = `${TTS_SERVICE_URL}/tts-stream?${new URLSearchParams({ text, instruct })}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`tts service HTTP ${res.status}`);
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  let fmt = null;
  const chunks = [];
  outer: while (true) {
    const { value, done: streamDone } = await reader.read();
    if (streamDone) break;
    buffered += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buffered.indexOf("\n\n")) !== -1) {
      const rawEvent = buffered.slice(0, idx);
      buffered = buffered.slice(idx + 2);
      const lines = rawEvent.split("\n");
      const eventType = (lines.find((l) => l.startsWith("event:")) || "").slice(6).trim();
      const dataLine = lines.find((l) => l.startsWith("data:"));
      if (!dataLine) continue;
      const payload = JSON.parse(dataLine.slice(5).trim());
      if (eventType === "error") throw new Error(payload.error || "tts generation failed");
      const wav = parseWav(Buffer.from(payload.audio, "base64"));
      if (!fmt) fmt = { sampleRate: wav.sampleRate, channels: wav.channels, bitsPerSample: wav.bitsPerSample };
      chunks.push(wav.data);
      if (payload.isFinal) break outer;
    }
  }
  if (!fmt || !chunks.length) throw new Error("tts stream produced no audio");
  return buildWav({ ...fmt, data: Buffer.concat(chunks) });
}

// 听写：生成/缓存一个词的朗读音频（词语 + 例句）。每个 word_id 只合成一次，缓存成
// dictation-audio/<id>.wav；vocab_words 的文字被编辑或删除时，对应缓存会被清掉
// （见 /api/vocab 的 PATCH/DELETE），下次用到再重新生成。一次重试：TTS 服务和
// dsh-sister 共用同一条生成队列，偶尔会因为并发繁忙短暂 503，等一下再试一次；两次都
// 失败就退回本机自带的 say 朗读（音质差很多，但总比按了🔊没反应强）。
//
// inFlight 去重：一份听写表生成后会在后台预热整份表的音频（见 precacheDictationAudio），
// 如果孩子playback的请求和预热请求前后脚打到同一个 word_id，两边都等同一个 Promise，
// 不会对同一个词并发合成两次、抢同一个文件写。
const inFlightDictationAudio = new Map(); // word_id -> Promise<string filePath>
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

// 后台预热：一份听写表生成/续上后，按听写顺序依次把整份表的音频合成好，这样孩子点
// "下一题"时大概率已经缓存好，不用现场等 TTS。故意串行（不是 Promise.all 并发炸一遍）——
// TTS 服务和 dsh-sister 共用同一条生成队列，并发轰炸只会让谁都变慢。已缓存的词
// ensureDictationAudio 会立刻返回，不占用生成队列。单个词失败不影响其他词继续预热，
// 也不影响孩子真正播放时按需生成的兜底路径。
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
function deleteDictationAudio(wordId) {
  try { fs.unlinkSync(path.join(DICTATION_AUDIO_DIR, `${wordId}.wav`)); } catch { /* no cache yet */ }
}

// 自定义听写表：跟 ensureDictationAudio 完全一样的缓存/去重/say兜底逻辑，只是词来自
// dictation_list_items（自由文本，不是 vocab_words），缓存到单独的目录，用
// item_id（而不是 vocab_words 的 id）做文件名，避免两边 id 撞在一起。
const inFlightCustomDictationAudio = new Map(); // list_item_id -> Promise<string filePath>
async function ensureCustomDictationAudio(itemId, text) {
  const file = path.join(CUSTOM_DICTATION_AUDIO_DIR, `${itemId}.wav`);
  if (fs.existsSync(file)) return file;
  if (inFlightCustomDictationAudio.has(itemId)) return inFlightCustomDictationAudio.get(itemId);
  const promise = (async () => {
    await synthesizeToFile(file, text, TTS_INSTRUCT, SAY_VOICE_ZH);
    return file;
  })();
  inFlightCustomDictationAudio.set(itemId, promise);
  try {
    return await promise;
  } finally {
    inFlightCustomDictationAudio.delete(itemId);
  }
}
// 后台预热：跟 precacheDictationAudio 一样的思路，串行、跳过已缓存的、单条失败不影响
// 其他条。触发点是 GET /api/dictation-lists/:id ——家长/孩子打开"管理"或者孩子开始
// 播放这份表时都会调用，所以加完词看一眼、或者点开始听写，都会顺带把还没缓存的补上。
function precacheCustomDictationAudio(items) {
  (async () => {
    for (const item of items) {
      try {
        await ensureCustomDictationAudio(item.id, item.text);
      } catch (err) {
        console.error(`[kid-reminder] precache failed for custom list item ${item.id}: ${err.message}`);
      }
    }
  })();
}
function deleteCustomDictationAudio(itemId) {
  try { fs.unlinkSync(path.join(CUSTOM_DICTATION_AUDIO_DIR, `${itemId}.wav`)); } catch { /* no cache yet */ }
}

// Fills a fill_blank prompt's blank marker with the correct answer, for the 🔊
// replay-sentence button on spelling items. The source data uses a few different
// blank-marker conventions (bold parenthetical, escaped underscores, plain
// underscores) — try each in turn; if none match, just read prompt + answer.
// Markdown bold markers are stripped afterwards so TTS doesn't read "asterisk".
function fillBlankSentence(prompt, correctAnswer) {
  const answer = correctAnswer.split("/")[0].trim(); // first alternative only
  const blankPatterns = [/\*\*\([^)]*\)\*\*/, /\*\*\\_+\*\*/, /\\_+/, /\*\*_+\*\*/, /_{2,}/];
  let sentence = null;
  for (const p of blankPatterns) {
    if (p.test(prompt)) { sentence = prompt.replace(p, answer); break; }
  }
  if (!sentence) sentence = `${prompt} — ${answer}`;
  return sentence.replace(/\*\*/g, "");
}

// 英语错题练习：拼写题的🔊按钮朗读"填对后的完整句子"。缓存规则和听写一样，按
// question_id 存一次；题目文字被编辑/删除时缓存会被清掉，下次用到再重新生成。同样在
// Qwen3 两次都失败后退回本机 say。
async function ensureEnglishAudio(questionId, prompt, correctAnswer) {
  const file = path.join(ENGLISH_AUDIO_DIR, `${questionId}.wav`);
  if (fs.existsSync(file)) return file;
  const text = fillBlankSentence(prompt, correctAnswer);
  await synthesizeToFile(file, text, TTS_INSTRUCT_EN, SAY_VOICE_EN);
  return file;
}
function deleteEnglishAudio(questionId) {
  try { fs.unlinkSync(path.join(ENGLISH_AUDIO_DIR, `${questionId}.wav`)); } catch { /* no cache yet */ }
}

// Pokémon collection: 9 generations (Kanto..Paldea). The kid spends stamps to
// randomly unlock sprites (served from sprites/<dex>.png). A generation becomes
// available once the previous one is fully caught. Non-commercial private use of
// public PokéAPI sprite art. info.json = { "<dex>": {name, types} }.
const GENERATIONS = [
  { name: "Kanto",   start: 1,   end: 151 },
  { name: "Johto",   start: 152, end: 251 },
];
const POKEDEX_INFO = (() => {
  try { return JSON.parse(fs.readFileSync(path.join(__dirname, "sprites", "info.json"), "utf8")); }
  catch { return {}; }
})();

function pokemonInfo(dex) {
  const info = POKEDEX_INFO[String(dex)] || {};
  const cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : "???");
  return { dex, name: cap(info.name || "Pokémon #" + dex), types: info.types || [] };
}

// generation index for a dex number (0-based), or null
function generationOf(dex) {
  return GENERATIONS.findIndex((g) => dex >= g.start && dex <= g.end);
}

// all dex numbers in a generation
function generationDexes(genIdx) {
  const g = GENERATIONS[genIdx];
  const out = [];
  for (let dex = g.start; dex <= g.end; dex++) out.push(dex);
  return out;
}

// which generations are playable: gen 0 always; gen N when gen N-1 fully caught
function generationAvailability(caughtSet) {
  const available = [];
  for (let i = 0; i < GENERATIONS.length; i++) {
    const prevDone = i === 0 || generationDexes(i - 1).every((dex) => caughtSet.has(dex));
    available.push(prevDone);
  }
  return available;
}

// ---------------------------------------------------------------- database
const db = new DatabaseSync(DB_PATH);
db.exec(`
  CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT NOT NULL,
    emoji           TEXT NOT NULL DEFAULT '',
    recurring       INTEGER NOT NULL DEFAULT 1,   -- legacy column, kept for migration; use repeat
    repeat          TEXT NOT NULL DEFAULT 'daily',-- daily | weekly | biweekly | monthly | once
    active          INTEGER NOT NULL DEFAULT 1,
    sort            INTEGER NOT NULL DEFAULT 0,
    target_date     TEXT,                          -- task date / schedule anchor / countdown target
    countdown_enabled INTEGER NOT NULL DEFAULT 0,  -- show a countdown towards target_date
    countdown_start INTEGER NOT NULL DEFAULT 7,    -- days before target when countdown activates
    created_by      TEXT NOT NULL DEFAULT 'admin', -- "admin" | "kid" (kids can only delete their own)
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS completions (
    task_id      INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    date         TEXT NOT NULL,              -- YYYY-MM-DD (server-local)
    minutes      INTEGER NOT NULL DEFAULT 0, -- time spent completing, entered when marked done
    completed_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (task_id, date)
  );
  CREATE TABLE IF NOT EXISTS stamps (
    date         TEXT PRIMARY KEY,           -- YYYY-MM-DD (one stamp per day)
    note         TEXT NOT NULL DEFAULT '',   -- e.g. "All tasks done!"
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS unlocks (
    dex          INTEGER PRIMARY KEY,        -- 1..151 which Pokémon was unlocked
    unlocked_at  TEXT NOT NULL DEFAULT (datetime('now'))
  );
  -- Who changed what, so questions like "who awarded these 5 stamps?" have an
  -- answer. Only mutating /api calls are recorded (see AUDIT_PATHS). Stores the
  -- role a request authenticated AS — never the PIN it used.
  CREATE TABLE IF NOT EXISTS audit_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    at           TEXT NOT NULL DEFAULT (datetime('now')),  -- UTC, like every other table here
    role         TEXT NOT NULL,              -- 'admin' | 'kid' | 'none'
    ip           TEXT NOT NULL DEFAULT '',
    method       TEXT NOT NULL,
    path         TEXT NOT NULL,              -- includes ?query when present
    status       INTEGER NOT NULL,           -- response status, so rejected attempts are visible too
    detail       TEXT NOT NULL DEFAULT ''    -- truncated JSON of the request body
  );
  CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_log(at);
  CREATE TABLE IF NOT EXISTS vocab_words (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    language     TEXT NOT NULL DEFAULT 'zh',   -- 'zh' now; 'en' later for English dictation
    level        TEXT NOT NULL,                 -- P1..P6
    lesson_index INTEGER NOT NULL,
    lesson       TEXT NOT NULL,                 -- e.g. "第一课"
    category     TEXT NOT NULL,                 -- 'read' (识读字) | 'write' (识写字)
    character    TEXT NOT NULL,                 -- the base 生字
    word         TEXT NOT NULL,                 -- compound word (词语)
    pinyin       TEXT NOT NULL,
    sentence     TEXT NOT NULL,                 -- example sentence
    correct_count INTEGER NOT NULL DEFAULT 0,   -- 听写正确数：答对+1，答错-1，用来加权随机出题
    source       TEXT NOT NULL DEFAULT 'manual',
    created_at   TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS vocab_words_unique
    ON vocab_words (language, level, lesson_index, category, character, word);
  CREATE TABLE IF NOT EXISTS dictation_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    status       TEXT NOT NULL DEFAULT 'in_progress', -- in_progress | pending_grading | graded
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    graded_at    TEXT
  );
  CREATE TABLE IF NOT EXISTS dictation_items (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES dictation_sessions(id) ON DELETE CASCADE,
    word_id    INTEGER NOT NULL REFERENCES vocab_words(id),
    seq        INTEGER NOT NULL,      -- 1..N, the order it was/will be dictated in
    result     TEXT                    -- NULL (ungraded) | 'correct' | 'incorrect'
  );
  -- 自定义听写表: freeform text entries the parent or kid type in themselves (not drawn
  -- from vocab_words — could be anything: a single word, a phrase, a whole sentence,
  -- e.g. this week's spelling list, or a set of sentences to dictate). No grading, no
  -- session/progress tracking: the app just fetches the list and plays through it in a
  -- fixed order, any number of times.
  CREATE TABLE IF NOT EXISTS dictation_lists (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    created_by TEXT NOT NULL DEFAULT 'admin', -- 'admin' | 'kid'
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS dictation_list_items (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    list_id INTEGER NOT NULL REFERENCES dictation_lists(id) ON DELETE CASCADE,
    seq     INTEGER NOT NULL,     -- fixed playback order, 1..N
    text    TEXT NOT NULL          -- read aloud as-is; a word, a phrase, or a whole sentence
  );
  CREATE TABLE IF NOT EXISTS english_questions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    type           TEXT NOT NULL,                -- 'fill_blank' | 'mcq' | 'sentence_transform'
    topic          TEXT NOT NULL DEFAULT '',      -- e.g. "Grammar: Verb Tenses", "Spelling Errors"
    prompt         TEXT NOT NULL,                 -- the question sentence, with a blank
    options        TEXT,                          -- JSON array of 4 strings, mcq only; NULL otherwise
    correct_answer TEXT NOT NULL,                 -- may contain "alt1 / alt2 / alt3" — any counts as correct
    explanation    TEXT NOT NULL DEFAULT '',       -- shown after answering, regardless of right/wrong
    needs_audio    INTEGER NOT NULL DEFAULT 0,    -- 1 = show a 🔊 replay-sentence button (spelling items)
    correct_count  INTEGER NOT NULL DEFAULT 0,    -- answer +1 / wrong -1, floored at 0 — same as vocab_words
    source_number  INTEGER,                        -- original wrong-answers.md question number, if imported
    source         TEXT NOT NULL DEFAULT 'manual', -- 'wrong-answers-import' | 'manual'
    created_at     TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE TABLE IF NOT EXISTS english_quiz_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    status       TEXT NOT NULL DEFAULT 'in_progress', -- in_progress | completed
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT
  );
  CREATE TABLE IF NOT EXISTS english_quiz_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER NOT NULL REFERENCES english_quiz_sessions(id),
    question_id INTEGER NOT NULL REFERENCES english_questions(id),
    seq         INTEGER NOT NULL,
    answer      TEXT,                 -- what the kid typed/picked
    result      TEXT,                 -- NULL (not yet answered) | 'correct' | 'incorrect'
    overridden  INTEGER NOT NULL DEFAULT 0  -- 1 if the kid flipped an auto-grade via self-override
  );

  -- 科学 (PSLE Science open-ended). Unlike the English bank, a question is NOT
  -- scored right/wrong: PSLE awards one mark per distinct scoring point, so a
  -- question is stored decomposed into its mark points and graded per point.
  -- Each point is tagged with its KIND, which is what makes the diagnosis work:
  -- a missed point says *which* answering technique failed (stopped at the
  -- observation, used an everyday word, ignored the data, missed the controlled
  -- variable), not merely that a mark was lost.
  CREATE TABLE IF NOT EXISTS science_questions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    source_ref    TEXT NOT NULL,        -- e.g. 'acsj-2025-q31b'; unique, makes re-import idempotent
    school        TEXT NOT NULL DEFAULT '',
    year          INTEGER,
    question_no   INTEGER,
    part          TEXT NOT NULL DEFAULT '',
    theme         TEXT NOT NULL DEFAULT '',  -- Diversity | Cycles | Systems | Interactions | Energy
    topic         TEXT NOT NULL DEFAULT '',
    question_type TEXT NOT NULL DEFAULT '',  -- explain | predict_explain | compare | data | experimental_design | draw_label
    answer_mode   TEXT NOT NULL DEFAULT 'text', -- text | short | drawing ('drawing' can't be typed)
    marks         INTEGER NOT NULL,
    context       TEXT NOT NULL DEFAULT '',    -- shared stem shown above the prompt
    prompt        TEXT NOT NULL,
    model_answer  TEXT NOT NULL DEFAULT '',
    image         TEXT NOT NULL DEFAULT '',    -- filename in science-images/
    do_not_accept TEXT NOT NULL DEFAULT '',    -- JSON [{answer, reason}] from the paper's own scheme
    attempts      INTEGER NOT NULL DEFAULT 0,
    -- Unfloored on purpose. The English bank floors this at 0 (server.js
    -- correct_count = MAX(0, ...)), which makes "wrong once" and "wrong eight
    -- times" indistinguishable and breaks weakest-first selection.
    score_total   INTEGER NOT NULL DEFAULT 0,  -- marks earned across all attempts
    -- Groups questions into one paper (e.g. 'acsj-2025') and orders them within
    -- it, so "做完整张卷子" can replay the exam's own question order.
    paper_key     TEXT NOT NULL DEFAULT '',
    paper_seq     INTEGER NOT NULL DEFAULT 0,
    -- Sticky on purpose: a parent-reviewed miss sets this to 1, and it is NEVER
    -- auto-cleared by a later correct answer — only an explicit parent action
    -- (PATCH inMistakeBank:false) removes a question from 错题本. The parent
    -- decides when something is actually mastered, not the keyword matcher.
    in_mistake_bank INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS science_questions_ref ON science_questions(source_ref);

  CREATE TABLE IF NOT EXISTS science_mark_points (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    question_id INTEGER NOT NULL REFERENCES science_questions(id),
    seq         INTEGER NOT NULL,
    point_kind  TEXT NOT NULL,        -- mechanism | observation | keyword | data | comparison | ...
    description TEXT NOT NULL DEFAULT '',  -- model phrasing, shown after answering
    keywords    TEXT NOT NULL DEFAULT '',  -- JSON [[a,b],[c]] = (a OR b) AND c
    any_of      TEXT NOT NULL DEFAULT '',  -- JSON [[groups],[groups]] for the scheme's "Any two"
    need_n      INTEGER NOT NULL DEFAULT 0 -- how many of any_of must match
  );
  CREATE INDEX IF NOT EXISTS science_mark_points_q ON science_mark_points(question_id);

  -- Parent-reviewed, like dictation — not auto-graded like English. The keyword
  -- verdict is provisional and only speeds the review up.
  CREATE TABLE IF NOT EXISTS science_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    status       TEXT NOT NULL DEFAULT 'in_progress', -- in_progress | pending_review | reviewed
    -- 'paper' = one full exam paper in its own order; 'mistakes' = the 错题本
    -- pool in random order; 'weakest' = the original weakest-first pool
    -- (kept for admin/testing, not offered in the app UI anymore).
    mode         TEXT NOT NULL DEFAULT 'weakest',
    paper_key    TEXT NOT NULL DEFAULT '',
    -- school/year are denormalized from the paper's questions at session-create
    -- time, purely so a session list can show "ACS(J) 2025" without a join.
    school       TEXT NOT NULL DEFAULT '',
    year         INTEGER,
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    reviewed_at  TEXT
  );
  CREATE TABLE IF NOT EXISTS science_session_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER NOT NULL REFERENCES science_sessions(id),
    question_id INTEGER NOT NULL REFERENCES science_questions(id),
    seq         INTEGER NOT NULL,
    answer      TEXT,
    auto_score  INTEGER,               -- NULL until answered
    final_score INTEGER                -- NULL until a parent reviews
  );
  CREATE INDEX IF NOT EXISTS science_session_items_s ON science_session_items(session_id);
  -- One row per mark point per answer. This table is the point of the whole
  -- design: without it "which kind of point does he keep missing?" is
  -- unanswerable.
  CREATE TABLE IF NOT EXISTS science_item_points (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id       INTEGER NOT NULL REFERENCES science_session_items(id),
    mark_point_id INTEGER NOT NULL REFERENCES science_mark_points(id),
    auto_hit      INTEGER NOT NULL DEFAULT 0,
    final_hit     INTEGER               -- NULL until reviewed; then 0/1
  );
  CREATE INDEX IF NOT EXISTS science_item_points_i ON science_item_points(item_id);
`);
// migrate older databases that predate newer columns
try { db.exec("ALTER TABLE completions ADD COLUMN minutes INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN target_date TEXT"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN countdown_start INTEGER NOT NULL DEFAULT 7"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN created_by TEXT NOT NULL DEFAULT 'admin'"); } catch { /* exists */ }
try { db.exec("ALTER TABLE tasks ADD COLUMN parent_only INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ } // 1 = only the parent sees/manages it
try {
  db.exec("ALTER TABLE tasks ADD COLUMN repeat TEXT NOT NULL DEFAULT 'daily'");
  db.exec("UPDATE tasks SET repeat = 'once' WHERE recurring = 0"); // migrate legacy one-offs
} catch { /* exists */ }
try {
  db.exec("ALTER TABLE tasks ADD COLUMN countdown_enabled INTEGER NOT NULL DEFAULT 0");
  db.exec("UPDATE tasks SET countdown_enabled = 1 WHERE target_date IS NOT NULL"); // migrate legacy countdowns
} catch { /* exists */ }
try { db.exec("ALTER TABLE vocab_words ADD COLUMN correct_count INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ }
try { db.exec("ALTER TABLE science_questions ADD COLUMN paper_key TEXT NOT NULL DEFAULT ''"); } catch { /* exists */ }
try { db.exec("ALTER TABLE science_questions ADD COLUMN paper_seq INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ }
try { db.exec("ALTER TABLE science_questions ADD COLUMN in_mistake_bank INTEGER NOT NULL DEFAULT 0"); } catch { /* exists */ }
try { db.exec("ALTER TABLE science_sessions ADD COLUMN mode TEXT NOT NULL DEFAULT 'weakest'"); } catch { /* exists */ }
try { db.exec("ALTER TABLE science_sessions ADD COLUMN paper_key TEXT NOT NULL DEFAULT ''"); } catch { /* exists */ }
try { db.exec("ALTER TABLE science_sessions ADD COLUMN school TEXT NOT NULL DEFAULT ''"); } catch { /* exists */ }
try { db.exec("ALTER TABLE science_sessions ADD COLUMN year INTEGER"); } catch { /* exists */ }
// Created here, not in the CREATE TABLE block above: on an already-deployed DB,
// "CREATE TABLE IF NOT EXISTS science_questions" is a no-op (the table already
// exists without paper_key/paper_seq), so an index on those columns placed in
// that block would run BEFORE the ALTER TABLE lines above ever add them and
// fail with "no such column: paper_key" — which crashed the server at startup
// the first time this shipped. Placing the index after the ALTERs guarantees
// the columns exist either way (freshly created here, or already in the
// CREATE TABLE for a brand-new database).
try { db.exec("CREATE INDEX IF NOT EXISTS science_questions_paper ON science_questions(paper_key, paper_seq)"); } catch { /* exists */ }
console.log(`[kid-reminder] db ready at ${DB_PATH}`);

// ---------------------------------------------------------------- helpers
function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// daysBetween(from, to): whole days from "YYYY-MM-DD" to "YYYY-MM-DD" (can be negative)
function daysBetween(from, to) {
  const [y1, m1, d1] = from.split("-").map(Number);
  const [y2, m2, d2] = to.split("-").map(Number);
  const a = Date.UTC(y1, m1 - 1, d1);
  const b = Date.UTC(y2, m2 - 1, d2);
  return Math.round((b - a) / 86400000);
}

// scheduledOn: does a weekly / bi-weekly / monthly task fall on date d?
// anchor is the task's first date (target_date or creation date).
function scheduledOn(repeat, anchor, d) {
  if (d < anchor) return false;
  if (repeat === "weekly") return weekdayOf(d) === weekdayOf(anchor);
  if (repeat === "biweekly") return daysBetween(anchor, d) % 14 === 0;
  if (repeat === "monthly") return dayOfMonth(d) === dayOfMonth(anchor);
  return false;
}
function weekdayOf(iso) { const [y, m, dd] = iso.split("-").map(Number); return new Date(Date.UTC(y, m - 1, dd)).getUTCDay(); }
function dayOfMonth(iso) { return Number(iso.slice(8, 10)); }

// listTasks(dateStr): tasks as-of a given date (default today).
//   recurring tasks appear every day; a one-off task appears until the day it
//   is completed (then hides the next day). "done" reflects that date's record.
function listTasks(dateStr, type) {
  const d = dateStr && /^\d{4}-\d{2}-\d{2}$/.test(dateStr) ? dateStr : today();
  let sql = "SELECT * FROM tasks WHERE active = 1";
  if (type === "todo") sql += " AND countdown_enabled = 0";          // today's checklist
  if (type === "countdown") sql += " AND countdown_enabled = 1 AND target_date IS NOT NULL"; // events
  sql += " ORDER BY sort, id";
  const tasks = db.prepare(sql).all();
  const doneOn = new Map(
    db.prepare("SELECT task_id, minutes FROM completions WHERE date = ?").all(d).map((r) => [r.task_id, r.minutes])
  );
  const doneBefore = new Set(
    db.prepare("SELECT DISTINCT task_id FROM completions WHERE date < ?").all(d).map((r) => r.task_id)
  );
  const result = [];
  for (const task of tasks) {
    if (String(task.created_at).slice(0, 10) > d) continue; // not created yet on that date
    const repeat = task.repeat || "daily";
    if (repeat === "once") {
      if (task.countdown_enabled) {
        // countdown event: hide once it has any completion (today or earlier),
        // so a finished event never reappears in the countdown panel.
        if (doneBefore.has(task.id) || doneOn.has(task.id)) continue;
      } else {
        // a non-countdown one-off shows only on its own day (its date, or the
        // day it was created) and never rolls over.
        if (doneBefore.has(task.id)) continue;
        const onceDate = task.target_date || String(task.created_at).slice(0, 10);
        if (d !== onceDate) continue;
      }
    }
    const anchor = task.target_date || String(task.created_at).slice(0, 10);
    if (repeat !== "daily" && repeat !== "once" && !scheduledOn(repeat, anchor, d)) continue; // off-schedule
    result.push({
      id: task.id,
      title: task.title,
      emoji: task.emoji,
      repeat,
      done: doneOn.has(task.id),
      minutes: doneOn.get(task.id) || 0,
      targetDate: task.target_date || null,
      countdownEnabled: !!task.countdown_enabled,
      countdownStart: task.countdown_start,
      daysLeft: task.target_date ? daysBetween(d, task.target_date) : null,
      createdBy: task.created_by,
      parentOnly: !!task.parent_only,
    });
  }
  return result;
}

// toggleTask(id, minutes): mark done/undone for today. If marking done, stores
// the minutes the kid says they spent on it.
function toggleTask(id, minutes) {
  const task = db.prepare("SELECT id FROM tasks WHERE id = ? AND active = 1").get(id);
  if (!task) return { status: 404, json: { error: "task not found" } };
  const t = today();
  const existing = db.prepare("SELECT task_id FROM completions WHERE task_id = ? AND date = ?").get(id, t);
  if (existing) {
    db.prepare("DELETE FROM completions WHERE task_id = ? AND date = ?").run(id, t);
    return { status: 200, json: { done: false, minutes: 0 } };
  } else {
    const m = Math.max(0, Math.min(999, Math.round(Number(minutes) || 0)));
    db.prepare("INSERT INTO completions (task_id, date, minutes) VALUES (?, ?, ?)").run(id, t, m);
    return { status: 200, json: { done: true, minutes: m } };
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      if (!data.trim()) return resolve({});
      try {
        const parsed = JSON.parse(data);
        req._auditBody = parsed; // stashed so the audit row can summarize it
        resolve(parsed);
      } catch {
        reject(Object.assign(new Error("invalid JSON body"), { status: 400 }));
      }
    });
    req.on("error", reject);
  });
}

// ------------------------------------------------------------------- audit log
// Mutating /api calls are recorded to audit_log so "who did this, from where,
// when" is answerable after the fact. Reads are not logged — they are high
// volume and were never the question.
//
// Deliberately NOT logged: /api/verify. It is the one endpoint that takes a PIN
// in the request *body*, so recording its body would write the admin PIN into
// the database in plaintext. scrubBody() strips pin-like keys as a second layer
// in case a future endpoint does the same thing.
const AUDIT_PATHS = /^\/api\/(stamps|unlock|tasks|vocab|dictation|dictation-lists|english|science)(\/|$)/;
const AUDIT_METHODS = new Set(["POST", "PATCH", "PUT", "DELETE"]);

function auditRole(req) {
  if (req.headers["x-admin-pin"] === ADMIN_PIN) return "admin";
  if (req.headers["x-kid-pin"] === KID_PIN) return "kid";
  return "none";
}

function clientIP(req) {
  const fwd = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();
  return (fwd || req.socket?.remoteAddress || "").replace(/^::ffff:/, "");
}

// Small, non-sensitive summary of the request body. Capped so a long 听写表 or
// composition body can't bloat the table.
function scrubBody(body) {
  if (!body || typeof body !== "object") return "";
  const safe = {};
  for (const [k, v] of Object.entries(body)) {
    if (/pin|password|secret|token/i.test(k)) continue;
    safe[k] = typeof v === "string" ? v.slice(0, 120) : v;
  }
  const json = JSON.stringify(safe);
  return json.length > 500 ? json.slice(0, 500) + "…" : json;
}

function recordAudit(req, method, pathWithQuery, status) {
  try {
    db.prepare(
      "INSERT INTO audit_log (role, ip, method, path, status, detail) VALUES (?, ?, ?, ?, ?, ?)"
    ).run(auditRole(req), clientIP(req), method, pathWithQuery, status, scrubBody(req._auditBody));
  } catch (e) {
    // Logging must never take the server down or fail a legitimate request.
    console.error("audit_log insert failed:", e.message);
  }
}

// normalizes a typed English answer for lenient comparison against correct_answer
// (case/whitespace/punctuation-insensitive) — used by /api/english/sessions/*/submit
function normalizeEnglishAnswer(s) {
  return String(s || "").trim().toLowerCase().replace(/\s+/g, " ").replace(/[.,!?;:"'()]/g, "").trim();
}

// ----------------------------------------------------- 科学 mark-point matching
// Science OEQ answers are free prose, so the English module's exact-after-
// normalisation comparison is useless here. Instead each mark point declares the
// terms that must appear:
//
//   keywords [[a,b],[c]]  ->  (a OR b) AND c
//   any_of + need_n       ->  at least need_n alternatives match ("Any two ...")
//
// Substring matching is deliberate — storing the stem "evaporat" covers
// evaporate/evaporates/evaporation without a stemmer.
//
// This verdict is PROVISIONAL. It cannot see whether the reasoning actually
// hangs together, so a parent confirms every answer before it counts; only the
// confirmed verdict feeds score_total and the failure-mode stats.
function scienceParse(json, fallback) {
  if (!json) return fallback;
  try { return JSON.parse(json); } catch { return fallback; }
}

function scienceGroupHit(text, group) {
  return group.some((term) => text.includes(normalizeEnglishAnswer(term)));
}

function scienceAutoHit(markPoint, answer) {
  const text = normalizeEnglishAnswer(answer);
  if (!text) return false;
  const anyOf = scienceParse(markPoint.any_of, null);
  if (Array.isArray(anyOf) && anyOf.length) {
    const need = markPoint.need_n > 0 ? markPoint.need_n : 1;
    const matched = anyOf.filter((alt) => alt.every((g) => scienceGroupHit(text, g))).length;
    return matched >= need;
  }
  const groups = scienceParse(markPoint.keywords, []);
  if (!Array.isArray(groups) || !groups.length) return false;
  return groups.every((g) => scienceGroupHit(text, g));
}

// ---------------------------------------------------------------- http server
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const pathname = url.pathname.replace(/\/+$/, "") || "/";
  const method = req.method;

  // Every JSON response — including every mutation — funnels through here, so
  // this is the one place the audit hook needs to live. /api/verify is excluded
  // by AUDIT_PATHS because its body carries a PIN (see recordAudit above).
  const shouldAudit = AUDIT_METHODS.has(method) && AUDIT_PATHS.test(pathname);

  const sendJSON = (status, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
    res.end(body);
    if (shouldAudit) recordAudit(req, method, pathname + url.search, status);
  };

  try {
    // --- admin panel --------------------------------------------------
    if (method === "GET" && (pathname === "/" || pathname === "/admin")) {
      const html = fs.readFileSync(ADMIN_HTML_PATH);
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return res.end(html);
    }
    if (method === "GET" && pathname === "/favicon.ico") {
      return res.writeHead(204).end();
    }

    // --- Pokémon sprites (PNG images served from sprites/) ----------------
    if (method === "GET" && pathname.startsWith("/sprites/")) {
      const file = path.basename(pathname); // guard against ../ traversal
      const full = path.join(SPRITES_DIR, file);
      if (!full.startsWith(SPRITES_DIR) || !/^\d+\.png$/.test(file) || !fs.existsSync(full)) {
        return sendJSON(404, { error: "sprite not found" });
      }
      const data = fs.readFileSync(full);
      res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" });
      return res.end(data);
    }

    // --- sound effects (WAV served from sounds/) ---------------------------
    if (method === "GET" && pathname.startsWith("/sounds/") && pathname.endsWith(".wav")) {
      const file = path.basename(pathname); // guard against ../ traversal
      const full = path.join(__dirname, "sounds", file);
      if (!full.startsWith(path.join(__dirname, "sounds")) || !fs.existsSync(full)) {
        return sendJSON(404, { error: "sound not found" });
      }
      const data = fs.readFileSync(full);
      res.writeHead(200, { "Content-Type": "audio/wav", "Cache-Control": "public, max-age=86400" });
      return res.end(data);
    }

    // --- health --------------------------------------------------------
    if (method === "GET" && pathname === "/api/health") {
      return sendJSON(200, { ok: true, today: today() });
    }

    // --- verify PIN (admin or kid) -------------------------------------
    if (method === "POST" && pathname === "/api/verify") {
      const body = await readBody(req);
      if (body.pin === ADMIN_PIN) return sendJSON(200, { ok: true, role: "admin" });
      if (body.pin === KID_PIN) return sendJSON(200, { ok: true, role: "kid" });
      return sendJSON(401, { error: "wrong pin" });
    }

    // --- tasks list (open; parent-only hidden unless admin) -------------
    if (method === "GET" && pathname === "/api/tasks") {
      const reqDate = url.searchParams.get("date") || "";
      const type = url.searchParams.get("type") || ""; // "todo" | "countdown" | "" (all)
      const date = /^\d{4}-\d{2}-\d{2}$/.test(reqDate) ? reqDate : today();
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const tasks = listTasks(date, type).filter((t) => isAdmin || !t.parentOnly);
      const todo = tasks.filter((t) => !t.countdownEnabled);
      const allDone = todo.length > 0 && todo.every((t) => t.done);
      const stamped = !!db.prepare("SELECT 1 FROM stamps WHERE date = ?").get(date);
      return sendJSON(200, { today: today(), date, type, tasks, allDone, stamped });
    }

    // --- stamps: month list (open) ----------------------------------------
    if (method === "GET" && pathname === "/api/stamps") {
      const month = url.searchParams.get("month") || "";
      const rows = month
        ? db.prepare("SELECT date FROM stamps WHERE date LIKE ? ORDER BY date").all(month + "%")
        : db.prepare("SELECT date FROM stamps ORDER BY date").all();
      return sendJSON(200, { stamps: rows.map((r) => r.date) });
    }

    // --- stats: stamp balance + collection progress (open) ---------------
    if (method === "GET" && pathname === "/api/stats") {
      const earned = db.prepare("SELECT COUNT(*) n FROM stamps").get().n;
      const caught = db.prepare("SELECT dex FROM unlocks ORDER BY dex").all().map((r) => r.dex);
      const available = Math.max(0, earned - caught.length); // each unlock spends one stamp
      const caughtSet = new Set(caught);
      const availability = generationAvailability(caughtSet);
      const generations = GENERATIONS.map((g, i) => ({
        name: g.name,
        start: g.start,
        end: g.end,
        total: g.end - g.start + 1,
        caught: generationDexes(i).filter((dex) => caughtSet.has(dex)).length,
        unlocked: availability[i],
        complete: generationDexes(i).every((dex) => caughtSet.has(dex)),
      }));
      return sendJSON(200, {
        stamps: { earned, spent: caught.length, available },
        collection: {
          total: GENERATIONS.reduce((sum, g) => sum + (g.end - g.start + 1), 0),
          caught: caught.map(pokemonInfo),
          generations,
        },
      });
    }

    // --- spend a stamp to randomly unlock a Pokémon (kid or admin) --------
    if (method === "POST" && pathname === "/api/unlock") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const genIdx = Math.max(0, Math.min(GENERATIONS.length - 1, parseInt(url.searchParams.get("gen") || "0", 10) || 0));
      const caught = new Set(db.prepare("SELECT dex FROM unlocks").all().map((r) => r.dex));
      const availability = generationAvailability(caught);
      if (!availability[genIdx]) return sendJSON(400, { error: "finish the previous generation first!" });
      const pool = generationDexes(genIdx).filter((dex) => !caught.has(dex));
      if (pool.length === 0) return sendJSON(400, { error: "this generation is complete!" });
      const earned = db.prepare("SELECT COUNT(*) n FROM stamps").get().n;
      const available = earned - caught.size;
      if (available <= 0) return sendJSON(400, { error: "no stamps to spend — earn one by finishing all tasks!" });
      // random among the uncaught dexes of this generation
      const dex = pool[Math.floor(Math.random() * pool.length)];
      db.prepare("INSERT INTO unlocks (dex) VALUES (?)").run(dex);
      const genComplete = generationDexes(genIdx).every((d) => caught.has(d) || d === dex);
      const nextGen = genComplete && genIdx + 1 < GENERATIONS.length
        ? { name: GENERATIONS[genIdx + 1].name, available: true }
        : null;
      return sendJSON(201, {
        ok: true,
        pokemon: pokemonInfo(dex),
        generation: GENERATIONS[genIdx].name,
        generationComplete: genComplete,
        nextGeneration: nextGen,
        available: available - 1,
        caught: caught.size + 1,
        total: GENERATIONS.reduce((sum, g) => sum + (g.end - g.start + 1), 0),
      });
    }

    // --- award a stamp (admin only; server verifies all-done) -------------
    if (method === "POST" && pathname === "/api/stamps") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      const date = /^\d{4}-\d{2}-\d{2}$/.test(body.date || "") ? body.date : null;
      if (!date) return sendJSON(400, { error: "date (YYYY-MM-DD) is required" });
      const existing = db.prepare("SELECT 1 FROM stamps WHERE date = ?").get(date);
      if (existing) return sendJSON(409, { error: "already stamped" });
      const todo = listTasks(date, "todo").filter((t) => !t.parentOnly);
      const allDone = todo.length > 0 && todo.every((t) => t.done);
      if (!allDone && !body.force) return sendJSON(400, { error: "not all tasks are done on that day" });
      db.prepare("INSERT INTO stamps (date, note) VALUES (?, ?)").run(date, String(body.note || "All tasks done!").slice(0, 200));
      return sendJSON(201, { ok: true, date, allDone });
    }

    // --- revoke a stamp (admin only) --------------------------------------
    const stampMatch = pathname.match(/^\/api\/stamps\/(\d{4}-\d{2}-\d{2})$/);
    if (stampMatch && method === "DELETE") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const info = db.prepare("DELETE FROM stamps WHERE date = ?").run(stampMatch[1]);
      if (!info.changes) return sendJSON(404, { error: "no stamp on that day" });
      return sendJSON(200, { ok: true });
    }

    // --- create task (admin or kid) ------------------------------------
    if (method === "POST" && pathname === "/api/tasks") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const body = await readBody(req);
      const title = (body.title || "").trim();
      if (!title) return sendJSON(400, { error: "title is required" });
      const repeat = ["daily", "weekly", "biweekly", "monthly", "once"].includes(body.repeat)
        ? body.repeat
        : (typeof body.recurring === "boolean" ? (body.recurring ? "daily" : "once") : "once"); // default: once
      const targetDate = /^\d{4}-\d{2}-\d{2}$/.test(body.targetDate || "") ? body.targetDate : null;
      const countdownEnabled = body.countdownEnabled ? 1 : 0;
      const countdownStart = Math.max(1, Math.min(30, Math.round(Number(body.countdownStart) || 7)));
      const parentOnly = !!body.parentOnly;
      if (parentOnly && !isAdmin) return sendJSON(403, { error: "only the parent can create parent-only tasks" });
      const createdBy = isAdmin ? "admin" : "kid";
      const info = db
        .prepare("INSERT INTO tasks (title, emoji, repeat, target_date, countdown_enabled, countdown_start, created_by, parent_only) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        .run(title, String(body.emoji || "").slice(0, 8), repeat, targetDate, countdownEnabled, countdownStart, createdBy, parentOnly ? 1 : 0);
      return sendJSON(201, { id: Number(info.lastInsertRowid), createdBy });
    }

    // --- task by id -----------------------------------------------------
    const taskMatch = pathname.match(/^\/api\/tasks\/(\d+)(\/toggle)?$/);
    if (taskMatch) {
      const id = Number(taskMatch[1]);
      const isToggle = !!taskMatch[2];

      // toggle done (kid's app, open; parent-only locked for kid)
      if (method === "POST" && isToggle) {
        const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
        const isKid = req.headers["x-kid-pin"] === KID_PIN;
        if (isKid && !isAdmin) {
          const t = db.prepare("SELECT parent_only FROM tasks WHERE id = ?").get(id);
          if (t && t.parent_only) return sendJSON(403, { error: "parent-only tasks are locked for the kid" });
        }
        const body = await readBody(req);
        const result = toggleTask(id, body.minutes);
        return sendJSON(result.status, result.json);
      }

      // edit (admin any; kid only their own tasks)
      if (method === "PATCH") {
        const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
        const isKid = req.headers["x-kid-pin"] === KID_PIN;
        if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
        const task = db.prepare("SELECT created_by, parent_only FROM tasks WHERE id = ?").get(id);
        if (!task) return sendJSON(404, { error: "task not found" });
        if (isKid) {
          if (task.parent_only) return sendJSON(403, { error: "parent-only tasks are locked for the kid" });
          if (task.created_by !== "kid") return sendJSON(403, { error: "kids can only edit their own tasks" });
        }
        const body = await readBody(req);
        if (body.parentOnly !== undefined && !isAdmin) return sendJSON(403, { error: "only the parent can change parent-only" });
        const sets = [];
        const vals = [];
        if (body.title !== undefined) { sets.push("title = ?"); vals.push(String(body.title).trim()); }
        if (body.emoji !== undefined) { sets.push("emoji = ?"); vals.push(String(body.emoji).slice(0, 8)); }
        if (body.repeat !== undefined) { sets.push("repeat = ?"); vals.push(["daily","weekly","biweekly","monthly","once"].includes(body.repeat) ? body.repeat : "once"); }
        else if (body.recurring !== undefined) { sets.push("repeat = ?"); vals.push(body.recurring ? "daily" : "once"); }
        if (body.active !== undefined) { sets.push("active = ?"); vals.push(body.active ? 1 : 0); }
        if (body.targetDate !== undefined) { sets.push("target_date = ?"); vals.push(/^\d{4}-\d{2}-\d{2}$/.test(body.targetDate || "") ? body.targetDate : null); }
        if (body.countdownEnabled !== undefined) { sets.push("countdown_enabled = ?"); vals.push(body.countdownEnabled ? 1 : 0); }
        if (body.countdownStart !== undefined) { sets.push("countdown_start = ?"); vals.push(Math.max(1, Math.min(30, Math.round(Number(body.countdownStart) || 7)))); }
        if (body.parentOnly !== undefined) { sets.push("parent_only = ?"); vals.push(body.parentOnly ? 1 : 0); }
        if (!sets.length) return sendJSON(400, { error: "nothing to update" });
        vals.push(id);
        const info = db.prepare(`UPDATE tasks SET ${sets.join(", ")} WHERE id = ?`).run(...vals);
        if (!info.changes) return sendJSON(404, { error: "task not found" });
        return sendJSON(200, { ok: true });
      }

      // delete (admin any; kid only their own tasks)
      if (method === "DELETE") {
        const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
        const isKid = req.headers["x-kid-pin"] === KID_PIN;
        if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
        const task = db.prepare("SELECT created_by, parent_only FROM tasks WHERE id = ?").get(id);
        if (!task) return sendJSON(404, { error: "task not found" });
        if (!isAdmin && (task.parent_only || task.created_by !== "kid")) return sendJSON(403, { error: "kids can only delete their own tasks" });
        db.prepare("DELETE FROM tasks WHERE id = ?").run(id);
        return sendJSON(200, { ok: true });
      }
    }

    // --- vocab words (dictation word bank) — admin only ------------------
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

      const total = db.prepare(`SELECT COUNT(*) n FROM vocab_words ${whereSql}`).get(...params).n;
      const words = db
        .prepare(`SELECT * FROM vocab_words ${whereSql} ORDER BY level, lesson_index, id LIMIT ? OFFSET ?`)
        .all(...params, limit, offset);
      return sendJSON(200, { total, limit, offset, words });
    }

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

    const vocabMatch = pathname.match(/^\/api\/vocab\/(\d+)$/);
    if (vocabMatch) {
      const id = Number(vocabMatch[1]);
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });

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

      if (method === "DELETE") {
        // a word referenced by past dictation_items (even an old graded session) used to
        // fail here with a raw "FOREIGN KEY constraint failed" 500 — deleting a word the
        // parent explicitly asked to remove is more useful than blocking on stale history
        // that references it, so clear those references first.
        db.prepare("DELETE FROM dictation_items WHERE word_id = ?").run(id);
        const info = db.prepare("DELETE FROM vocab_words WHERE id = ?").run(id);
        if (!info.changes) return sendJSON(404, { error: "word not found" });
        deleteDictationAudio(id);
        return sendJSON(200, { ok: true });
      }
    }

    // --- dictation audio: lazily synthesized + cached, served as static files ---
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
        console.error(`[kid-reminder] TTS failed for word ${wordId}: ${err.message}`);
        return sendJSON(502, { error: "TTS service unavailable, try again shortly" });
      }
      const data = fs.readFileSync(filePath);
      res.writeHead(200, { "Content-Type": "audio/wav", "Cache-Control": "public, max-age=31536000" });
      return res.end(data);
    }

    // --- dictation sessions: generate a listening-test set (open; kid app calls this) ---
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

    // --- mark a session finished by the kid; now awaiting parent grading (open) ---
    const completeMatch = pathname.match(/^\/api\/dictation\/sessions\/(\d+)\/complete$/);
    if (completeMatch && method === "POST") {
      const id = Number(completeMatch[1]);
      const session = db.prepare("SELECT status FROM dictation_sessions WHERE id = ?").get(id);
      if (!session) return sendJSON(404, { error: "session not found" });
      db.prepare("UPDATE dictation_sessions SET status = 'pending_grading', completed_at = datetime('now') WHERE id = ?").run(id);
      return sendJSON(200, { ok: true });
    }

    // --- list sessions: all history by default, or filter by ?status= (admin, or the
    // kid app viewing its own graded results — see DictationHistoryView) ---
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

    // --- session detail: ordered items joined to their word (admin grading, or the kid
    // app viewing its own graded results — see DictationHistoryView) ---
    const sessDetailMatch = pathname.match(/^\/api\/dictation\/sessions\/(\d+)$/);
    if (sessDetailMatch && method === "GET") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const id = Number(sessDetailMatch[1]);
      const session = db.prepare("SELECT * FROM dictation_sessions WHERE id = ?").get(id);
      if (!session) return sendJSON(404, { error: "session not found" });
      const items = db
        .prepare(
          `SELECT i.id, i.seq, i.result, w.id word_id, w.character, w.word, w.pinyin, w.sentence, w.level, w.lesson
           FROM dictation_items i JOIN vocab_words w ON w.id = i.word_id
           WHERE i.session_id = ? ORDER BY i.seq`
        )
        .all(id);
      return sendJSON(200, { session, items });
    }

    // --- delete a session (any status — e.g. an abandoned "in_progress" one the kid
    // never finished, or just old history the parent wants to tidy up) (admin only) ---
    if (sessDetailMatch && method === "DELETE") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(sessDetailMatch[1]);
      // ON DELETE CASCADE in the schema isn't automatic — node:sqlite's
      // DatabaseSync actually enforces foreign_keys by default (confirmed:
      // `PRAGMA foreign_keys` reports 1, contrary to what an earlier version of
      // this comment claimed), which makes deleting children first mandatory,
      // not just tidy: deleting dictation_sessions first would throw.
      db.prepare("DELETE FROM dictation_items WHERE session_id = ?").run(id);
      const info = db.prepare("DELETE FROM dictation_sessions WHERE id = ?").run(id);
      if (!info.changes) return sendJSON(404, { error: "session not found" });
      return sendJSON(200, { ok: true });
    }

    // --- submit grading: per-item correct/incorrect, updates correct_count (admin only) ---
    const gradeMatch = pathname.match(/^\/api\/dictation\/sessions\/(\d+)\/grade$/);
    if (gradeMatch && method === "POST") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(gradeMatch[1]);
      const session = db.prepare("SELECT id FROM dictation_sessions WHERE id = ?").get(id);
      if (!session) return sendJSON(404, { error: "session not found" });
      const body = await readBody(req);
      const results = Array.isArray(body.results) ? body.results : [];
      if (!results.length) return sendJSON(400, { error: "results array is required" });

      const getItem = db.prepare("SELECT id, word_id FROM dictation_items WHERE id = ? AND session_id = ?");
      const setResult = db.prepare("UPDATE dictation_items SET result = ? WHERE id = ?");
      const bumpCorrect = db.prepare("UPDATE vocab_words SET correct_count = MAX(0, correct_count + 1) WHERE id = ?");
      const bumpWrong = db.prepare("UPDATE vocab_words SET correct_count = MAX(0, correct_count - 1) WHERE id = ?");

      db.exec("BEGIN");
      try {
        for (const r of results) {
          if (!["correct", "incorrect"].includes(r.result)) continue;
          const item = getItem.get(r.itemId, id);
          if (!item) continue;
          setResult.run(r.result, item.id);
          (r.result === "correct" ? bumpCorrect : bumpWrong).run(item.word_id);
        }
        db.prepare("UPDATE dictation_sessions SET status = 'graded', graded_at = datetime('now') WHERE id = ?").run(id);
        db.exec("COMMIT");
      } catch (err) {
        db.exec("ROLLBACK");
        throw err;
      }
      return sendJSON(200, { ok: true });
    }

    // --- 自定义听写表: freeform lists the parent or kid types in themselves (not drawn
    // from vocab_words). No grading, no session state — the app just fetches the list
    // and plays through it, any number of times. Full CRUD is open to both admin and
    // kid pins (unlike vocab/English banks) — this is explicitly self-managed content. ---
    if (method === "GET" && pathname === "/api/dictation-lists") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const lists = db
        .prepare(
          `SELECT l.id, l.name, l.created_by, l.created_at, COUNT(i.id) itemCount
           FROM dictation_lists l LEFT JOIN dictation_list_items i ON i.list_id = l.id
           GROUP BY l.id ORDER BY l.created_at DESC`
        )
        .all();
      return sendJSON(200, { lists });
    }

    if (method === "POST" && pathname === "/api/dictation-lists") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const body = await readBody(req);
      const name = String(body.name || "").trim();
      if (!name) return sendJSON(400, { error: "name is required" });
      const info = db
        .prepare("INSERT INTO dictation_lists (name, created_by) VALUES (?, ?)")
        .run(name, isAdmin ? "admin" : "kid");
      return sendJSON(201, { id: Number(info.lastInsertRowid) });
    }

    const listMatch = pathname.match(/^\/api\/dictation-lists\/(\d+)$/);
    if (listMatch) {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const id = Number(listMatch[1]);

      if (method === "GET") {
        const list = db.prepare("SELECT id, name, created_by, created_at FROM dictation_lists WHERE id = ?").get(id);
        if (!list) return sendJSON(404, { error: "list not found" });
        const items = db.prepare("SELECT id, seq, text FROM dictation_list_items WHERE list_id = ? ORDER BY seq").all(id);
        precacheCustomDictationAudio(items);
        return sendJSON(200, { list, items });
      }

      if (method === "PATCH") {
        const body = await readBody(req);
        const name = String(body.name || "").trim();
        if (!name) return sendJSON(400, { error: "name is required" });
        const info = db.prepare("UPDATE dictation_lists SET name = ? WHERE id = ?").run(name, id);
        if (!info.changes) return sendJSON(404, { error: "list not found" });
        return sendJSON(200, { ok: true });
      }

      if (method === "DELETE") {
        const itemIds = db.prepare("SELECT id FROM dictation_list_items WHERE list_id = ?").all(id).map((r) => r.id);
        db.prepare("DELETE FROM dictation_list_items WHERE list_id = ?").run(id);
        const info = db.prepare("DELETE FROM dictation_lists WHERE id = ?").run(id);
        if (!info.changes) return sendJSON(404, { error: "list not found" });
        for (const itemId of itemIds) deleteCustomDictationAudio(itemId);
        return sendJSON(200, { ok: true });
      }
    }

    const listItemsMatch = pathname.match(/^\/api\/dictation-lists\/(\d+)\/items$/);
    if (listItemsMatch && method === "POST") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const listId = Number(listItemsMatch[1]);
      const list = db.prepare("SELECT id FROM dictation_lists WHERE id = ?").get(listId);
      if (!list) return sendJSON(404, { error: "list not found" });
      const body = await readBody(req);
      const text = String(body.text || "").trim();
      if (!text) return sendJSON(400, { error: "text is required" });
      const nextSeq = (db.prepare("SELECT COALESCE(MAX(seq), 0) n FROM dictation_list_items WHERE list_id = ?").get(listId)).n + 1;
      const info = db
        .prepare("INSERT INTO dictation_list_items (list_id, seq, text) VALUES (?, ?, ?)")
        .run(listId, nextSeq, text);
      return sendJSON(201, { id: Number(info.lastInsertRowid) });
    }

    const listItemMatch = pathname.match(/^\/api\/dictation-lists\/(\d+)\/items\/(\d+)$/);
    if (listItemMatch) {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const listId = Number(listItemMatch[1]);
      const itemId = Number(listItemMatch[2]);

      if (method === "PATCH") {
        const body = await readBody(req);
        if (body.text === undefined) return sendJSON(400, { error: "nothing to update" });
        const text = String(body.text).trim();
        if (!text) return sendJSON(400, { error: "text is required" });
        const info = db.prepare("UPDATE dictation_list_items SET text = ? WHERE id = ? AND list_id = ?").run(text, itemId, listId);
        if (!info.changes) return sendJSON(404, { error: "item not found" });
        deleteCustomDictationAudio(itemId); // text changed -> stale cache, regenerate lazily
        return sendJSON(200, { ok: true });
      }

      if (method === "DELETE") {
        const info = db.prepare("DELETE FROM dictation_list_items WHERE id = ? AND list_id = ?").run(itemId, listId);
        if (!info.changes) return sendJSON(404, { error: "item not found" });
        deleteCustomDictationAudio(itemId);
        return sendJSON(200, { ok: true });
      }
    }

    // --- custom-list audio: same lazy-generate-and-cache pattern as /dictation-audio/ ---
    if (method === "GET" && pathname.startsWith("/custom-dictation-audio/")) {
      const file = path.basename(pathname);
      const m = file.match(/^(\d+)\.wav$/);
      if (!m) return sendJSON(404, { error: "not found" });
      const itemId = Number(m[1]);
      const item = db.prepare("SELECT text FROM dictation_list_items WHERE id = ?").get(itemId);
      if (!item) return sendJSON(404, { error: "item not found" });
      let filePath;
      try {
        filePath = await ensureCustomDictationAudio(itemId, item.text);
      } catch (err) {
        console.error(`[kid-reminder] custom dictation TTS failed for item ${itemId}: ${err.message}`);
        return sendJSON(502, { error: "TTS service unavailable, try again shortly" });
      }
      const data = fs.readFileSync(filePath);
      res.writeHead(200, { "Content-Type": "audio/wav", "Cache-Control": "public, max-age=31536000" });
      return res.end(data);
    }

    // --- English wrong-answer practice: question bank CRUD -----------------
    if (method === "GET" && pathname === "/api/english/questions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const search = (url.searchParams.get("search") || "").trim();
      const type = url.searchParams.get("type") || "";
      const topic = url.searchParams.get("topic") || "";
      const limit = Math.max(1, Math.min(200, parseInt(url.searchParams.get("limit") || "50", 10) || 50));
      const offset = Math.max(0, parseInt(url.searchParams.get("offset") || "0", 10) || 0);

      const where = [];
      const params = [];
      if (search) {
        where.push("(prompt LIKE ? OR correct_answer LIKE ? OR explanation LIKE ? OR topic LIKE ?)");
        const like = `%${search}%`;
        params.push(like, like, like, like);
      }
      if (type) { where.push("type = ?"); params.push(type); }
      if (topic) { where.push("topic = ?"); params.push(topic); }
      const whereSql = where.length ? `WHERE ${where.join(" AND ")}` : "";

      const total = db.prepare(`SELECT COUNT(*) n FROM english_questions ${whereSql}`).get(...params).n;
      const rows = db
        .prepare(`SELECT * FROM english_questions ${whereSql} ORDER BY id DESC LIMIT ? OFFSET ?`)
        .all(...params, limit, offset);
      const questions = rows.map((r) => ({ ...r, options: r.options ? JSON.parse(r.options) : null }));
      return sendJSON(200, { total, limit, offset, questions });
    }

    // create (admin or kid — the macOS app's "add a mistake" form uses this too)
    if (method === "POST" && pathname === "/api/english/questions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      const isKid = req.headers["x-kid-pin"] === KID_PIN;
      if (!isAdmin && !isKid) return sendJSON(401, { error: "admin or kid pin required" });
      const body = await readBody(req);
      const type = ["fill_blank", "mcq", "sentence_transform"].includes(body.type) ? body.type : null;
      const prompt = String(body.prompt || "").trim();
      const correctAnswer = String(body.correctAnswer || "").trim();
      if (!type || !prompt || !correctAnswer) {
        return sendJSON(400, { error: "type, prompt, correctAnswer are required" });
      }
      let options = null;
      if (type === "mcq") {
        if (!Array.isArray(body.options) || body.options.length < 2) {
          return sendJSON(400, { error: "mcq questions need an options array (2+ choices)" });
        }
        options = JSON.stringify(body.options.map((o) => String(o).trim()));
      }
      const topic = String(body.topic || "").trim();
      const explanation = String(body.explanation || "").trim();
      const needsAudio = type === "fill_blank" && !!body.needsAudio;
      const info = db
        .prepare(
          `INSERT INTO english_questions (type, topic, prompt, options, correct_answer, explanation, needs_audio, source)
           VALUES (?, ?, ?, ?, ?, ?, ?, 'manual')`
        )
        .run(type, topic, prompt, options, correctAnswer, explanation, needsAudio ? 1 : 0);
      return sendJSON(201, { id: Number(info.lastInsertRowid) });
    }

    const engQMatch = pathname.match(/^\/api\/english\/questions\/(\d+)$/);
    if (engQMatch) {
      const id = Number(engQMatch[1]);
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });

      if (method === "PATCH") {
        const body = await readBody(req);
        const sets = [];
        const vals = [];
        if (body.type !== undefined && ["fill_blank", "mcq", "sentence_transform"].includes(body.type)) {
          sets.push("type = ?"); vals.push(body.type);
        }
        const strField = (key, col) => { if (body[key] !== undefined) { sets.push(`${col} = ?`); vals.push(String(body[key]).trim()); } };
        strField("topic", "topic");
        strField("prompt", "prompt");
        strField("correctAnswer", "correct_answer");
        strField("explanation", "explanation");
        if (body.options !== undefined) { sets.push("options = ?"); vals.push(Array.isArray(body.options) ? JSON.stringify(body.options.map((o) => String(o).trim())) : null); }
        if (body.needsAudio !== undefined) { sets.push("needs_audio = ?"); vals.push(body.needsAudio ? 1 : 0); }
        if (body.correctCount !== undefined) { sets.push("correct_count = ?"); vals.push(Math.round(Number(body.correctCount)) || 0); }
        if (!sets.length) return sendJSON(400, { error: "nothing to update" });
        vals.push(id);
        const info = db.prepare(`UPDATE english_questions SET ${sets.join(", ")} WHERE id = ?`).run(...vals);
        if (!info.changes) return sendJSON(404, { error: "question not found" });
        // text changed -> stale cached audio, regenerate lazily next time it's needed
        if (body.prompt !== undefined || body.correctAnswer !== undefined) deleteEnglishAudio(id);
        return sendJSON(200, { ok: true });
      }

      if (method === "DELETE") {
        // same reasoning as the vocab_words delete: don't let old quiz history block
        // deleting a question the parent explicitly asked to remove.
        db.prepare("DELETE FROM english_quiz_items WHERE question_id = ?").run(id);
        const info = db.prepare("DELETE FROM english_questions WHERE id = ?").run(id);
        if (!info.changes) return sendJSON(404, { error: "question not found" });
        deleteEnglishAudio(id);
        return sendJSON(200, { ok: true });
      }
    }

    // --- English audio: lazily synthesized + cached "sentence with blank filled in" ---
    if (method === "GET" && pathname.startsWith("/english-audio/")) {
      const file = path.basename(pathname);
      const m = file.match(/^(\d+)\.wav$/);
      if (!m) return sendJSON(404, { error: "not found" });
      const questionId = Number(m[1]);
      const q = db.prepare("SELECT prompt, correct_answer FROM english_questions WHERE id = ?").get(questionId);
      if (!q) return sendJSON(404, { error: "question not found" });
      let filePath;
      try {
        filePath = await ensureEnglishAudio(questionId, q.prompt, q.correct_answer);
      } catch (err) {
        console.error(`[kid-reminder] English TTS failed for question ${questionId}: ${err.message}`);
        return sendJSON(502, { error: "TTS service unavailable, try again shortly" });
      }
      const data = fs.readFileSync(filePath);
      res.writeHead(200, { "Content-Type": "audio/wav", "Cache-Control": "public, max-age=31536000" });
      return res.end(data);
    }

    // --- English practice sessions: weakest-first, self-graded (open; kid app calls these) ---
    if (method === "POST" && pathname === "/api/english/sessions") {
      const pool = db.prepare(`SELECT id FROM english_questions ORDER BY correct_count ASC LIMIT 60`).all();
      if (pool.length === 0) return sendJSON(400, { error: "question bank is empty" });
      const ids = pool.map((r) => r.id);
      for (let i = ids.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [ids[i], ids[j]] = [ids[j], ids[i]]; }
      const chosen = ids.slice(0, Math.min(10, ids.length));

      const info = db.prepare("INSERT INTO english_quiz_sessions DEFAULT VALUES").run();
      const sessionId = Number(info.lastInsertRowid);
      const insertItem = db.prepare("INSERT INTO english_quiz_items (session_id, question_id, seq) VALUES (?, ?, ?)");
      const getQ = db.prepare("SELECT id, type, topic, prompt, options, needs_audio FROM english_questions WHERE id = ?");
      const items = chosen.map((qid, i) => {
        const info2 = insertItem.run(sessionId, qid, i + 1);
        const q = getQ.get(qid);
        return {
          itemId: Number(info2.lastInsertRowid),
          seq: i + 1,
          questionId: q.id,
          type: q.type,
          topic: q.topic,
          prompt: q.prompt,
          options: q.options ? JSON.parse(q.options) : null,
          needsAudio: !!q.needs_audio,
        };
      });
      return sendJSON(201, { sessionId, items });
    }

    const engSubmitMatch = pathname.match(/^\/api\/english\/sessions\/(\d+)\/items\/(\d+)\/submit$/);
    if (engSubmitMatch && method === "POST") {
      const sessionId = Number(engSubmitMatch[1]);
      const itemId = Number(engSubmitMatch[2]);
      const item = db
        .prepare(
          `SELECT i.id, i.result, i.question_id, q.correct_answer, q.explanation
           FROM english_quiz_items i JOIN english_questions q ON q.id = i.question_id
           WHERE i.id = ? AND i.session_id = ?`
        )
        .get(itemId, sessionId);
      if (!item) return sendJSON(404, { error: "item not found" });
      const body = await readBody(req);
      const answer = String(body.answer || "");
      if (item.result === null) {
        const alts = item.correct_answer.split("/").map((a) => normalizeEnglishAnswer(a));
        const isCorrect = alts.includes(normalizeEnglishAnswer(answer));
        const result = isCorrect ? "correct" : "incorrect";
        db.prepare("UPDATE english_quiz_items SET answer = ?, result = ? WHERE id = ?").run(answer, result, itemId);
        db.prepare(
          `UPDATE english_questions SET correct_count = MAX(0, correct_count + ?) WHERE id = ?`
        ).run(isCorrect ? 1 : -1, item.question_id);
        item.result = result; // reflect below
      }
      return sendJSON(200, {
        correct: item.result === "correct",
        correctAnswer: item.correct_answer,
        explanation: item.explanation,
      });
    }

    // self-override: for sentence-transform items where auto-grading may be too strict —
    // the kid/parent can flip the verdict once after seeing the correct answer.
    const engOverrideMatch = pathname.match(/^\/api\/english\/sessions\/(\d+)\/items\/(\d+)\/override$/);
    if (engOverrideMatch && method === "POST") {
      const sessionId = Number(engOverrideMatch[1]);
      const itemId = Number(engOverrideMatch[2]);
      const item = db
        .prepare("SELECT id, result, overridden, question_id FROM english_quiz_items WHERE id = ? AND session_id = ?")
        .get(itemId, sessionId);
      if (!item) return sendJSON(404, { error: "item not found" });
      if (item.result === null) return sendJSON(400, { error: "item hasn't been answered yet" });
      if (item.overridden) return sendJSON(409, { error: "already overridden once" });
      const body = await readBody(req);
      const newResult = body.correct ? "correct" : "incorrect";
      if (newResult !== item.result) {
        // reverse the original delta, then apply the new one (net ±2)
        const delta = newResult === "correct" ? 2 : -2;
        db.prepare("UPDATE english_questions SET correct_count = MAX(0, correct_count + ?) WHERE id = ?").run(delta, item.question_id);
      }
      db.prepare("UPDATE english_quiz_items SET result = ?, overridden = 1 WHERE id = ?").run(newResult, itemId);
      return sendJSON(200, { ok: true });
    }

    const engCompleteMatch = pathname.match(/^\/api\/english\/sessions\/(\d+)\/complete$/);
    if (engCompleteMatch && method === "POST") {
      const id = Number(engCompleteMatch[1]);
      const info = db.prepare("UPDATE english_quiz_sessions SET status = 'completed', completed_at = datetime('now') WHERE id = ?").run(id);
      if (!info.changes) return sendJSON(404, { error: "session not found" });
      return sendJSON(200, { ok: true });
    }

    // --- list practice-set history: all by default, or filter by ?status= (admin only) ---
    if (method === "GET" && pathname === "/api/english/sessions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const status = url.searchParams.get("status") || "";
      const where = status ? "WHERE status = ?" : "";
      const rows = db
        .prepare(
          `SELECT s.id, s.status, s.created_at, s.completed_at,
                  COUNT(i.id) itemCount,
                  SUM(CASE WHEN i.result = 'correct' THEN 1 ELSE 0 END) correctCount,
                  SUM(CASE WHEN i.result = 'incorrect' THEN 1 ELSE 0 END) incorrectCount
           FROM english_quiz_sessions s LEFT JOIN english_quiz_items i ON i.session_id = s.id
           ${where} GROUP BY s.id ORDER BY s.created_at DESC`
        )
        .all(...(status ? [status] : []));
      return sendJSON(200, { sessions: rows });
    }

    // --- practice-set detail: ordered items joined to their question (admin only) ---
    const engSessDetailMatch = pathname.match(/^\/api\/english\/sessions\/(\d+)$/);
    if (engSessDetailMatch && method === "GET") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(engSessDetailMatch[1]);
      const session = db.prepare("SELECT * FROM english_quiz_sessions WHERE id = ?").get(id);
      if (!session) return sendJSON(404, { error: "session not found" });
      const items = db
        .prepare(
          `SELECT i.id, i.seq, i.answer, i.result, i.overridden,
                  q.id question_id, q.type, q.topic, q.prompt, q.options, q.correct_answer, q.explanation
           FROM english_quiz_items i JOIN english_questions q ON q.id = i.question_id
           WHERE i.session_id = ? ORDER BY i.seq`
        )
        .all(id)
        .map((r) => ({ ...r, options: r.options ? JSON.parse(r.options) : null }));
      return sendJSON(200, { session, items });
    }

    // --- delete a practice-set record (any status — abandoned in_progress ones the kid
    // never finished, or just old history the parent wants to tidy up) (admin only) ---
    if (engSessDetailMatch && method === "DELETE") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(engSessDetailMatch[1]);
      db.prepare("DELETE FROM english_quiz_items WHERE session_id = ?").run(id);
      const info = db.prepare("DELETE FROM english_quiz_sessions WHERE id = ?").run(id);
      if (!info.changes) return sendJSON(404, { error: "session not found" });
      return sendJSON(200, { ok: true });
    }

    // ============================ 科学 (PSLE Science open-ended) ==============
    // Grading is per MARK POINT, not per question, and every answer is confirmed
    // by a parent — the keyword verdict only pre-fills the review.

    // --- question images (open; same three-layer traversal guard as /sprites/) ---
    if (method === "GET" && pathname.startsWith("/science-images/")) {
      const file = path.basename(pathname);
      const full = path.join(SCIENCE_IMAGES_DIR, file);
      if (!full.startsWith(SCIENCE_IMAGES_DIR) || !/^[\w.-]+\.png$/.test(file) || !fs.existsSync(full)) {
        return sendJSON(404, { error: "image not found" });
      }
      const data = fs.readFileSync(full);
      res.writeHead(200, { "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" });
      return res.end(data);
    }

    // --- browse the bank (admin only) ---------------------------------------
    // ?mistakeBank=1 narrows to the 错题本 for the admin's mistake-bank
    // management view (list + a per-question "移出错题本" action via PATCH below).
    if (method === "GET" && pathname === "/api/science/questions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const limit = Math.min(200, Math.max(1, parseInt(url.searchParams.get("limit") || "50", 10)));
      const offset = Math.max(0, parseInt(url.searchParams.get("offset") || "0", 10) || 0);
      const theme = url.searchParams.get("theme") || "";
      const mistakeOnly = url.searchParams.get("mistakeBank") === "1";
      const clauses = [], args = [];
      if (theme) { clauses.push("theme = ?"); args.push(theme); }
      if (mistakeOnly) clauses.push("in_mistake_bank = 1");
      const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
      const total = db.prepare(`SELECT COUNT(*) n FROM science_questions ${where}`).get(...args).n;
      const rows = db.prepare(
        `SELECT * FROM science_questions ${where} ORDER BY question_no, part LIMIT ? OFFSET ?`
      ).all(...args, limit, offset);
      return sendJSON(200, { total, limit, offset, questions: rows });
    }

    // --- clear (or set) a question's 错题本 membership (admin only) -----------
    // Membership is sticky by design — a review only ever sets it to 1 (see the
    // /review handler below); this is the one path that clears it, so a question
    // never leaves 错题本 except by a parent's explicit decision.
    const sciQuestionMatch = pathname.match(/^\/api\/science\/questions\/(\d+)$/);
    if (sciQuestionMatch && method === "PATCH") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const body = await readBody(req);
      if (typeof body.inMistakeBank !== "boolean") {
        return sendJSON(400, { error: "inMistakeBank (boolean) is required" });
      }
      const info = db.prepare("UPDATE science_questions SET in_mistake_bank = ? WHERE id = ?")
        .run(body.inMistakeBank ? 1 : 0, Number(sciQuestionMatch[1]));
      if (!info.changes) return sendJSON(404, { error: "question not found" });
      return sendJSON(200, { ok: true });
    }

    // --- list papers for the browse screen (open; the kid app calls this) -----
    if (method === "GET" && pathname === "/api/science/papers") {
      // Only non-drawing parts are counted — those are the ones the kid can
      // actually earn marks on on a screen.
      const papers = db.prepare(`
        SELECT paper_key AS paperKey, school, year,
               COUNT(*) AS questionCount, SUM(marks) AS marksTotal
          FROM science_questions
         WHERE answer_mode != 'drawing' AND paper_key != ''
         GROUP BY paper_key ORDER BY year DESC, school ASC`).all();
      const mistakeCount = db.prepare(
        "SELECT COUNT(*) n FROM science_questions WHERE in_mistake_bank = 1 AND answer_mode != 'drawing'"
      ).get().n;
      return sendJSON(200, { papers, mistakeCount });
    }

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
        const rows = db.prepare(
          "SELECT id FROM science_questions WHERE in_mistake_bank = 1 AND answer_mode != 'drawing'"
        ).all();
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

    // --- submit one answer (open) --------------------------------------------
    const sciSubmit = pathname.match(/^\/api\/science\/sessions\/(\d+)\/items\/(\d+)\/submit$/);
    if (sciSubmit && method === "POST") {
      const sessionId = Number(sciSubmit[1]), itemId = Number(sciSubmit[2]);
      const item = db.prepare(
        "SELECT * FROM science_session_items WHERE id = ? AND session_id = ?"
      ).get(itemId, sessionId);
      if (!item) return sendJSON(404, { error: "item not found" });
      const body = await readBody(req);
      const answer = String(body.answer || "");
      const q = db.prepare("SELECT * FROM science_questions WHERE id = ?").get(item.question_id);
      const points = db.prepare(
        "SELECT * FROM science_mark_points WHERE question_id = ? ORDER BY seq"
      ).all(item.question_id);

      // Idempotent, like the English submit: re-posting returns the stored
      // verdict instead of re-scoring.
      if (item.auto_score === null) {
        let auto = 0;
        for (const p of points) {
          const hit = scienceAutoHit(p, answer) ? 1 : 0;
          auto += hit;
          db.prepare(
            "INSERT INTO science_item_points (item_id, mark_point_id, auto_hit) VALUES (?, ?, ?)"
          ).run(itemId, p.id, hit);
        }
        db.prepare("UPDATE science_session_items SET answer = ?, auto_score = ? WHERE id = ?")
          .run(answer, auto, itemId);
        item.auto_score = auto;
      }

      const hits = db.prepare("SELECT mark_point_id, auto_hit FROM science_item_points WHERE item_id = ?").all(itemId);
      const hitBy = new Map(hits.map((h) => [h.mark_point_id, h.auto_hit]));
      return sendJSON(200, {
        autoScore: item.auto_score,
        marks: q.marks,
        modelAnswer: q.model_answer,
        doNotAccept: scienceParse(q.do_not_accept, []),
        provisional: true,   // a parent still has to confirm this
        points: points.map((p) => ({
          markPointId: p.id, seq: p.seq, pointKind: p.point_kind,
          description: p.description, autoHit: (hitBy.get(p.id) || 0) === 1,
        })),
      });
    }

    // --- finish a set -> parent's review queue (open) -------------------------
    const sciComplete = pathname.match(/^\/api\/science\/sessions\/(\d+)\/complete$/);
    if (sciComplete && method === "POST") {
      const info = db.prepare(
        "UPDATE science_sessions SET status = 'pending_review', completed_at = datetime('now') WHERE id = ?"
      ).run(Number(sciComplete[1]));
      if (!info.changes) return sendJSON(404, { error: "session not found" });
      return sendJSON(200, { ok: true });
    }

    // --- session list (admin: the review queue) ------------------------------
    if (method === "GET" && pathname === "/api/science/sessions") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const status = url.searchParams.get("status");
      const where = status ? "WHERE s.status = ?" : "";
      const args = status ? [status] : [];
      const rows = db.prepare(`
        SELECT s.*,
               (SELECT COUNT(*) FROM science_session_items i WHERE i.session_id = s.id) itemCount,
               (SELECT COALESCE(SUM(q.marks), 0) FROM science_session_items i
                  JOIN science_questions q ON q.id = i.question_id WHERE i.session_id = s.id) marksTotal,
               (SELECT COALESCE(SUM(i.auto_score), 0) FROM science_session_items i WHERE i.session_id = s.id) autoTotal,
               (SELECT COALESCE(SUM(i.final_score), 0) FROM science_session_items i WHERE i.session_id = s.id) finalTotal
          FROM science_sessions s ${where} ORDER BY s.created_at DESC`).all(...args);
      return sendJSON(200, { sessions: rows });
    }

    // --- one session in full, for reviewing or reading back (admin) ----------
    const sciSessDetail = pathname.match(/^\/api\/science\/sessions\/(\d+)$/);
    if (sciSessDetail && method === "GET") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(sciSessDetail[1]);
      const session = db.prepare("SELECT * FROM science_sessions WHERE id = ?").get(id);
      if (!session) return sendJSON(404, { error: "session not found" });
      const items = db.prepare(`
        SELECT i.*, q.prompt, q.context, q.image, q.marks, q.model_answer, q.theme, q.topic,
               q.question_type, q.do_not_accept, q.source_ref
          FROM science_session_items i JOIN science_questions q ON q.id = i.question_id
         WHERE i.session_id = ? ORDER BY i.seq`).all(id);
      const detailed = items.map((it) => {
        const pts = db.prepare(`
          SELECT mp.id markPointId, mp.seq, mp.point_kind pointKind, mp.description,
                 ip.auto_hit autoHit, ip.final_hit finalHit
            FROM science_mark_points mp
            LEFT JOIN science_item_points ip
                   ON ip.mark_point_id = mp.id AND ip.item_id = ?
           WHERE mp.question_id = ? ORDER BY mp.seq`).all(it.id, it.question_id);
        return { ...it, do_not_accept: scienceParse(it.do_not_accept, []), points: pts };
      });
      return sendJSON(200, { session, items: detailed });
    }

    // --- parent review: confirm or correct the per-point verdict (admin) -----
    const sciReview = pathname.match(/^\/api\/science\/sessions\/(\d+)\/review$/);
    if (sciReview && method === "POST") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const sessionId = Number(sciReview[1]);
      const session = db.prepare("SELECT * FROM science_sessions WHERE id = ?").get(sessionId);
      if (!session) return sendJSON(404, { error: "session not found" });
      const body = await readBody(req);
      if (!Array.isArray(body.items)) return sendJSON(400, { error: "items array required" });

      // A re-review must not double-count: undo this session's previous
      // contribution to the question stats before applying the new one.
      const already = session.status === "reviewed";
      for (const entry of body.items) {
        const itemId = Number(entry.itemId);
        const item = db.prepare(
          "SELECT * FROM science_session_items WHERE id = ? AND session_id = ?"
        ).get(itemId, sessionId);
        if (!item) continue;
        const q = db.prepare("SELECT marks FROM science_questions WHERE id = ?").get(item.question_id);
        let final = 0;
        for (const p of entry.points || []) {
          const hit = p.hit ? 1 : 0;
          final += hit;
          db.prepare("UPDATE science_item_points SET final_hit = ? WHERE item_id = ? AND mark_point_id = ?")
            .run(hit, itemId, Number(p.markPointId));
        }
        const prev = already && item.final_score !== null ? item.final_score : 0;
        const prevAttempt = already ? 1 : 0;
        db.prepare("UPDATE science_session_items SET final_score = ? WHERE id = ?").run(final, itemId);
        db.prepare("UPDATE science_questions SET attempts = attempts + ?, score_total = score_total + ? WHERE id = ?")
          .run(1 - prevAttempt, final - prev, item.question_id);
        // Sticky add-only: a miss puts it in 错题本; a full score here does NOT
        // take it back out — only the parent's explicit PATCH does that.
        if (q && final < q.marks) {
          db.prepare("UPDATE science_questions SET in_mistake_bank = 1 WHERE id = ?").run(item.question_id);
        }
      }
      db.prepare("UPDATE science_sessions SET status = 'reviewed', reviewed_at = datetime('now') WHERE id = ?")
        .run(sessionId);
      return sendJSON(200, { ok: true });
    }

    // --- delete a set (admin) -----------------------------------------------
    // For abandoned in_progress sets the kid never finished, and for tidying up.
    // Deleting also removes its per-point rows, so the failure-mode stats stop
    // counting it. Question attempts/score_total are NOT rewound — those record
    // that the question was attempted, which stays true.
    if (sciSessDetail && method === "DELETE") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const id = Number(sciSessDetail[1]);
      const items = db.prepare("SELECT id FROM science_session_items WHERE session_id = ?").all(id);
      for (const it of items) {
        db.prepare("DELETE FROM science_item_points WHERE item_id = ?").run(it.id);
      }
      db.prepare("DELETE FROM science_session_items WHERE session_id = ?").run(id);
      const info = db.prepare("DELETE FROM science_sessions WHERE id = ?").run(id);
      if (!info.changes) return sendJSON(404, { error: "session not found" });
      return sendJSON(200, { ok: true });
    }

    // --- the diagnosis: which kinds of point get missed (admin) --------------
    if (method === "GET" && pathname === "/api/science/stats/failure-modes") {
      const isAdmin = req.headers["x-admin-pin"] === ADMIN_PIN;
      if (!isAdmin) return sendJSON(401, { error: "admin pin required" });
      const rows = db.prepare(`
        SELECT mp.point_kind pointKind,
               COUNT(*) total,
               SUM(CASE WHEN ip.final_hit = 1 THEN 1 ELSE 0 END) hit
          FROM science_item_points ip
          JOIN science_mark_points mp ON mp.id = ip.mark_point_id
         WHERE ip.final_hit IS NOT NULL
         GROUP BY mp.point_kind
         ORDER BY (COUNT(*) - SUM(CASE WHEN ip.final_hit = 1 THEN 1 ELSE 0 END)) DESC`).all();
      return sendJSON(200, {
        kinds: rows.map((r) => ({ ...r, missed: r.total - r.hit })),
      });
    }

    sendJSON(404, { error: "not found" });
  } catch (err) {
    const status = err.status || 500;
    console.error(`[kid-reminder] ${method} ${pathname} -> ${status}: ${err.message}`);
    sendJSON(status, { error: status === 500 ? "server error" : err.message });
  }
});

// server.log is world-readable and never rotates, so printing the PIN in full
// left a permanent plaintext copy of it (plus every previous PIN) on disk. Show
// just enough to confirm *which* PIN is live without disclosing it.
function maskPin(pin) {
  const s = String(pin ?? "");
  if (s.length < 4) return "*".repeat(s.length || 1); // too short to reveal any of
  return "*".repeat(s.length - 2) + s.slice(-2);
}

server.listen(PORT, () => {
  console.log(`[kid-reminder] listening on http://0.0.0.0:${PORT} (admin pin: ${maskPin(ADMIN_PIN)})`);
});
