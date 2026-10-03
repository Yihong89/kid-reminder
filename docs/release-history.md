# Release history

Auto-update only ever reads `releases/latest`, so old releases are not needed
functionally. The list was tidied on 2026-10-03 down to the feature milestones;
this file keeps the full history so nothing is lost.

| 版本 | 标题 | 发布 | 保留 |
|---|---|---|---|
| `v1.18.7` | v1.18.7 — 修复日历每月开头几天不显示 | 2026-10-01 | ✅ |
| `v1.18.6` | v1.18.6 — 支持 Tailscale 地址连接 | 2026-10-01 | ✅ |
| `v1.18.5` | v1.18.5 — 听写词数改由家长端控制 | 2026-09-16 | ✅ |
| `v1.18.4` | v1.18.4 — 做完卷子提示休息 | 2026-09-12 |  |
| `v1.18.3` | v1.18.3 — 科学练习可断点续做 | 2026-09-11 |  |
| `v1.18.2` | v1.18.2 — 英语试卷可断点续做 | 2026-09-11 |  |
| `v1.18.1` | v1.18.1 — 英语听写改为10个词 | 2026-09-09 |  |
| `v1.18.0` | v1.18.0 — 英文单词听写 | 2026-09-09 | ✅ |
| `v1.17.0` | v1.17.0 — 英语试卷不再即时透露对错 | 2026-09-09 | ✅ |
| `v1.16.0` | v1.16.0 — 英语试卷错题分析报告 + 成绩显示 | 2026-09-08 | ✅ |
| `v1.14.0` | v1.14.0 — 试卷完整文章 + 字体调节 + 修复 | 2026-09-06 | ✅ |
| `v1.11.3` | v1.11.3 — 科学 PSLE 练习模块 | 2026-09-05 | ✅ |
| `v1.10.0` | v1.10.0 — 听写 两栏布局 + 统一听写窗口 | 2026-09-05 | ✅ |
| `v1.9.4` | v1.9.4 | 2026-08-31 |  |
| `v1.9.3` | v1.9.3 | 2026-08-31 |  |
| `v1.9.2` | v1.9.2 | 2026-08-31 |  |
| `v1.9.1` | v1.9.1 | 2026-08-31 |  |
| `v1.9.0` | v1.9.0 | 2026-08-31 |  |
| `v1.8.0` | v1.8.0 | 2026-08-31 |  |
| `v1.7.7` | v1.7.7 | 2026-08-30 |  |
| `v1.7.6` | v1.7.6 | 2026-08-30 |  |
| `v1.7.5` | v1.7.5 | 2026-08-30 |  |
| `v1.7.4` | v1.7.4 | 2026-08-30 |  |
| `v1.7.3` | v1.7.3 | 2026-08-30 |  |
| `v1.7.2` | v1.7.2 | 2026-08-30 |  |
| `v1.7.1` | v1.7.1 | 2026-08-30 |  |
| `v1.7.0` | v1.7.0 | 2026-08-30 |  |
| `v1.6.1` | Kid Reminder v1.6.1 | 2026-08-30 |  |
| `v1.6.0` | Kid Reminder v1.6.0 | 2026-08-30 |  |
| `v1.5.0` | Kid Reminder v1.5.0 | 2026-08-14 |  |
| `v1.4.0` | Kid Reminder v1.4.0 | 2026-08-14 |  |
| `v1.3.0` | Kid Reminder v1.3.0 | 2026-08-14 |  |
| `v1.2.0` | Kid Reminder v1.2.0 | 2026-08-14 |  |
| `v1.1.8` | Kid Reminder v1.1.8 | 2026-08-14 |  |
| `v1.1.7` | Kid Reminder v1.1.7 | 2026-08-09 |  |
| `v1.1.6` | Kid Reminder v1.1.6 | 2026-08-09 |  |
| `v1.1.5` | Kid Reminder v1.1.5 | 2026-08-09 |  |
| `v1.1.4` | Kid Reminder v1.1.4 | 2026-08-09 |  |
| `v1.1.3` | Kid Reminder v1.1.3 | 2026-08-09 |  |
| `v1.1.2` | Kid Reminder v1.1.2 | 2026-08-09 |  |
| `v1.1.1` | Kid Reminder v1.1.1 | 2026-08-09 |  |
| `v1.1.0` | Kid Reminder v1.1.0 (auto-update) | 2026-08-09 |  |
| `v1.0.0` | Kid Reminder v1.0.0 | 2026-08-09 | ✅ |

