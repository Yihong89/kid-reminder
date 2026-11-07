# Google Classroom 作业看板 · 配置指南

> English summary: Kid Reminder can show what your kid **hasn't turned in** on Google
> Classroom, sorted by how soon it's due. It reads data through a small Apps Script
> Web App deployed under **the kid's own Google account** — no OAuth client, no app
> verification, and it works around the "under-18 users cannot use unconfigured
> third-party apps" policy that commonly blocks OAuth on school accounts.
> Setup takes about 10 minutes; see steps 1–6 below.

macOS app 侧栏里的**「作业」**面板，数据来自这一份 Apps Script。

---

## 它能显示什么

| 能 | 不能 |
|---|---|
| 还没交的**作业 / 测验**，带截止时间、分值、交没交 | 作业附件里的文件内容（只给链接） |
| 老师发的**资料**（Classwork → Materials） | 谁读过公告（API 没有已读状态） |
| 老师发的**公告**（Stream），带正文和时间 | 成绩单 / 报告单 |
| **单元**（Topics）名，用来给作业和资料分组 | 只在 Google Calendar 上出现的事项 |
| 每条都能直接跳转到 Classroom 打开 | 公告/资料没有截止日期，只能按时间排 |

分档规则：

| 分档 | 含义 |
|---|---|
| 已经逾期 | 逾期 4 周以内 |
| 今天必须做 | 今天剩下的时间 **＋ 未来 10 小时内**到期的 |
| 明天截止 / 这周内 / 以后 | 按截止时间排 |
| 很久以前就逾期了 | 逾期超过 4 周，**默认折叠** |
| 没有截止日期 | **默认折叠** |

后两档默认折叠是有原因的：真实数据里，「未完成」往往有一半是老师随手发的、
永远不过期的材料，还有上个月甚至上学期的老帐。它们要是和今天要交的混在一
起，红色就失去意义了，孩子两周内就学会无视整个看板。

「今天必须做」也不按日历日算——凌晨 02:20 截止的作业，日历上是明天，但孩子
今晚就得写完。

### 面板里的三个页签

| 页签 | 内容 | 怎么排的 |
|---|---|---|
| **作业** | 还没交的作业 / 测验 | 按上面的紧急程度分档 |
| **资料** | Classwork → Materials | 按课程分组，课程内再按**单元**分组（没挂单元的落进"未分类"，排在最后） |
| **公告** | Stream 上的公告，标注**老师 / 同学 / 我** | 按课程分组，组内按发布时间倒序 |

资料和公告**没有截止日期**，所以不参与"逾期 / 今天"那套分档——硬塞进去只会
全落进"没有截止日期"这个折叠档，等于看不见。这也是它们单独占一个页签的原因。

公告上的「老师 / 同学 / 我」是**推断**出来的，不是 API 直接给的。Classroom 只返回
`creatorUserId`（一串数字 ID），要反查成名字需要 `profile.emails` 或 `rosters`
权限，学生账号通常被拒——所以看不到名字。

但只有老师能创建作业和资料，所以这两处的 `creatorUserId` 天然构成「老师集合」，
不在集合里的就是同学。判不出来时（比如这门课一门作业都没有）宁可不标，也不瞎标。

展开方式：**课程默认收起**，点开才看到单元；**单元也默认收起**，再点才看到条目。
真实数据里一门课能有一百多条资料，全平铺出来是没法用的。

顶部有搜索框，同时过滤三个页签——标题、课程名、单元名、公告正文都能搜，
中英文都行，大小写不敏感。**一开始搜索，所有分组自动展开**，否则搜到了却
藏在折叠里。清空搜索框就恢复原来的折叠状态。

---

## 为什么不用 OAuth 直接连 Google

Google Classroom API 有两条路，差别在**谁来当那个 OAuth 客户端**：

| | 谁去授权 | 会被学校策略拦吗 |
|---|---|---|
| **Apps Script Web App**（本指南） | Google 自家的 OAuth 客户端 | **实测不会**。学校拦的是「未配置的第三方 App」，Apps Script 是 Google 自己的东西 |
| 自己注册 OAuth client | 你的 `client_id` | 很可能被拦。Google 文档写明：被标记为未满 18 岁的用户，禁止使用未配置的第三方 App |

