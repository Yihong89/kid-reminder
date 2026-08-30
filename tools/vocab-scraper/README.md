# vocab-scraper

One-off tool for the (planned) 听写 / dictation feature: scrapes
[SGSchoolKaki's PSLE Chinese Word Bank](https://sgschoolkaki.com/learning/study-guides/psle-chinese-study-guide/word-bank)
into a local JSON cache of `{ character → compound words + pinyin + example sentence }`,
covering P1–P6.

## Why scrape instead of calling an API

The page is client-rendered: the entire word bank ships to the browser on
first load, and clicking a character makes **zero network requests** — it's
a local lookup. So this script makes one real HTTP request (the page load)
and then reads already-downloaded data out of the DOM; it's no heavier on
their server than a parent reading the page once. Their `robots.txt`
explicitly allows AI crawlers on `/` and only disallows `/api/`, which this
script never touches.

Not every character has word-bank data — P1/P2 characters mostly don't (too
basic to have interesting compound words yet on this site), so expect 0
entries for those levels. That's correct, not a bug.

## Usage

```bash
npm install        # also downloads a local Chromium via `playwright install`
npm run scrape      # writes vocab-raw.json (all P1–P6)

# quick smoke test on a subset:
LEVELS=P3 MAX_LESSONS=2 node scrape.js
```

Output is saved incrementally (after each lesson), so a crash partway
through never loses more than the current lesson's progress — just re-run.

## Output shape (`vocab-raw.json`)

```json
{
  "level": "P3",
  "lessonIndex": 1,
  "lesson": "第一课",
  "category": "read",       // "read" (识读字) | "write" (识写字)
  "character": "科",
  "word": "科学",
  "pinyin": "kē xué",
  "sentence": "小明对科学课上的实验非常感兴趣，每次都认真地做笔记。"
}
```

No English gloss is kept (not needed for dictation).

## Important: don't commit `vocab-raw.json`

This repo is **public**. The scraped file reproduces SGSchoolKaki's own
curated words/sentences — fine to keep locally for our private family use,
not fine to republish in a public repo. It's already in `.gitignore`
(`tools/vocab-scraper/vocab-raw.json`). Copy it wherever the backend will
read it from (not decided yet — this tool only produces the raw cache;
importing it into `kidreminder.db` is a separate, later step).

## Coverage gap: Higher Chinese

This site's character list matches the **mainstream** 2015 MOE syllabus,
not Higher Chinese. Higher Chinese has ~140 extra characters (see the PSLE
Chinese vocab handbook artifact from earlier in this project) that won't
appear here. Not handled by this tool — flagged for later.