## 各版本说明

### v1.18.7 — v1.18.7 — 修复日历每月开头几天不显示

## 修复：日历每月开头几天不显示

日历页每个月都看不到 **1～3 日**，只从 4 日往后才显示。

### 原因

日历网格原本是三个并列的 `ForEach`，都用 `id: \.self`：

```swift
ForEach(weekdayNames, id: \.self)               // ["S","M","T","W","T","F","S"]
ForEach(0..<(firstWeekday - 1), id: \.self)     // 月初占位格，Int
ForEach(1...days, id: \.self)                   // 日期格，也是 Int
```

有两处 id 撞车：

1. **星期表头里 `S` 和 `T` 各出现两次** —— 7 个字母只有 5 个唯一 id
2. **占位格和日期格都用 Int** —— `0,1,2…` 和 `1,2,3…` 互相撞

SwiftUI 是按 id 认子视图的，**id 重复会导致内容被丢弃**。而月初的占位格排在日期前面，先被消费掉，所以丢的正好是每月开头的几天。

### 修复

改成**一个扁平数组**，每格 id 带命名空间，从结构上不可能再撞：

```swift
private enum GridCell: Identifiable {
    case weekday(Int)   // id "w0".."w6"
    case blank(Int)     // id "b0".."b5"
    case day(Int)       // id "d1".."d31"
}
```

### 验证

逐月检查 2025–2026 共 24 个月：每格 id 唯一、每一天都出现且只出现一次。

```
2025-01  首日星期=4 天数=31 格子数=41  唯一id=41
   前 21 格: S M T W T F S · · · 1 2 3 4 5 6 7 8 9 10 11
2026-01  首日星期=5 天数=31 格子数=42  唯一id=42
   前 21 格: S M T W T F S · · · · 1 2 3 4 5 6 7 8 9 10

检查 24 个月，失败 0 个 ✅
```

---

**安装**：解压后用 `KidReminder.app` 覆盖旧版本，首次启动右键 → 打开。
应用内「检查更新」也会自动装这一版。

### v1.18.6 — v1.18.6 — 支持 Tailscale 地址连接

## 修复：无法连接 Tailscale 地址

在外面（非家庭局域网）通过 Tailscale 访问时，App 报错：

> Could not connect: The resource could not be loaded because the App Transport Security policy requires the use of a secure connection.

### 原因

App Transport Security 把 **RFC1918 私有地址**（`192.168.x.x`、`10.x.x.x`）当作"本地网络"放行，
但 **Tailscale 用的 `100.64.0.0/10`（RFC6598 CGNAT 段）不算私有**，ATS 会要求 HTTPS。
而客户端代码里 scheme 是固定的 `http`，所以连接被拒。

### 修复