而且 Apps Script 这条路还省掉了：建 Cloud 项目、配同意屏幕、加测试用户、
等 Google 审核。代价是多一次部署。

---

## 前置条件

- 孩子有一个 Google 账号，并且**能用它打开 <https://script.google.com>**
  - 学校发的 Workspace for Education 账号（如 `xxx@students.edu.sg`）通常可以
  - 如果是个人 `@gmail.com` 账号，同样适用
- 孩子能完成一次 OAuth 授权（会看到"Google hasn't verified this app"，点
  **Advanced → Go to … (unsafe)** 即可，这是自己给自己部署的脚本，正常）

如果打开 `script.google.com` 提示「Apps Script 已被管理员停用」，那这条路走
不通，需要找学校 IT 或改用 Classroom 的日历订阅（只有截止日期，没有完成状态）。

---

## 步骤

### 1. 新建 Apps Script 项目

用**孩子自己的账号**打开 <https://script.google.com> → **New project**。

> 必须用孩子的账号。用家长账号建，读到的会是家长自己的（空的）Classroom。

### 2. 粘贴 Code.gs

左边 `Code.gs` 里原有内容**全部删掉**，粘贴本目录下
[`Code.gs`](Code.gs) 的完整内容。

### 3. 粘贴 appsscript.json

左下 **Project Settings** → 勾上 **「Show "appsscript.json" manifest file in editor」**。

回到编辑器，左边会多出 `appsscript.json`，把它原有内容**整个替换**为
[`appsscript.json`](appsscript.json)。

> 这一步不能省。`student-submissions` 那个权限如果只在界面里勾，经常加不上，
> 结果就是"能看到作业，但不知道交没交"。

这份 manifest 声明了 **5 个 classroom 只读权限**（课程、作业、提交状态、资料、
公告）加 2 个工具权限。

> ⚠️ **从旧版本升级**：权限范围变了，必须**重新部署**（New version）**并且**让
> 孩子重新授权一次。只改代码不重新授权的话，「资料」和「公告」两个页签会一直是空的。

`⌘S` 保存。

### 4. 先跑一次，确认能拿到数据

函数下拉框选 **`probe`** → **Run**。第一次会弹授权：

选孩子的账号 → **Advanced** → **Go to … (unsafe)** → 全部 **Allow**。

下方 **Execution log** 应该打出类似：

```
=== 结论 ===
✓ 全部拿到了。这条路通。
   课程 8 门 / 作业 172 份 / 提交记录 172 条 / 未完成 14 项
```

**这一关不过就别往下做了**，先看文末的故障排查表。

### 5. 部署成 Web App

右上 **Deploy** → **New deployment** → 点左边**齿轮** → 选 **Web app**。

| 字段 | 必须选 | 为什么 |
|---|---|---|
| Execute as | **Me** | 用孩子的身份读数据 |
| Who has access | **Anyone** | app 是匿名的 HTTPS GET，不带 Google 登录态。选 "Anyone with Google account" 会返回登录页而不是 JSON |

点 **Deploy** → 授权 → **Allow**。

部署完会给出两个地址，**只要上面那个**：

```
Web app          https://script.google.com/macros/s/AKfycb.../exec    ← 这个
Test deployment  https://script.google.com/macros/s/AKfycb.../dev     ← 不要
```

`/dev` 只在编辑器里带登录态时能用，app 拉它会失败。

### 6. 生成 Secret

回到编辑器，函数选 **`installSecret`** → **Run**，执行记录会打印：

```
==========================================
URL    : https://script.google.com/macros/s/AKfycb.../exec
Secret : 8f3a…
==========================================
```

`installSecret` 可以重复运行，secret 不会变。

> 它靠 `ScriptApp.getService().getUrl()` 取地址，所以**必须先完成第 5 步部署**，
> 否则 URL 那行会提示"还没部署"。

---

## 填进 app

