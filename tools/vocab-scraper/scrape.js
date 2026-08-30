#!/usr/bin/env node
// Vocab scraper — one-off tool for kid-reminder's dictation feature.
//
// Scrapes https://sgschoolkaki.com's PSLE Chinese "Word Bank" page: for every
// character (识读字 + 识写字) at every level (P1–P6) and lesson, it clicks the
// character and reads the compound words + pinyin + example sentences that
// the page renders. No English gloss is kept (not needed for dictation).
//
// Why this is safe to do this way (see robots.txt + DOM audit before writing
// this script): the site's own robots.txt explicitly allows AI crawlers on
// "/" and only disallows "/api/"; clicking a character makes ZERO network
// requests (the whole word bank is already shipped to the browser on first
// load and rendered client-side from memory), so this script is no heavier
// on their server than one person reading the page once. We still run
// headless with small waits and do a single page load — not a request storm.
//
// Output: vocab-raw.json — flat array of
//   { level, lessonIndex, lesson, category, character, word, pinyin, sentence }
// Re-run any time to refresh (idempotent — overwrites the output file).

const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const URL = "https://sgschoolkaki.com/learning/study-guides/psle-chinese-study-guide/word-bank";
// LEVELS=P1,P2 node scrape.js  -> scrape just those levels (handy for a quick smoke test)
const LEVELS = process.env.LEVELS ? process.env.LEVELS.split(",") : ["P1", "P2", "P3", "P4", "P5", "P6"];
// MAX_LESSONS=1 node scrape.js -> only scrape the first N lesson cards per level (smoke test)
const MAX_LESSONS = process.env.MAX_LESSONS ? parseInt(process.env.MAX_LESSONS, 10) : Infinity;
const OUT_PATH = path.join(__dirname, "vocab-raw.json");
const CLICK_SETTLE_MS = 120; // small buffer after each click before reading the panel; the panel itself is awaited explicitly below

const LESSON_CARD = "div.rounded-xl.border.border-gray-200.bg-white.shadow-sm.overflow-hidden";

async function scrapeLevel(page, level, results) {
  const levelBtn = page.getByRole("button", { name: new RegExp(`^${level}\\s`) }).first();
  await levelBtn.click();
  await page.waitForTimeout(400);

  const lessonCount = Math.min(await page.locator(LESSON_CARD).count(), MAX_LESSONS);
  console.log(`[${level}] ${lessonCount} lesson card(s)`);

  for (let li = 0; li < lessonCount; li++) {
    const lessonCard = page.locator(LESSON_CARD).nth(li);
    const lessonLabel = (await lessonCard.locator("span.text-sm.font-medium.text-gray-700").innerText()).trim();

    const groups = lessonCard.locator("div.p-4.space-y-3 > div");
    const groupCount = await groups.count();

    for (let gi = 0; gi < groupCount; gi++) {
      const group = groups.nth(gi);
      const headerText = await group.locator("span.text-xs.font-medium.text-gray-500").innerText().catch(() => "");
      const category = headerText.includes("识读字") ? "read" : headerText.includes("识写字") ? "write" : null;
      if (!category) continue;

      const charButtons = group.locator("div.flex.flex-wrap.gap-1\\.5 > button");
      const charCount = await charButtons.count();

      for (let ci = 0; ci < charCount; ci++) {
        const btn = charButtons.nth(ci);
        const character = (await btn.innerText()).trim();
        await btn.click();

        // NOTE: each level uses its own Tailwind theme color (P3=blue, P5=purple, P1=emerald, ...)
        // so the selector must not depend on color-specific classes like "border-blue-200".
        const panel = group.locator("div.mt-3.rounded-xl.overflow-hidden.shadow-sm");
        try {
          await panel.waitFor({ state: "visible", timeout: 2000 });
        } catch {
          console.warn(`  ! no panel appeared for ${level} ${lessonLabel} ${category} "${character}" — skipping`);
          continue;
        }
        await page.waitForTimeout(CLICK_SETTLE_MS);

        const entries = panel.locator("div.p-3.space-y-2 > div");
        const entryCount = await entries.count();
        for (let ei = 0; ei < entryCount; ei++) {
          const entry = entries.nth(ei);
          const word = (await entry.locator("span.text-lg.font-bold").innerText()).trim(); // color class varies per level, don't match on it
          const pinyin = (await entry.locator("span.text-xs.text-gray-400.font-medium").innerText()).trim();
          const sentence = (await entry.locator("p").innerText()).trim();
          results.push({
            level,
            lessonIndex: li + 1,
            lesson: lessonLabel,
            category,
            character,
            word,
            pinyin,
            sentence,
          });
        }
      }
    }
    // incremental save after every lesson so a crash never loses more than one lesson's work
    fs.writeFileSync(OUT_PATH, JSON.stringify(results, null, 2));
  }
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  console.log(`Loading ${URL} ...`);
  await page.goto(URL, { waitUntil: "networkidle" });

  const results = [];
  for (const level of LEVELS) {
    await scrapeLevel(page, level, results);
    console.log(`[${level}] done — ${results.length} word entries total so far`);
  }

  await browser.close();
  fs.writeFileSync(OUT_PATH, JSON.stringify(results, null, 2));

  const byLevel = {};
  for (const r of results) byLevel[r.level] = (byLevel[r.level] || 0) + 1;
  console.log("\nDone.");
  console.log("Entries per level:", byLevel);
  console.log(`Total: ${results.length} word entries -> ${OUT_PATH}`);
})().catch((err) => {
  console.error("Scrape failed:", err);
  process.exit(1);
});
