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
