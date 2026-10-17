# OEQ 判分改用 oeq-grader —— 设计方案（未实施）

> 2026-10-13 起草。**2026-10-17 已实施。**
> 目的：把 kid-reminder 里 OEQ「AI 第二意见」的后端从本机 Ollama 换成 oeq-grader 服务。
>
> **实施记录（2026-10-17）**
>
> - `epaperAiSuggest()` 改为 `POST ${OEQ_GRADER_URL}/api/v1/grade`，`ai_hit` 取
>   `points[].aiVerdict`（yes→1 / no→0 / unknown→不写），`ai_reason` 改为**逐点**理由
>   （原来每个点都写同一段 raw 文本）。
> - 第八节的三个待定项，按实施时的决定：**隐私接受**（同一台机器上的 grader 本来就在用，
>   孩子这几份卷子的答案早已经它送到 DeepSeek）；**Ollama 那条路删除**
>   （`OLLAMA_URL` / `OLLAMA_MODEL` / `AI_KEEP_ALIVE` / 两段提示词一并删掉，回退靠 git）；
>   **只送漏判的点**（第五节「触发时机不变」优先）。
> - **句子改写（synthesis）也一并接入** `epaperAiJudgeObjective()`：`section: "synthesis"`
>   + `correctAnswer`，满分才算「意思对」（`ai_correct` 只作提示，不参与计分）。
> - 实测（数据库副本 + 真实 grader）：OEQ 漏判点返回 `ai 0` 与逐点中文理由；
>   synthesis 返回「意思有出入 / 句式不对 / 语法扣 1 分」三条理由；
>   `OEQ_GRADER_URL` 指向死端口时提交照常成功、`ai_hit` 保持空。
> - 环境变量：新增 `OEQ_GRADER_URL`（默认 `http://127.0.0.1:8790`），其余不变。

## 一、摘要

kid-reminder 现在判阅读理解问答题（comprehension_oeq）分两步：先用**关键词匹配**自动判，
漏判的点再交给**本机 Ollama** 出「第二意见」，家长复核时参考。

oeq-grader 是同一个 Mac mini 上的独立判分服务（端口 8790），用 DeepSeek 判，
规则已经用四份老师批改过的卷子调了很久（照抄豁免、按 `point_kind` 分流、3 票多数表决）。
**它的接口我们实测过了**（2026-10-13，见附录），返回结构正好覆盖 kid-reminder 需要的字段。

这次改动**只换传输层**：调用谁变了，判分触发时机、失败处理、计分口径、家长复核链全部不变。

## 二、现在是怎么判的（as-is）

```
孩子提交一道 oeq 题
  └─ epaperAutoHit(point, answer)      关键词匹配，逐点得 auto_hit 0/1
       └─ 命中为 1 的点：直接算
       └─ 漏判的点（auto_hit=0）→ 攒进 missed[]
            └─ epaperRunAiSuggest(itemId, question, answer, missed)   ← fire-and-forget
                 └─ epaperAiSuggest(...)  POST {OLLAMA_URL}/api/chat
                      └─ 提示词里塞 prompt/passage/answer/漏判的点
                      └─ 正则抓 "N: YES/NO"
                 └─ 写 epaper_item_points.ai_hit / ai_reason
家长复核 ── 逐点确认 final_hit / final_correct  ← **计分只用这个**
```

代码位置（`backend/server.js`）：

| 位置 | 作用 |
|---|---|
| L67-75 | 配置：`AI_GRADING`、`OLLAMA_URL`、`OLLAMA_MODEL`、`AI_TIMEOUT_MS`、`AI_KEEP_ALIVE` |
| L1281 | `epaperAiSuggest()` —— 调模型、解析 YES/NO |
| L1327 | `epaperRunAiSuggest()` —— fire-and-forget + 落库 |
| L3607 | 提交时调用（只传漏判的点） |
| L1391 | 句子改写（synthesis）另有一条同类路径，本次不动 |

数据现状（2026-10-13 实测）：

