// 回归测试：把 admin.html 的两套卡片渲染函数都真的跑一遍。
//
// 为什么需要它：两次 bug 都是"文件看着对、加载也正常，但一渲染就抛异常"——
//   1. "Can't find variable: high"   —— 扣分项引用了 if 块里声明的变量
//   2. 预览卡引用不存在的 readOnly    —— 补丁 str.replace(..., 1) 打到了同名同形的另一个函数
// 语法检查(node --check)和加载期桩跑都发现不了这两种，只有真的调用渲染函数才行。
//
// 跑法：node tools/english-papers/admin-card-render-test.js
// 需要先准备数据（用 admin PIN 取接口）：
//   curl -H "X-Admin-Pin: 1056" "http://127.0.0.1:2021/api/epaper/questions?paperKey=rulang-2025&limit=100" \
//     -o /tmp/questions-rulang.json
//   curl -H "X-Admin-Pin: 1056" "http://127.0.0.1:2021/api/epaper/sessions/53" \
//     -o /tmp/session53.json
const fs = require('fs');
const path = require('path');

const ADMIN = path.join(__dirname, '../../backend/admin.html');
const QUESTIONS = process.env.QUESTIONS_JSON || '/tmp/questions-rulang.json';
const SESSION = process.env.SESSION_JSON || '/tmp/session53.json';

const html = fs.readFileSync(ADMIN, 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1])[0];

// ---- 自返回 Proxy 桩：任何属性访问/调用/赋值都不炸 ----
function stub(name) {
  const f = function () { return p; };
  const p = new Proxy(f, {
    get(t, k) {
      if (k === 'length') return 0;
      if (k === 'then') return undefined;
      if (k === Symbol.toPrimitive || k === 'valueOf') return () => 0;
      if (k === 'toString') return () => '';
      if (k === 'textContent' || k === 'innerHTML' || k === 'value' || k === 'className') return '';
      if (k === 'dataset') return {};
      if (k === 'classList') return { add() {}, remove() {}, toggle() {} };
      if (k === 'style') return {};
      return stub(name + '.' + String(k));
    },
    set() { return true; },
    apply() { return stub(name + '()'); },
    has() { return true; },
  });
  return p;
}
global.window = global;
global.document = new Proxy({}, {
  get(t, k) {
    if (k === 'createElement') return () => stub('el');
    if (k === 'getElementById' || k === 'querySelector' || k === 'querySelectorAll') return () => stub('el');
    if (k === 'addEventListener') return () => {};
    if (k === 'body') return stub('body');
    return stub('doc.' + String(k));
  }, set() { return true; },
});
global.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
global.fetch = () => new Promise(() => {});
global.setInterval = () => 0; global.setTimeout = () => 0; global.clearTimeout = () => {};
global.alert = () => {}; global.confirm = () => false; global.prompt = () => null;
global.location = { hash: '', search: '', pathname: '/admin', href: '' };
global.navigator = { userAgent: 'node' };
global.Notification = function () {}; global.Notification.permission = 'denied';
global.Audio = function () { return stub('audio'); };
global.URL = { createObjectURL: () => 'blob:x', revokeObjectURL() {} };

// 暴露要测的内部函数
new Function('window', script +
  '\nwindow.__t = { epaperItemCard, epaperPreviewStepCard, epaperGroupSteps,' +
  ' setDecisions: (d) => { epaperDecisions = d; } };')(global.window);
const t = global.window.__t;

let ok = 0, bad = 0;
const fail = (what, e) => { bad++; console.log(`  ❌ ${what}: ${e.constructor.name}: ${e.message}`); };

// ---- 1. 批改卡：逐题渲染（会话详情的数据） ----
console.log('1) 批改卡 epaperItemCard —— 用会话数据逐题渲染');
if (!fs.existsSync(SESSION)) {
  console.log(`  ⚠️  没有 ${SESSION}，跳过`);
} else {
  const items = JSON.parse(fs.readFileSync(SESSION, 'utf8')).items;
  const decisions = {};
  for (const it of items) {
    if (it.question_type === 'oeq') {
      decisions[it.id] = { points: {}, liftZero: false, simplifyHalf: false, tenseError: false };
      for (const p of it.points || []) decisions[it.id].points[p.markPointId] = !!p.autoHit;
    } else {
      decisions[it.id] = { finalCorrect: !!it.final_correct };
      if (it.section === 'synthesis') { decisions[it.id].meaningChanged = false; decisions[it.id].langError = false; }
    }
  }
  t.setDecisions(decisions);
  let n = 0;
  for (const it of items) { try { t.epaperItemCard(it, it.seq - 1, false); ok++; n++; } catch (e) { fail(`Q${it.paper_seq} [${it.section}]`, e); } }
  console.log(`  渲染 ${n} 张，失败 ${bad}`);
  // 只读模式也要能渲染（进行中的卷子）
  let ro = 0, robad = 0;
  for (const it of items) { try { t.epaperItemCard(it, 0, true); ro++; ok++; } catch (e) { robad++; fail(`只读 Q${it.paper_seq}`, e); } }
  console.log(`  只读模式 ${ro} 张，失败 ${robad}`);
}

// ---- 2. 预览卡：按分组渲染（试卷预览页的数据） ----
console.log('\n2) 预览卡 epaperPreviewStepCard —— 按分组逐块渲染');
if (!fs.existsSync(QUESTIONS)) {
  console.log(`  ⚠️  没有 ${QUESTIONS}，跳过`);
} else {
  const questions = JSON.parse(fs.readFileSync(QUESTIONS, 'utf8')).questions;
  t.setDecisions({});
  const steps = t.epaperGroupSteps(questions);
  console.log(`  ${questions.length} 题 -> ${steps.length} 个分组（${steps.filter((s) => s.length > 1).length} 个共享段落块）`);
  let n = 0;
  for (const step of steps) {
    try { t.epaperPreviewStepCard(step); ok++; n++; }
    catch (e) { fail(`第 ${step[0].paper_seq}-${step[step.length - 1].paper_seq} 题 [${step[0].section}]`, e); }
  }
  console.log(`  渲染 ${n} 块`);
}

console.log(`\n总计：成功 ${ok}，失败 ${bad}  ${bad === 0 ? '✅' : '❌'}`);
process.exit(bad ? 1 : 0);
