// 回归测试：用真实会话数据调用 epaperItemCard()，覆盖每一种题型。
// 之前那个 "Can't find variable: high" 是块级作用域 bug —— 语法检查过、
// 加载期执行也过，只有真正渲染一张 OEQ 卡片才会抛出来。所以必须真的调它。
const fs = require('fs');
const html = fs.readFileSync('/Users/yihongzhang/Documents/claude-workspace/kid-reminder/backend/admin.html', 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1])[0];

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

// 暴露要测的内部函数
let api = {};
new Function('window', script + '\nwindow.__t = { epaperItemCard, setDecisions: (d) => { epaperDecisions = d; } };')(
  global.window);
api = global.window.__t;

const data = JSON.parse(fs.readFileSync('/tmp/pdf-src.json', 'utf8'));
// pdf-src.json 只有三段，补上其余题型：直接用完整会话
const full = JSON.parse(fs.readFileSync('/tmp/session53.json', 'utf8'));
const items = full.items;

console.log('用会话 53 的 ' + items.length + ' 道题逐张渲染卡片：\n');

// 模拟 openEpaperGradeDialog 里的决策初始化
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
api.setDecisions(decisions);

let ok = 0, bad = 0;
for (const it of items) {
  try {
    api.epaperItemCard(it, it.seq - 1, false);
    ok++;
  } catch (e) {
    bad++;
    console.log(`  ❌ Q${it.paper_seq} [${it.section}] ${e.constructor.name}: ${e.message}`);
  }
}
console.log(`\n渲染成功 ${ok} / 失败 ${bad}`);
if (bad === 0) {
  // 再针对 OEQ 的两个极端各渲染一次（liftRatio 为 null / 非 null）
  for (const variant of [
    { label: 'liftRatio=null', patch: { liftRatio: null, offPoint: null, wordCount: 0 } },
    { label: 'liftRatio=0.9', patch: { liftRatio: 0.9, offPoint: { idle: 2, total: 4, ratio: 0.5, samples: ['x'] }, wordCount: 99 } },
    { label: 'liftExpected', patch: { liftRatio: 1.0, liftExpected: true, offPoint: { idle: 0, total: 2, ratio: 0, samples: [] }, wordCount: 5 } },
  ]) {
    const oeq = items.find((i) => i.question_type === 'oeq');
    const t = Object.assign({}, oeq, variant.patch);
    try { api.epaperItemCard(t, 0, false); console.log(`  ✅ OEQ ${variant.label}`); }
    catch (e) { console.log(`  ❌ OEQ ${variant.label}: ${e.message}`); bad++; }
  }
}
process.exit(bad ? 1 : 0);