在 Info.plist 中加入 ATS 豁免：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key><true/>
</dict>
```

因为服务器地址由用户在设置里自行填写，无法预先枚举域名白名单，故采用全局豁免。

### 现在可以用的地址

| 场景 | IP / hostname |
| --- | --- |
| 局域网 | `192.168.x.x` |
| Tailscale（在家在外都可用）| `100.x.y.z` |

以后接任何新服务器（Mac Studio 等）都不再受此限制。

---

**安装**：解压后用 `KidReminder.app` 覆盖旧版本，首次启动右键 → 打开。

### v1.18.5 — v1.18.5 — 听写词数改由家长端控制

听写每次的词数现在由**家长在网页端控制**，以后想改不用再动代码。

**默认：中文 40 个 / 英文 20 个**（原来是 30 / 10）。

## 家长端

新增 **⚙️ 设置** 标签页，里面可以改「中文听写每套词数」和「英语听写每套词数」（可填 1–200）。保存后**立即生效**——孩子下次开始听写就用新个数，**App 不用重新下载**。

## 孩子端

听写页的提示文字现在是「会挑 N 个最需要练习的词」，N 读的是服务端设置，会跟着家长的改动自动变（以前是写死的 10 / 30）。

> 只影响**新开始**的听写套题；正在进行的套题和历史记录不受影响。

### v1.18.4 — v1.18.4 — 做完卷子提示休息

孩子做完一份英语卷子后，现在会弹出提示让他**休息 30 分钟**再做下一份：站起来走走、喝点水、看看远处。关掉弹窗后，完成页上还会保留同样的提醒（橙色卡片），防止顺手一点就跳过了。

**休息时长由服务端控制**（环境变量 `EPAPER_REST_MINUTES`，默认 30 分钟）。以后想调成 20 或 45 分钟，只要改服务端配置重启即可，**不用再下载新 App**。

顺带：家长端现在能看到每次练习的用时——会话列表和批改对话框里会显示「用时 38 分钟」，方便对照真实 PSLE Paper 2 的 1 小时 50 分钟。

---
更新方式：打开 App 会自动检查新版本，按提示更新即可。

### v1.18.3 — v1.18.3 — 科学练习可断点续做

科学（PSLE）练习现在也支持断点续做，跟英语试卷一样：孩子强退或崩溃后不会再留下卡死的记录，重新打开同一份卷子（或错题本）会自动接着上次没做完的地方继续，完成后的自动判分总分也会正确算上之前已经答过的题（之前会漏算）。后台新增"✅ 标记可批改"按钮，用于孩子中途换了另一份卷子、旧的那份卡在"进行中"时手动收尾。

### v1.18.2 — v1.18.2 — 英语试卷可断点续做

英语试卷（epaper）练习现在支持断点续做：孩子强退或崩溃后不会再留下无法批改的卡死记录，重新打开同一份卷子会自动接着上次没做完的地方继续（跳过的题也不会把进度拉回去）。后台新增"✅ 标记可批改"按钮，用于孩子中途换了另一份卷子、旧的那份卡在"进行中"时手动收尾。

### v1.18.1 — v1.18.1 — 英语听写改为10个词

英语听写每次改为听写10个单词（原来是30个）；中文听写维持30个不变。

### v1.18.0 — v1.18.0 — 英文单词听写

## 英文单词听写

- 家长在网页端新增"🔤 英语听写词库"标签页：添加英语单词（单词+例句+分类），孩子在 App 侧边栏新增的"英语听写"里听写、系统自动挑最需要练习的30个词
- 家长批改后自动统计正确率，体验跟中文听写完全一致；已预置40个精选英文单词（silent letters / double letters / -ough family 等常见拼写陷阱）
- 后端复用了 vocab_words 的 language 字段做成通用双语听写管线，中文听写行为完全不受影响

### v1.17.0 — v1.17.0 — 英语试卷不再即时透露对错

## 英语试卷：做题时不再透露对错和答案

- 每答完一题只显示"已提交"，不再显示答对/答错、正确答案或解析
- 只有等家长在网页端批改完整张卷子，孩子才能通过成绩徽章和下载的错题报告看到结果
- 起因：发现孩子利用即时反馈作弊，堵上这个漏洞

### v1.16.0 — v1.16.0 — 英语试卷错题分析报告 + 成绩显示

## 英语试卷：错题分析报告 + 成绩显示

- 卷子列表每行显示最近一次已批改完成的成绩（如 `67/90 · 74%`）
- 新增"下载错题报告"按钮：一键把这次考试的错题分析报告（英文，孩子能看懂）存到 `~/Downloads`。每道错题都包含原题、正确答案/得分点、错误原因分析和提高建议
- 后端新增 `GET /api/epaper/sessions/:id/report` 生成该报告；`GET /api/epaper/papers` 附带每张卷子的最近成绩

### v1.14.0 — v1.14.0 — 试卷完整文章 + 字体调节 + 修复

## v1.14.0

（本次合并了此前 v1.12.0 / v1.13.0 / v1.13.1 的改动，并撤销了那些历史 tag，改为单版发布。）

### 功能
- 英语 / 科学试卷运行器：右侧显示**完整文章**（14 份卷子阅读理解补齐），题目按要求分组。
- **Q21-25** (Visual Text) 放在一起考：右侧 Text 1 海报 + Text 2 文案，左侧 5 题一起作答提交。
- **字体大小调节**：试卷运行器工具栏 A− / A+（带百分比）缩放阅读文字，跨卷生效。
- **编辑题**不再提示是拼写还是语法错误，孩子自行判断；错误词加下划线。
- **跳过**按钮：可快速翻完整卷检查内容，不必逐题作答。

### 修复
- **错题本**：做错的客观题不再在提交时自动进错题本，只有家长批改/复核判定为错后才加入；已清空测试产生的错题本数据。
- **科学试卷预览**：修复 `s.replace is not a function` 崩溃。
- **PIN 门控**：改 PIN 后，旧浏览器登录态不再"刷新就进去"，会重新校验并提示输入新 PIN。
- macOS 科学 / 英语试卷的 ▶️ 按钮改为「开始」。

### 更新
Mac 端启动自动检查更新，或 设置 → 更新 → 下载并更新。通用包（Apple Silicon + Intel）。

### v1.11.3 — v1.11.3 — 科学 PSLE 练习模块

## 科学 PSLE 练习模块

孩子可以练**科学（PSLE）开放式问答**，错题自动汇入错题本。

- 新增科学练习入口与做题流程，**批改移到网页端**，错题收录进错题本。
- 内置 2025 年多所小学的科学试卷题库（扫描件题目裁剪图片），覆盖 10 家学校。
- **科学 runner 作为独立可最大化窗口**打开，不再是 sheet。

### 后端加固

- 变更类 API 增加**审计日志**。
- 停止把管理员 PIN 打印到 server.log。

## 更新方式

Mac 端应用启动时自动检查更新；也可在 **设置 → 更新** 里点 **下载并更新** 直接安装。

### v1.10.0 — v1.10.0 — 听写 两栏布局 + 统一听写窗口

## 听写 UI 重做

听写页面从一列居中的按钮改成了真正的 macOS 两栏布局：

- **左栏 — 📋 听写记录**：已批改的听写结果，点一下看每个词的 ✓/✗。待批改和未完成的不再显示（批改是家长在网页端做的事）。
- **右栏 — 📚 自定义听写表**：每张表后面跟一个 ▶️ 播放按钮，点表名本身可以管理内容。
- 两栏各自独立滚动，表头固定不动。

### 同一个听写窗口

**🎲 随机听写** 和任意一张自定义表的 **▶️**，现在打开的是同一个窗口。之前这两条路径各有一份几乎一样的播放界面（只差 题/条 和要不要提交批改），现在合并成一个 `DictationRunnerView`。

听写进行中是模态窗口，侧边栏点不动 —— 顺带让「切换标签页把听写状态弄丢」这个老问题不可能再发生。

### 播放界面改进

- 加了进度条，题号字号加大
- 空格键 = 重听，回车键 = 下一题

### 内部

- 删除 `CustomDictationPracticeView.swift`（已被统一窗口取代）
- `DictationHistoryView.swift` → `DictationSessionDetailView.swift`
- 之前修过的坑原样保留：单个 `.sheet(item:)`、每个 sheet 根视图的 `.frame(minWidth:minHeight:)`、按钮按 `isBusy` 而不是 `isPlaying` 禁用、`DictationAudioPlayer` 完全没动

### v1.9.4 — v1.9.4

## Likely fix + diagnostics: blank dictation session detail

Applied the same sizing fix that resolved the list screen
(`.frame(minWidth: 420, minHeight: 420)`) to the per-session detail
screen (the words/results you see after tapping a record). Also added
logging in case that's not the whole story this time.

If it's still blank after updating: Settings → 开发者日志 → 清空日志, open
一条听写记录的详情 once, then 复制日志到剪贴板 and send it over.

### v1.9.3 — v1.9.3

## Actual fix: blank "我的听写记录" sheet

The dev log from v1.9.2 confirmed the data was loading correctly (2
sessions, right host/pin) — the sheet just had no explicit minimum size,
so on macOS it could render too small to see. Added the same
`.frame(minWidth: 420, minHeight: 420)` already used successfully
elsewhere in the app to the dictation-history, custom-list-practice, and
custom-list-editor sheets.

### v1.9.2 — v1.9.2

## Diagnostics only — not a fix this time

v1.9.1's sheet-consolidation fix didn't resolve the blank 我的听写记录
screen after all. Added logging so the next Developer Log capture shows
exactly where it's breaking: never presented, presented but never
loads, loads but errors, or loads with 0 results.

Please: Settings → 开发者日志 → 清空日志, then open 我的听写记录 once, then
复制日志到剪贴板 and send it over.

### v1.9.1 — v1.9.1

## Fix: "我的听写记录" sheet showing blank

Confirmed the data was always there (checked directly against the Mac
Mini) — this was a SwiftUI bug from having four separate sheet
presentations stacked on the dictation screen (history, custom-list
practice, create list, edit list), which can flakily show a blank sheet.
Consolidated into a single, reliable sheet presentation.

### v1.9.0 — v1.9.0

## New: custom dictation lists (自定义听写表)

Alongside the standard 30-word auto-selected dictation, you can now
create your own lists to practice — a single word, a phrase, or a whole
sentence, typed in by either the parent (web admin) or the kid (right in
the app). No grading needed, and no limit on repeats — perfect for a
spelling list, a batch of sentences, or anything else you want to drill.

- App: the dictation screen now shows your custom lists alongside the
  usual "30词听写" button — tap ▶️ to practice or ✏️ to manage one, or
  "➕ 新建自定义听写表" to start a new one.
- Web admin: new "自定义听写表" tab for the same management, parent-side.

### v1.8.0 — v1.8.0

## New: see your own dictation results in the app

Graded ✓/✗ results used to only show up in the parent's web admin. Now
there's a "📋 我的听写记录" button on the dictation screen — tap it to see
past graded sets (date, score) and, per set, exactly which words you got
right or wrong.

## Also included (backend, already live)

- Dictation word selection now picks 30 words directly by weakest-first,
  lower-grade-breaks-ties priority, instead of a random pool of characters.
- Background audio pre-caching for a whole dictation set as soon as it's
  generated, so words are ready before you tap 下一题.

### v1.7.7 — v1.7.7

## Cleanup

Removed the "卡住了？点这里重试这道题" manual recovery link from dictation —
it was a workaround for the playback-completion stall fixed in v1.7.6, and
isn't needed anymore.

### v1.7.6 — v1.7.6

## Likely real fix: dictation "stuck showing 正在朗读" bug

The v1.7.5 dual heartbeat gave a conclusive answer: during a stall, a
classic Timer kept ticking every second without interruption, while a
Task.sleep-based timer froze solid for the same window — and the app
stayed fully responsive throughout (switching tabs still worked). That
points at Swift Concurrency's own task scheduling occasionally stalling
on this machine, not the audio, not App Nap, not a real freeze.

This version stops relying on that for anything in the playback-completion
path — the safety net, the recovery-hint timer, and the hop off
AVFoundation's finish callback now all use plain Timer/DispatchQueue
instead, which the evidence shows stays reliable.

Please keep an eye on it and send another Developer Log if it still
happens — but this should be the real fix, not another mitigation.

### v1.7.5 — v1.7.5

## Diagnostics only — not a fix this time

The App Nap fix in v1.7.4 didn't help (the delay got worse, not better),
which rules that theory out. Rather than guess again, this version adds
two independent "heartbeat" log lines every second during playback, on
two different timer mechanisms, so the next Developer Log capture can
show exactly what's stalling instead of us guessing.

If it gets stuck again: please note whether the rest of the app (switching
tabs, etc.) is responsive during the stall, then grab the Developer Log as
before (Settings → 开发者日志 → 复制日志到剪贴板).

### v1.7.4 — v1.7.4

## Likely fix: dictation "stuck showing 正在朗读" bug

The Developer Log added in v1.7.3 caught it: playback timers were being
delayed by several seconds, consistent with macOS's App Nap throttling the
app while it sits idle (dictation is "listen and write on paper," so
there's no screen interaction during a clip). The app now tells macOS not
to throttle it while a word is playing.

Also fixed the "卡住了？点这里重试" hint staying visible after playback
actually finished successfully (it only used to clear at the start of the
next word).

Please grab another Developer Log after this update (Settings → 开发者日志)
so we can confirm the delay is gone, or catch it if not.

### v1.7.3 — v1.7.3

## Added: Developer Log (Settings → 开发者日志)

Records internal events for dictation playback (and its recovery
mechanisms) to a small local log file, so intermittent issues — like the
reported stuck-playing bug — can actually be diagnosed instead of guessed
at. Three actions: copy the log to the clipboard, reveal it in Finder, or
clear it. Doesn't affect normal use.

### v1.7.2 — v1.7.2

## Fix: dictation could lose all progress when it got stuck (or when switching tabs)

Switching away from the 听写 tab and back used to silently abandon the
in-progress session and start over from scratch. Now it resumes the same
session instead — no more starting over after navigating away to recover
from a stuck screen (or just checking another tab mid-dictation).

## Added: manual recovery if a word's audio doesn't respond

If a word's read-aloud doesn't wrap up within 6 seconds, a small "卡住了？
点这里重试这道题" link appears — tap it to force-retry that word without
losing your place.

### v1.7.1 — v1.7.1

## Fix: dictation could get permanently stuck after the audio finished

If the read-aloud audio's finish signal ever failed to reach the app (rare,
not consistently reproducible), the UI would stay showing "正在朗读" forever
with 下一题 disabled, even though the clip had already finished playing.

Added a safety-net timeout: if playback doesn't get acknowledged as finished
within its own duration (+1.5s grace), the app now unlocks the next question
on its own instead of hanging indefinitely.

### v1.7.0 — v1.7.0

## English wrong-answer practice (错题练习)

- New question bank (`english_questions`) seeded from the kid's own real
  mistake log - fill-in-the-blank/spelling, multiple choice, and sentence
  transformation questions, each with the correct answer and a short
  explanation.
- Self-graded quiz sessions: typed/tapped answers are checked automatically
  (no parent grading step needed), pulling 10 questions weighted toward the
  ones the kid has gotten wrong most often - same adaptive weak-pool
  algorithm as Chinese dictation.
- Spelling-flavored fill-blank questions get a speaker button that reads the
  completed sentence aloud.
- A one-time self-override lets the kid flip a sentence-transformation
  verdict the auto-grader was too strict about.
- Web admin: new 英语错题 tab with full add/edit/delete/search for the
  question bank.
- macOS app: new 英语错题 tab to take quizzes, plus a "➕ 添加一道错题" form so
  new mistakes can be logged straight from the app into the same bank the
  web admin manages.

## Reliability

- TTS now falls back to macOS's built-in voices when the neural TTS service
  is busy or unavailable, instead of leaving the speaker button dead.
- Fixed a bug where a slow/failing audio fetch could leave playback stuck
  showing "playing" with no sound.
- Fixed foreign-key-constraint errors when deleting a vocab word or English
  question that already had quiz/dictation history attached to it.
- Fixed a CSS bug where hidden form sections in the admin panel's add/edit
  dialogs didn't actually hide.

## Chinese dictation cleanup

- Deduplicated vocab words that appeared in both the 识读 and 识写 lists,
  keeping only the 识写 entry, while preserving real dictation history.
- Dictation records now show on the parent web admin panel, with a delete
  button for abandoned in-progress sessions.

### v1.6.1 — Kid Reminder v1.6.1

## 🛠️ Fix: crash on Apple Silicon Macs

**v1.6.1** — v1.6.0 was accidentally built as an x86_64-only binary, which had to run under Rosetta translation on Apple Silicon Macs and could **crash on launch or the first time audio played** (a Rosetta issue with CoreAudio's format converter, hit via the new 听写 TTS playback). No feature changes from v1.6.0 — just a proper universal (arm64 + x86_64) binary this time, native on both Apple Silicon and Intel Macs.

If v1.6.0 crashed for you, update to this release.

### Install
Unzip `KidReminder.zip`, move `KidReminder.app` to Applications, right-click → **Open** on first launch (ad-hoc signed). Enter server IP, port, and PIN in **Settings**.

### v1.6.0 — Kid Reminder v1.6.0

## 📝 Chinese Dictation (听写)

**v1.6.0** — a full 听写 (dictation) practice loop, built for PSLE Chinese prep: a vocab bank scraped from the official MOE character lists, TTS read-aloud, adaptive weak-word selection, and parent grading.

- **Vocab bank** — 8,706 words (character + compound word + pinyin + example sentence), covering P3–P6 mainstream Chinese plus the 38 characters exclusive to Higher Chinese. Parents can search/filter/add/edit/delete entries from a new **📚 生词库** tab in the web admin panel.
- **Adaptive sessions** — each listening test picks 10 characters from the 60 lowest-scoring (by average `correct_count`), up to 3 words each, in shuffled order — so practice keeps circling back to what the kid is weakest at.
- **Read aloud, not shown** — the macOS app's new **听写** tab plays each word + example sentence via TTS; the screen only shows "第 N 题 / 共 M 题" progress, never the text itself. 重听 (replay) and 下一题 (next) are disabled while audio is loading or playing, so a slow first-time synthesis can't be skipped past.
- **Parent grading** — a new **📝 听写批改** tab lists finished-but-ungraded sessions; grading shows every item in the order it was dictated (character/word/pinyin/sentence) so a parent can follow along against the paper answer, defaulting to ✓ with a tap to flip any wrong ones. Submitting updates each word's `correct_count` (+1 / −1, floored at 0).
- **TTS backend** — server-side synthesis (cached forever per word, regenerated only if the word's text is edited), no client-side speech synthesis needed.

### Install
Unzip `KidReminder.zip`, move `KidReminder.app` to Applications, right-click → **Open** on first launch (ad-hoc signed). Enter server IP, port, and PIN in **Settings**. Update the backend files first (`server.js`, `admin.html`) so the new `/api/vocab`, `/api/dictation/*`, and `/dictation-audio/*` routes exist, and set up the TTS backend your server calls into.

### v1.5.0 — Kid Reminder v1.5.0

## 🎵 Task-Done Chime

**v1.5.0** — every time the kid checks off a task, a **cheerful chime** plays to celebrate (web panel + macOS app).

- Short, bright rising arpeggio — different from the unlock fanfare so each moment has its own sound.
- Plays on the **Today**, **Calendar**, and **Countdown** views in the macOS app, and when marking done in the web panel.
- Sound is synthesized in-repo (no licensing issues) and served from the backend (`/sounds/done.wav`).

### Install
Unzip `KidReminder.zip`, move `KidReminder.app` to Applications, right-click → **Open** on first launch (ad-hoc signed). Enter server IP, port, and PIN in **Settings**. Update the backend files first (see backend-setup.md) so `/sounds/done.wav` is served.

### v1.4.0 — Kid Reminder v1.4.0

## ⚡ Generations — Johto auto-unlocks after Kanto

**v1.4.0** — the Pokémon collection now has **2 generations**:

- **Kanto (1–151)** — the starting generation.
- **Johto (152–251)** — appears **automatically** (as a second tab) once the kid completes **all 151 Kanto Pokémon**.
- Generation switcher in the web panel (tabs) and the macOS app (segmented picker); locked generations are greyed out.
- Unlock rules unchanged: spend 1 ⭐ stamp per random unlock, fanfare + reveal, click for details.

*Sprite art from public PokéAPI (non-commercial private family use).*

### Install
Unzip `KidReminder.zip`, move `KidReminder.app` to Applications, right-click → **Open** on first launch (ad-hoc signed). Enter server IP, port, and PIN in **Settings**.

### v1.3.0 — Kid Reminder v1.3.0

## ⚡ Pokémon Collection

**v1.3.0** — the achievement system is now a **Pokémon collection** on its own panel:

- **⚡ Pokémon panel** (new tab in web + new view in the macOS app) — the full **151-entry Kanto Pokédex**.
- **Locked slots show a ?** — every Pokémon starts hidden.
- **Spend a ⭐ stamp to randomly unlock** a Pokémon — each unlock plays an **exciting fanfare** and reveals the Pokémon with a pop animation.
- **Click an unlocked Pokémon** to see a **bigger sprite with details** (name, number, types).
- Stamps are still earned by finishing all of the day's tasks (gold markers on the calendar).

*Sprites + fanfare served from the backend (/sprites/, /sounds/) — non-commercial, private family use of public PokéAPI sprite art.*

### Server
Backend was updated (unlock API + 151 sprites + fanfare) — deploy the new server files first, then update the app.

### Install
Unzip `KidReminder.zip`, move `KidReminder.app` to Applications, right-click → **Open** on first launch (ad-hoc signed). Enter server IP, port, and PIN in **Settings**.

### v1.2.0 — Kid Reminder v1.2.0

## 🏅 Achievements & Sticker System

**v1.2.0** — when the kid finishes **all** of today's tasks, the parent can award a **⭐ stamp**:

- **Stamps** — award from the web panel (server verifies all tasks are done); shown as gold markers on the calendar.
- **Levels** — every **5 stamps** levels the kid up.
- **Pokémon stickers** — each level unlocks a sticker (Pikachu → Bulbasaur → Charmander → Squirtle → Eevee → Vulpix → Jigglypuff → Snorlax → Dragonite → Mew), shown in the new **Stickers** panel (web + macOS app).
- **macOS app** — new Stickers sidebar view, gold stamp markers on the calendar, and a 🎉 all-done banner with "ask for a stamp" prompt.

*Sprites served from the backend (/sprites/) — non-commercial, private family use of public PokéAPI sprite art.*

### Server
The backend was updated (stamps API + sprite serving) — deploy the new server files first (see backend-setup.md). Then update the app via **Settings → Updates → Download & Update** or grab the zip below.

### Install
Unzip `KidReminder.zip`, move `KidReminder.app` to Applications, right-click → **Open** on first launch (ad-hoc signed). Enter server IP, port, and PIN in **Settings**.

### v1.1.8 — Kid Reminder v1.1.8

## 🔒 Parent-only tasks (macOS app)

**v1.1.8** brings the parent-only task feature to the macOS app, matching the web panel:

- **🔒 Parent only toggle** in the Add-task form — shown only in admin mode; those tasks are hidden from the kid's view everywhere (server-enforced).
- **Lock badge** on parent-only tasks in the Today list, the next-7-days section, and the Calendar day view (admin mode).
- Universal build (Apple Silicon + Intel), ad-hoc signed.

### Server
The backend (v1.1.7+ server code) already enforces parent-only tasks — this release adds the app-side UI. Update the server first if you haven't (see backend-setup.md), then update the app via **Settings → Updates → Download & Update** or grab the zip below.

### Install
Unzip `KidReminder.zip`, move `KidReminder.app` to Applications, right-click → **Open** on first launch (ad-hoc signed). Enter server IP, port, and PIN in **Settings**.

### v1.1.7 — Kid Reminder v1.1.7

# Kid Reminder v1.1.7

- **Show repeat frequency** on every task row (weekly / biweekly / monthly /
  once), matching the web panel
- **Fix adding recurring events**: the picked date is now sent, so a weekly /
  monthly event anchors to the date you choose (not just countdown events)

### v1.1.6 — Kid Reminder v1.1.6

# Kid Reminder v1.1.6

- **Clean rounded app icon** — fixed the renderer (SVG is rendered directly, no
  more gray border on the bottom/right edges). Matches the standard macOS icon
  proportions (rounded corners, ~9% margin).

### v1.1.5 — Kid Reminder v1.1.5

# Kid Reminder v1.1.5

- **Full-bleed app icon** — macOS applies the rounded corners itself, so there
  are no transparency/shadow lines in the Dock or Launchpad

### v1.1.4 — Kid Reminder v1.1.4

# Kid Reminder v1.1.4

- **Proper macOS-style icon** — rounded corners (transparent, no white border)

### v1.1.3 — Kid Reminder v1.1.3

# Kid Reminder v1.1.3

- **Fix the app icon** — the background now fills the whole canvas, so the
  white border is gone
- Universal build (Apple Silicon + Intel)

### v1.1.2 — Kid Reminder v1.1.2

# Kid Reminder v1.1.2

- **Fix auto-update check** — it now reads the release even while GitHub is
  still processing a freshly uploaded zip (the download URL is built from the
  release tag, so it's always available)
- Friendly message + Try again when GitHub is unreachable

### v1.1.1 — Kid Reminder v1.1.1

# Kid Reminder v1.1.1

- Friendlier message when the update check can't reach GitHub (instead of a cryptic data error)
- Adds a **Try again** button in Settings → Updates
- Universal build (Apple Silicon + Intel)

### v1.1.0 — Kid Reminder v1.1.0 (auto-update)

# Kid Reminder v1.1.0

Adds **automatic updates**: the app checks GitHub for a new version on launch,
and in Settings → Updates you can **Download & Update** — it fetches the new
version, swaps itself, and relaunches. No more manual downloads.

- ✅ Auto-update (check + download + install + relaunch)
- ✅ Today checklist with "Next 7 days" countdown preview
- ✅ Calendar, Countdown panel, school-focused emoji
- ✅ Universal build (Apple Silicon + Intel)

## Install
1. Download **KidReminder.zip**
2. Unzip → **KidReminder.app** → move to **Applications**
3. First launch: **right-click → Open** (ad-hoc signed; macOS warns once)
4. In **Settings**, enter the Mac Mini IP, port `2021`, and your PIN

Future versions will offer an in-app update button instead of a manual download.

### v1.0.0 — Kid Reminder v1.0.0

# Kid Reminder for macOS

A daily **homework & tuition reminder** for the kid, syncing with the family server on the Mac Mini.

## Download
- **KidReminder.zip** — universal build (works on Apple Silicon **and** Intel Macs)

## Install
1. Download **KidReminder.zip**
2. Double-click to unzip → **KidReminder.app**
3. Drag it into **Applications**
4. **First launch:** right-click the app → **Open** → **Open** (it's ad-hoc signed, so macOS shows a warning once — that's normal)

## Connect it
Open the app → **Settings** → enter:
- **IP:** the Mac Mini's address (ask your parent)
- **Port:** `2021`
- **PIN:** parent PIN (full control) or kid PIN (own tasks only)

## Features
- ✅ Today checklist with time tracking
- 📅 Calendar with completion dots + countdown-event markers
- ⏳ Countdown panel for exams & deadlines (21-day window)
- ➕ Kids can add tasks; they can only edit/delete their own
- Settings apply immediately — no restart needed