- `epaper_questions` 里 **300 道** comprehension_oeq 题，共 **597 个** mark point
- `epaper_mark_points.point_kind` 是齐的：`textual_evidence` 322 / `inference` 173 /
  `multi_part` 45 / `keyword` 57 —— 这正是 oeq-grader 判分需要的类型信息

## 三、想要的样子（to-be）

只把 `epaperAiSuggest()` 里的 HTTP 调用换掉：

```js
// 现在
const res = await fetch(`${OLLAMA_URL}/api/chat`, { ... 拼好的提示词 ... });
const text = out.message.content;
for (const m of text.matchAll(/(\d+)\s*[:.\-]\s*(YES|NO)/gi)) verdicts.set(...);

// 换成
const res = await fetch(`${OEQ_GRADER_URL}/api/v1/grade`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    question: { prompt: q.prompt, marks: q.marks, section: "comprehension_oeq", passage: q.passage },
    markPoints: points.map(p => ({ seq: p.seq, description: p.description, pointKind: p.point_kind })),
    answer,
  }),
});
const out = await res.json();
for (const p of out.points || []) {
  verdicts.set(p.seq, p.aiVerdict === "yes" ? 1 : 0);
  reasons.set(p.seq, p.aiReason || "");     // 逐点理由，比现在整段 raw 更有用
}
```

响应里可以直接用的字段（实测）：

```jsonc
{
  "score": 2, "maxScore": 2, "needsHuman": true, "scoreBasis": "ai",
  "points": [
    { "seq": 1, "description": "...", "aiVerdict": "yes", "aiReason": "...", "earned": true, "basis": "ai" }
  ],
  "signals": { "liftRatio": 0, "evidenceHeavy": false, "lengthLimit": 39, ... },
  "reasons": ["模型逐要点判定：2/2 个要点答到", "..."],
  "ai": { ... }
}
```

需要落库的还是那两个字段，语义不变：

| 字段 | 现在 | 换成之后 |
|---|---|---|
| `epaper_item_points.ai_hit` | Ollama 的 YES/NO | grader 的 `points[].aiVerdict` |
| `epaper_item_points.ai_reason` | 整段 raw 文本（截 300 字） | 该点的 `aiReason`（逐点、更短更有用） |

## 四、配置

| 变量 | 默认 | 说明 |
|---|---|---|
| `OEQ_GRADER_URL` | `http://127.0.0.1:8790` | 新增。grader 与 kid-reminder 同机，走 localhost |
| `AI_GRADING` | 不变 | `0` 关闭整条 AI 第二意见路径（保留现有总开关） |
| `AI_TIMEOUT_MS` | 180000 | 不变。grader 内部 3 票 + 每票一次 DeepSeek，实测单题数秒 |

`OLLAMA_URL` / `OLLAMA_MODEL` / `AI_KEEP_ALIVE` 若不再使用，一并删掉或保留为死配置（待定，见第八节）。

## 五、明确不变的部分

这一点比改了什么更重要：

- **触发时机**：仍然只在「关键词漏判的点」上跑，仍然 fire-and-forget，提交请求不等它
- **失败语义**：grader 挂了 / 超时 / 返回看不懂 → 当作没有建议，什么都不写，绝不抛给调用方
- **`auto_hit` 不动**：AI 结果只写 `ai_hit`，关键词判定保持原样，两者在后台并排显示
- **计分口径不动**：`epaperComputeScore` 用 `final_correct`（家长确认过的），`ai_hit` 从不参与计分
- **家长复核链不动**：后台仍然是「自动判定 / AI 建议 / 家长最终」三列
- **sentence synthesis 那条 AI 路径不动**（L1391）

## 六、影响与风险

**1. 隐私：孩子的答案会离开本机。** ← 这是唯一需要你点头的地方

现在那条路径是纯本机 Ollama，代码注释写的就是「a child's answers never leave the house」。
换成 oeq-grader 后，答案会经 grader 送到 **DeepSeek 云端**（grader 每次判分跑 3 票）。
服务端到服务端，不经浏览器、不经第三方，但**确实出网**。

