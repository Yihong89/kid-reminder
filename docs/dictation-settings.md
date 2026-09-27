# Dictation settings (听写设置)

Every dictation knob is a row in the `app_settings` key/value table, editable
from the web admin's **⚙️ 设置** tab — no code change, no app rebuild, no
redeploy. The kid's app reads the set size from `GET /api/settings` (open, no
PIN) so its idle screen can say "会挑 N 个…"; everything else is server-side only.

`SETTING_DEFS` in `backend/server.js` is the single source of truth: the admin
panel builds its controls from the `fields` array that `GET /api/settings`
returns, so adding a setting is a one-line change there and no HTML edit.

## The settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `dictation.zh.size` | int 1–200 | `40` | Words per Chinese set. |
| `dictation.en.size` | int 1–200 | `20` | Words per English set. |
| `dictation.zh.priorityLevel` | level, or `""` | `""` | Words at this grade level are drawn first. Empty = no level preference, which is the original behaviour (weakest first across the whole bank, lowest level breaking ties). |
| `dictation.zh.writeOnly` | bool | `false` | Draw only 识写字 (`vocab_words.category = 'write'`), skipping 认读字. |
| `dictation.zh.charCap` | int 1–10 | `10` | Once a character has this many words answered correctly, its remaining words are **demoted** among equally-weak words. `10` = never demote, i.e. off. |

A missing or out-of-range row falls back to the default rather than erroring, so
a hand-edited database can't break a session.

### How the draw order is built

```
[priority level first]  →  correct_count ASC  →  [charCap demotion]  →  level ASC  →  RANDOM()
```

Two things are easy to get wrong here:

- **The cap is a tiebreak, not a filter.** A learned character's words are never
  removed from the pool — they only lose priority against words that are
  *equally* weak. Removing them instead caps total coverage (a character that
  never reaches the cap, e.g. one with a single word, would cycle forever) and
  lets the pool run dry. It is an `ORDER BY` term, deliberately.
- **`correct_count` is `+1` right / `-1` wrong, floored at 0**, so a word that
  was answered correctly can drop back to 0 and return to the front of the
  queue. That is why covering the whole bank takes noticeably more sessions than
  `word_count / set_size`.

## Exam-period preset (期末复习)

Verified 2026-09-21. The exam was ~26 days out, so the goal was to cover all
**254 P5 识写字 characters** (1036 words) rather than every single word.

| Key | Value | Why |
|---|---|---|
| `dictation.zh.size` | `50` | 254 characters need ~20–23 sessions at 50–70% accuracy; 26 days at 50 words leaves margin. |
| `dictation.zh.priorityLevel` | `P5` | The exam is on P5 content. Without this the draw favours P3, whose 792 unanswered words would take ~20 sessions to clear first. |
| `dictation.zh.writeOnly` | `true` | 识写字 is what has to be *written* in the exam; P5 is 1036 write + 895 read words. |
| `dictation.zh.charCap` | `2` | Stops drilling all ~5 words of a character once the character is demonstrably known. |

`tools/dictation-preset.sh` applies or clears this in one command:

```bash
ADMIN_PIN=xxxx tools/dictation-preset.sh exam      # 期末复习
ADMIN_PIN=xxxx tools/dictation-preset.sh restore   # 恢复默认
ADMIN_PIN=xxxx tools/dictation-preset.sh status    # 只看当前值
```

### Restoring afterwards

`restore` writes every key back to its default, which is exactly the behaviour
from before these settings existed:

```
dictation.zh.size           = 40
dictation.zh.priorityLevel  = ""
dictation.zh.writeOnly      = false
dictation.zh.charCap        = 10
```

Both presets can also be applied by hand on the **⚙️ 设置** tab; the script
exists so the restore is one command and can't be half-applied from memory.

> Note: `restore` only touches dictation settings. It does not re-grade anything
> already dictated, and it does not change the word bank.
