// 让错题本标记和"跟随最终判定"这条新规则对齐。
// 对每道题取它在**最近一次会话**里的判定：判错进错题本、判对摘掉。
// 从没做过的题不动（保持原值）。
const os = require('os');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(os.homedir() + '/kidreminder/kidreminder.db');
const q = (s, ...a) => db.prepare(s).all(...a);

const before = q("SELECT COUNT(*) n FROM epaper_questions WHERE in_mistake_bank = 1")[0].n;
let toAdd = 0, toClear = 0, untouched = 0, same = 0;
const addList = [], clearList = [];

for (const eq of q("SELECT id, paper_key, paper_seq, question_type, marks, in_mistake_bank FROM epaper_questions")) {
  const last = q(`SELECT i.id, i.final_correct, i.auto_correct FROM epaper_session_items i
       WHERE i.question_id = ? ORDER BY i.session_id DESC, i.id DESC LIMIT 1`, eq.id)[0];
  if (!last) { untouched++; continue; }        // 没做过，不动
  let wrong;
  if (eq.question_type === 'oeq') {
    // 和 server.js 一致：按**实际得分**（含照抄归零、simplify 扣半、时态扣 1）
    const row = q(`SELECT i.lift_zero, i.simplify_half, i.tense_error FROM epaper_session_items i WHERE i.id = ?`, last.id)[0];
    const hits = q("SELECT COALESCE(final_hit, auto_hit) h FROM epaper_item_points WHERE item_id = ?", last.id)
      .reduce((a, x) => a + (x.h || 0), 0);
    let earned = hits;
    if (row.lift_zero) earned = 0;
    else {
      if (row.simplify_half) earned -= eq.marks * 0.5;
      if (row.tense_error) earned -= 1;
      earned = Math.max(0, earned);
    }
    wrong = earned < eq.marks;
  } else {
    wrong = !((last.final_correct !== null ? last.final_correct : last.auto_correct) ? 1 : 0);
  }
  const want = wrong ? 1 : 0;
  if (want === eq.in_mistake_bank) { same++; continue; }
  if (want) { toAdd++; addList.push(`${eq.paper_key} Q${eq.paper_seq}`); }
  else { toClear++; clearList.push(`${eq.paper_key} Q${eq.paper_seq}`); }
  db.prepare("UPDATE epaper_questions SET in_mistake_bank = ? WHERE id = ?").run(want, eq.id);
}

const after = q("SELECT COUNT(*) n FROM epaper_questions WHERE in_mistake_bank = 1")[0].n;
console.log(`错题本：${before} -> ${after} 题`);
console.log(`  摘掉（最新判定为对）: ${toClear} 题`);
console.log(`  补上（最新判定为错）: ${toAdd} 题`);
console.log(`  本来就一致: ${same} 题`);
console.log(`  从未做过、保持原样: ${untouched} 题`);
if (clearList.length) console.log(`\n摘掉: ${clearList.join(', ')}`);
if (addList.length) console.log(`\n补上: ${addList.join(', ')}`);

console.log('\n按卷子:');
for (const r of q(`SELECT paper_key, COUNT(*) n FROM epaper_questions WHERE in_mistake_bank = 1 GROUP BY paper_key ORDER BY n DESC`))
  console.log(`  ${r.paper_key.padEnd(22)} ${r.n} 题`);