Kid Reminder → **Settings → Google Classroom 作业**，粘贴 URL 和 Secret →
**测试连接**。成功会显示「成功，拿到 N 项未完成」，然后切到侧栏「作业」。

两个值存在 app 的 `UserDefaults` 里，**不会发到后端服务器**。

---

## 先用终端验一遍（推荐）

把"部署问题"和"app 问题"分开：

```bash
curl -s "把URL粘这里?k=把Secret粘这里" | head -c 300
```

| 返回 | 说明 |
|---|---|
| `{"ok":true,"schema":1,...}` | 通了 |
| `{"ok":false,"error":"bad_secret"}` | Secret 错了 |
| `{"ok":false,"error":"no_secret"}` | 没跑 `installSecret` |
| HTML / 登录页 | Who has access 没选 **Anyone** |
| `404` | 用了 `/dev` 地址 |

---

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `probe` 第 1 关就 403，报 `SERVICE_DISABLED` | Classroom API 没在这个脚本的 Cloud 项目里启用 | 左侧 **Services** → `+` → 添加 **Classroom API**；或用孩子账号打开报错里的 `console.developers.google.com/...` 链接点 Enable，等 1–2 分钟 |
| 授权页报 `admin_policy_enforced` | 学校把 Apps Script 也拦了 | 找学校 IT；或退回 Classroom 日历订阅（只有截止日期） |
| `probe` 说"数据只拿到一半" | `student-submissions.me.readonly` 没批 | 确认第 3 步的 `appsscript.json` 真的替换成功了 |
| app 里「测试连接」报"返回的内容不是预期的 JSON" | Who has access 不是 **Anyone** | 重新部署，改权限 |
| 改了 `Code.gs` 但行为没变 | 没重新部署 | **Deploy → Manage deployments → 铅笔 → Version 选 New version → Deploy** |
| 「资料」「公告」一直是空的 | 升级后没重新授权（权限变多了） | 重新部署后，在编辑器里随便运行一次 `probe`，会重新弹授权；全部允许后再拉一次 |
| 某门课有作业但没有资料 | 老师没发过 Materials，或只存了草稿 | 正常，`PUBLISHED` 之外的不会返回 |
| 面板一直显示"还没连上" | URL / Secret 没填，或填了没保存 | 两个字段都会即时存进 UserDefaults，填完点一次「测试连接」 |
| 作业数量比预期少很多 | 该课程已归档，或老师发的是"材料"而不是"作业" | 正常，只统计 `PUBLISHED` 的 coursework |

---

## 安全与隐私

- **Secret 等价于密码。** 拿到 URL + Secret 的人就能读到孩子所有未交作业的
  标题、课程名、班级名。别贴到聊天、截图、issue 里。
- Secret 存在 Apps Script 的 **Script Properties** 里，不进代码、不进 git。
- app 端只存在本机 `UserDefaults`，**不经过 Kid Reminder 的后端**——后端监听
  `0.0.0.0` 且走明文 HTTP、用共享 PIN 认证，把 secret 交上去等于对整个局域网
  （包括学校 WiFi）开放。
- 想作废：编辑器里改掉 `SECRET` 属性（或删了重跑 `installSecret`），再在 app
  里填新的。
- 数据不出你家：Apps Script 只在你自己的 Google 账号和这台 Mac 之间跑。

---

## 维护

- **改了 `Code.gs` 必须重新部署**（Manage deployments → Edit → New version），
  否则 `/exec` 拉到的还是旧代码。
- 服务端有 60 秒缓存（`CacheService`），app 每 10 分钟自动刷新一次。
- 想手动确认脚本还在正常工作：重跑一次 `probe`，看结论那一段。

---

## 已知限制

- 只能看到「老师发布成作业/测验」的东西，公告和材料不在范围内。
- 完成状态依赖 `student-submissions.me.readonly`。哪天学校收紧了这个 scope，
  看板会退化成纯截止日期列表。
- 没有「标记完成」按钮：作业交没交以 Classroom 为准，本地勾选会和真实状态打架。
- 一个部署对应一个孩子的账号。两个孩子就部署两份，app 里只能填一份，需要
  来回切换（或分别装在两台机器上）。