**2. 成本**：每道 OEQ 题 3 次 DeepSeek 调用（`OEQ_AI_VOTES=3`）。
一份卷子 10 道 OEQ ≈ 30 次；家长复核前就会跑完。量级很小，但要心里有数。

**3. 质量**：预期是提升 —— grader 的规则是用老师批改过的卷子校准的，
而且它会按 `point_kind` 分流（`textual_evidence` 允许照抄、`inference` 要求自己推理），
这是本机 Ollama 那条提示词做不到的。但**需要用真实历史数据验证**，见第七节。

**4. 依赖**：kid-reminder 的 OEQ 第二意见从此依赖另一个服务的存活。
因为失败即静默，grader 挂掉只会退化成「没有 AI 建议」（= 这个功能上线前的行为），不会报错给孩子。

**5. 一致性**：oeq-grader 自带 3 票多数表决；平票返回 unknown。映射时 unknown 的点直接跳过（不写 ai_hit），保持「不确定就不表态」。

## 七、验证方案（实施后按这个跑）

1. **接口契约**：已实测（附录）。实施后再跑一次，确认 `points[].aiVerdict` 稳定。
2. **离线重放**：从 `epaper_session_items` 里挑若干已提交的 oeq 作答（有 `auto_hit` 和
   家长 `final_hit` 的历史记录），分别跑旧路径（Ollama）和新路径（grader），
   对比 `ai_hit` 与家长 `final_hit` 的一致率。**谁的错判少就用谁** —— 这是判据。
3. **故障演练**：把 `OEQ_GRADER_URL` 指向一个不存在的端口，提交一道 OEQ，
   确认既不报错、也不写坏数据、也不阻塞提交。
4. **端到端**：让 app 提交一道真实 OEQ，确认后台三列（自动/AI/家长）显示正常。

## 八、待决定的问题

1. **隐私**：接受孩子的答案上 DeepSeek 云端吗？（不接受的话这个方案就不成立，
   或者只对「家长手动触发」的题目跑，而不是每次提交都跑）
2. **Ollama 那条路**：直接删掉，还是保留为 grader 不可用时的兜底？
   - 删掉：代码简单，行为单一
   - 保留：多一层保险，但两条路的结果会不一样，家长看到的「AI 建议」口径不统一
3. **送哪些点**：仍然只送漏判的点（省钱、和现状一致），还是把该题全部点都送？
   - 只送漏判：便宜；但 grader 看不到已经判对的点，可能影响它对上下文的理解
   - 全送：更接近 grader 的设计用法（它本来就是整题一起判），成本约翻倍

## 九、回退

- 改的是 `backend/server.js` 一个文件 + 一个环境变量。回退 = 还原文件 + 重启
  `com.kidreminder.server`。
- `AI_GRADING=0` 可以立刻关掉整条路径，不需要改代码。
- 现在已经写进 `ai_hit` 的历史数据是**建议值**，从不参与计分，不需要迁移。

---

## 附录：2026-10-13 的接口实测

从 Mac mini 上 `POST http://127.0.0.1:8790/api/v1/grade`，用一道两分的 OEQ 题：

```
请求: question{prompt, marks:2, section:"comprehension_oeq", passage} 
      markPoints[{seq:1, pointKind:"inference"}, {seq:2, pointKind:"inference"}]
      answer
响应: score 2 / maxScore 2 / scoreBasis "ai"
      points[0].aiVerdict "yes"  aiReason "学生写 \"she was afraid that her schoolmates
                                        would see her\"，表达了不想被学校的人认出来的意思。"
      points[1].aiVerdict "yes"  aiReason "学生写 \"she felt ashamed\"，表达了在湿巴刹帮忙
                                        感到难为情／丢脸的意思。"
```

服务健康信息（`GET /health`）：`ai.enabled = true`，`model = deepseek-chat`，`votes = 3`，
`kidReminder.connected = true`。
