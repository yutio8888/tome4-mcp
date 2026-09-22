# 执行模型表现账本（execute→review loop 统计）

状态：**现行记录**。每次"执行（Dev）→ 审阅（Review）"闭环结束后，追加一行；按**执行 model**归类，
统计通过率与 issue 数量。审阅 model 另行记录（不属于本账本的"执行 model"维度）。

## 记账口径（冻结）
- **一个 loop** = 一次 `[Dev]` 交付 + 一次独立 `[Review]` 裁决（不含 dispatcher 自查）。
- **执行 model** = 该 loop 中 `[Dev]` 代理使用的 provider/model/thinking。
- **通过（PASS）** = 该 loop 的最终 Review 裁决为 `merge`（无阻塞项）。`merge with follow-ups` 记为
  **PARTIAL**（不阻塞但未干净通过）；`do not merge` 记为 **FAIL**。
- **issue 数** = 该 loop 最终裁决中的 P0/P1/P2/P3 计数之和（`issues`），并分列严重度。
- 通过率 = PASS / 总 loop；同时给出"非 FAIL 率"（PASS+PARTIAL）。

## 固定执行模型与轮换（维护者指定）
| 代号 | provider / model | thinking | 备注 |
| --- | --- | --- | --- |
| **A** | `pi` / `commandcode/deepseek/deepseek-v4.1-flash` | high | **已实测通过**（需在 pi 的 `enabledModels` 中启用） |
| **B** | `pi` / `opencode-go/glm-5.3-flash` | high | **已实测通过**（B 是 **pi 的 `opencode-go` 供应商**模型，不是 paseo 的 `opencode` provider） |

## 角色分工（协调者定稿）
| 角色 | 模型 | 说明 |
| --- | --- | --- |
| **Dev / Test（执行）** | **A ↔ B 逐 loop 交替** | A=`commandcode/deepseek/deepseek-v4.1-flash`，B=`opencode-go/glm-5.3-flash` |
| **Review（复核）** | **固定 GPT-5.6 Sol（Codex）** | `pi` / **`openai-codex/gpt-5.6-sol`**，thinking high；**不再**用 A/B 做评审 |

轮换规则（**两条独立的交替序列，各自计数，互不牵连**）：
- **Dev 序列**：本轮 A → 下轮 B → 再下轮 A …
- **Test 序列**：本轮 A → 下轮 B → 再下轮 A …
- **Review 恒为 Sol**；每个新任务用**全新** Review agent（仅"复核上一轮自身发现"时可复用同一
  Review agent）。

**当前指针（2026-09-18）**：
- Dev 序列历史全部为 **A**（#1–#11、#15–#17、#19、#21、#22，以及进行中的 D-1 活锁修复）
  → **下一个 Dev loop 用 B**。
- Test 序列历史全部为 **B**（#18 Rush 实测、#20 Rush 复测、#23 星月术士回归）
  → **下一个 Test 用 A**。

## 上下文窗口与自动压缩（2026-09-18 定稿，已实测）
- 全局：`~/.pi/agent/settings.json` → `compaction={enabled:true,keepRecentTokens:20000}`（`reserveTokens`
  用默认 **16384**）。pi 的阈值公式为 `contextWindow − reserveTokens`。
- **A、B 的 600K**：在 `~/.pi/agent/models-store.json` 把 `opencode-go/deepseek-v4.1-flash` 与
  `opencode-go/glm-5.3-flash` 的 `contextWindow` 设为 **616384** → 阈值 = 616384 − 16384 =
  **600,000**，即**在 600K 触发自动压缩**。A 另补 `commandcode` 供应商条目（同一 `contextWindow`）。
- **Sol 保持其真实窗口 272,000**（Codex），阈值 ≈ 255.6K——**不可**套用 400K 预留（会产生负阈值）。
- 实测：`openai-codex/gpt-5.6-sol`、`commandcode/deepseek/deepseek-v4.1-flash`、
  `opencode-go/glm-5.3-flash` 均以 `--provider pi` 启动并正常应答。
已在 `~/.pi/agent/settings.json` 的 `enabledModels` 加入 `opencode-go/glm-5.3-flash`；两个模型均已用
paseo 试跑确认可启动并返回。
**启用点的实测命令**：A = `--provider pi --model commandcode/deepseek/deepseek-v4.1-flash --thinking high`；
B = `--provider pi --model opencode-go/glm-5.3-flash --thinking high`。

## Loop 记录（回填：全部为模型 A；B 尚未启用）
| # | 任务（分支/PR） | 执行 model | 审阅 model | 裁决 | P0 | P1 | P2 | P3 | issues |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | movement-first-tranche rev1 (PR #15) | A | gpt-5.6-sol | FAIL | 0 | 6 | 3 | 0 | 9 |
| 2 | movement-first-tranche rev2 | A | gpt-5.6-sol（复核自身） | FAIL | 0 | 3 | 3 | 0 | 6 |
| 3 | movement-first-tranche rev3 | A | gpt-5.6-sol（复核自身） | FAIL | 0 | 1 | 0 | 0 | 1 |
| 4 | movement-first-tranche rev4 | A | gpt-5.6-sol（复核自身） | **PASS** | 0 | 0 | 0 | 0 | 0 |
| 5 | movement-adapter-factory rev1 (PR #16) | A | gpt-5.6-sol（全新） | FAIL | 0 | 3 | 2 | 0 | 5 |
| 6 | movement-adapter-factory rev2 | A | 同 #5（复核自身） | FAIL | 0 | 2 | 1 | 0 | 3 |
| 7 | movement-adapter-factory rev3 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 8 | movement-adapter-factory rev4 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 9 | movement-adapter-factory rev5 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 10 | movement-adapter-factory rev6 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 11 | movement-adapter-factory rev7 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 0 | 0 | 1 |
| 12 | docs-antipattern rev1 (PR #17) | A′ (`deepseek-v4-flash`) | gpt-5.6-sol（全新） | FAIL | 0 | 2 | 1 | 0 | 3 |
| 13 | docs-antipattern rev2 | A′ | 同 #12（复核自身） | FAIL | 0 | 1 | 0 | 0 | 1 |
| 14 | docs-antipattern rev3 | A′ | 同 #12（复核自身） | **PASS** | 0 | 0 | 0 | 0 | 0 |
| 15 | movement-adapter-factory rev8 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 1 | 0 | 2 |
| 16 | movement-adapter-factory rev9 | A | 同 #5（复核自身） | FAIL | 0 | 1 | 2 | 0 | 3 |
| 17 | movement-adapter-factory rev10 | A | 同 #5（复核自身） | **PASS** | 0 | 0 | 0 | 0 | 0 |
| 18 | S1 Rush 实机测试（Test） | **B** | 无（测试任务） | FAIL（主指标 NOT_OBSERVED） | 1 | 0 | 2 | 1 | 4 |
| 19 | auto-combat 移动原生死锁 P0 修复 | A（Dev）/ **B**（Review） | 全新 Review（新任务） | **PASS**（merge with follow-ups） | 0 | 0 | 0 | 5 | 5 |
| 20 | P0 修复后 Rush 复测（Test） | **B** | 无（测试任务） | **PASS**（P0 关闭；新 P2 1 / P3 2） | 0 | 0 | 1 | 2 | 3 |
| 21 | P2-1 备选落点 + P3-2 冷却详情 | A（Dev）/ **B**（Review） | 全新 Review（新任务） | **PASS**（merge with follow-ups） | 0 | 0 | 0 | 3 | 3 |
| 22 | N2 测试运行器根 + N1 日志 landing | A（Dev）/ **B**（Review） | 全新 Review（新任务） | **PASS**（**merge**，无阻塞项） | 0 | 0 | 0 | 3 | 3 |
| 23 | 星月术士回归实机测试（Test） | **B** | 无（测试任务） | FAIL（无 P0 回归；新 P1 1 / P2 1 / P3 2） | 0 | 1 | 1 | 2 | 4 |
| 24 | anor-reg-01 修复 D-1..D-4 | A（Dev）/ **Sol**（Review） | 全新 Sol（新任务） | FAIL（**do_not_merge**） | 0 | 1 | 0 | 1 | 2 |
| 25 | anor-reg-01 fix2（R-1/R-2） | **B**（Dev）/ **Sol**（Review，复用复核自身） | 同 #24（复核自身发现） | **PASS**（merge with follow-ups） | 0 | 0 | 0 | 1 | 1 |
| 26 | anor fix2 定向回归（Test，协调者提前终止） | **A** | 无（测试任务） | **PASS**（D-1/R-1 核心通过；未覆盖项已声明） | 0 | 0 | 0 | 0 | 0 |
| 27 | P3 门禁清尾（#60-N2/#63-P3-b/-c/#64） | A→**B**（Dev）/ **Sol**（Review，复用复核自身） | 首轮全新 Sol；修正轮复用 | **PASS**（终审 **MERGE**，0 findings） | 0 | 0 | 0 | 2 | 2 |
| 28 | S2 有序 prompt-响应队列（实现） | A（Dev）/ **Sol**（Review，全新） | 全新 Sol（新任务） | FAIL（**do_not_merge**） | 0 | 2 | 4 | 1 | 7 |
| 29 | S2 rev2 修 REV-01..07 | **B**（Dev）/ **Sol**（Review，复用复核自身） | 同 #28（复核自身发现） | FAIL（**do_not_merge**） | 0 | 2 | 0 | 0 | 2 |
| 30 | S2 契约修订（Investigation B）+ 应用事故修复 | B（Investigation）/ — | — | BLOCKED→已修复（Dev A 正确拒绝实施） | 0 | 0 | 0 | 0 | 0 |
| 31 | S2 rev3 按修订契约实现（记录在 main 分支账本 c62c31e） | A（Dev）/ **Sol**（Review，复用复核自身） | 同 #29（复核自身发现） | FAIL（**do_not_merge**） | 0 | 1 | 2 | 0 | 3 |
| 32 | S2 rev4/rev5 收口（presence-explicit + 运行期 exactly-one + Vault 撤回） | **B**（Dev rev4）→ **A**（Dev rev5）/ **Sol**（Review，复用复核自身） | 同 #29/#31（复核自身发现） | **PASS**（终审 **MERGE**，0 findings） | 0 | 0 | 0 | 1 | 1 |
| 33 | S2 实机测试（Archmage / Phase Door 有效 TL5） | **A**（Test） | —（测试任务；前一候选 Sol 未参与） | FAIL（主目标 **PASS**；新 P1） | 0 | 1 | 0 | 0 | 1 |
| 34 | S2-FIX5 前置拒绝误报偏差修复 | **B**（Dev）/ **Sol**（Review，全新） | 全新 Sol（新任务） | FAIL（**do_not_merge**） | 0 | 1 | 0 | 0 | 1 |
| 35 | S2 rev7 零提示成功收紧（S2-FIX5-R1） | **A**（Dev）/ **Sol**（Review，全新） | 全新 Sol（新任务） | **PASS**（终审 **MERGE**，0 findings） | 0 | 0 | 0 | 0 | 0 |
| 36 | S2-FIX5/rev7 定向复测（V1-V5） | **B**（Test） | —（测试任务） | **PASS**（V1-V5 全通过；仅夹具 bug） | 0 | 0 | 0 | 0 | 0 |
| 37 | 不支持条目全量审计（Investigation A） | **A**（Investigation） | — | **PASS**（1 项可证过度保守 + 4 项错误理由 + 1 项 v1.6 违规） | 0 | 0 | 0 | 0 | 0 |
| 38 | R3/R4/R5 理由改写 + R7 移除 Progression 源身份门禁 | **B**（Dev）/ **Sol**（Review，全新） | 全新 Sol（新任务） | FAIL（**do_not_merge**；P1 假成功 + P2） | 0 | 1 | 1 | 0 | 2 |
| 39 | NEW-01/02（finish/unload 后置复核 + 文档更正） | **A**（Dev）/ **Sol**（Review，全新） | 全新 Sol（新任务） | FAIL（**do_not_merge**；2 P1） | 0 | 2 | 0 | 0 | 2 |
| 40 | NEW-03/04（结算期重校验 + 类型安全） | **B**（Dev）/ **Sol**（Review，全新） | 全新 Sol（新任务） | **PASS**（merge with follow-ups） | 0 | 0 | 1 | 0 | 1 |

> A′ 说明：#12/#13 的 Dev 实际以 `commandcode/deepseek/deepseek-v4-flash`（非 v4.1）启动，属**偏离**；
> 后续统一使用固定 A。

## 汇总（截至当前）
- Loop 总数：**40**（含 1 个未进入评审的 BLOCKED 轮；#31 记录于 main 分支账本 c62c31e）。
- **PASS 15**、**FAIL 24**、BLOCKED 1、PARTIAL 0 → **通过率 15/38 = 39.5%**。
- **#38–#40（Progression 审计链，Dev B→A→B，三轮全新 Sol）**：为移除 **v1.6 违规的
  `debug.getinfo` 源身份门禁**（7 处）而做，但移除后**暴露了"在错误时点判定成功"这一类漏洞的三个变体**，
  **每轮都由独立 Sol 反证抓出新的一处**（单测与自查均未发现）：
  ① **NEW-01（P1）**：在 `dialog.finish`（**会跑活 `on_levelup_close` 回调**）**之前**判定成功 → 回调可在
  finish 中撤销花费而仍返回 `progression_applied`；
  ② **NEW-03（P1）**：改成"finish 后 + unload 后**同步**复核"仍不够——回调可用**原生自己的**
  `game:onTickEnd(...)`（**官方技能就这么做**，`psionic/solipsism.lua:48`）把撤销**排队**，两道同步检查
  都过，随后排队的回调才恢复原状；
  ③ **修复（通过）**：变更被接受时在 command 上记录期望后置条件，`Runtime` 在**原生 tick-end 队列 drain
  完成、`phase=='ready'`、且在任何 `finish(...'completed')` 之前**重跑校验；不一致 → `failed`/`uncertain`/
  `native_progression_mismatch` + quarantine；不可校验 → `progression_execution_error`+`uncertain`。
  **NEW-04**（`learn_category` 先算术后验类型、after-unload 复核在 `pcall` 之外 → 字符串 mastery 逃逸为
  未捕获错误）同轮修复。
  ④ **遗留 P2（NEW-05，已按评审收窄）**：诚实保证 = "**调用完成且当前（递归链式）`onTickEnd` 队列为空后的
  第一个 ready 决策边界**上状态一致"；**不是**对更晚帧/回合（`registerTimer`、更晚 tick、不受管协程）调度的
  永久保证——那不属本插件调用所有权。已写入 `Runtime.lua` 注释与 TODO #67。
  **教训**：**"成功"必须在最终可观测状态上判定**；每把判定点后移，都要再问"**还有没有更晚的写入者**"。
- **#37（不支持条目全量审计，Investigation A）**：审计 `EffectManifest.UNSUPPORTED` 全部 11 条 + 表外能力型
  拒绝，结论（我已逐条独立核实）：
  ① **唯一可证的过度保守拒绝 = `T_BLINK_RUNE`**（理由 `stable_native_talent_id` 为**假前提**——六个
  `T_RUNE:_BLINK_1..6` 是同一份定义的克隆、行为同一；设计 `:594` 一直写"Supportable with the factory"；
  且 `Out of Phase` 为**自益**效果 → 既不需要 S2 也不需要 S3）。**修复 S 级**，已并入 S3 分支实施。
  ② `T_SHADOWSTEP`/`T_GIANT_LEAP`/`T_VAULT` **归 S3 正确**（main 上显示"不支持"只是 S3 未合并）。
  ③ **四条 typed 理由事实错误**（拒绝本身仍正当，但原因写错）：`MERGE`/`STONE` 称
  `signature_not_distinguishable` ——**不实**（两段 spec 差 `pass_terrain` presence，Stone 另差
  `friendlyblock=false`），真正阻塞是**多主体操作**（Merge 杀自己影子 `:51`、Stone `target:move :88`）；
  `CURSED_BOLT` 段数**有界且玩家已知**（上限 4），真正阻塞是**每轮 `rng.table` 随机主体**（`:242`；审计初稿误记为 `:246`，
  已在 loop-39 修正）；
  `WORMHOLE` 的 `distance>=2` **可用 S2 队列表达**且两段 cursor_type 可区分（`:144` vs `:152`），真正阻塞是
  **后续触发的陷阱对**（无施法者移动）。每项 **S 级**。
  ④ **更高用户可见影响（表外）**：`Progression.lua` 仍在 `learn_talent`/`spend` 路径上用
  **`debug.getinfo` 源身份审计**（`D.native`，7 处调用），而 `review-disposition.md:14-18` 已宣告
  **D11（运行期摘要+身份+闭包门禁）作废** → **真实的 v1.6 违规**，需独立评审，**M–L**。
  ⑤ 真正不可判定（保留）：Dimensional Step TL5（S4）、Merge/Stone（双主体）、Cursed Bolt（随机主体）、
  Wormhole（第三方触发陷阱）、Displacement Shield（延迟伤害转移，无位移，设计 `:601` 已置于工厂之外）。
- Issue 合计：**84**（P0 1 / P1 34 / P2 27 / P3 22）；平均每 loop 2.40。
- **#36（S2-FIX5/rev7 定向复测，model B）全部 PASS**：**V1** 旧 P1 零复现（未加 `cooldown_ready` 守卫 +
  PD 冷却中 `start` ⇒ `paused reason=unexpected_target_request` **= 0**，冷却拒绝表现为普通
  `denied/native_rejected` 且带 `missing={kind='cooldown',remaining=11}`，该窗口游戏日志**仅一行**冷却提示）；
  **V2** 全场 12 条策略事件每条带 `rule`，4 条 denied 全带 `detail`，**paused=0**、无任何无 detail 事件；
  **V3** 主目标仍 PASS（`target_sequence` 恰 2 条 `hit`→`ball`、两条 answer 不同、`native_result=ok`、
  落点在中心 ±1）；**V4** 视野外落点**未被拒**且观察到**显式 fizzle 分支**；**V5** 直方图 **0 unexpected**、
  `unexpected_target_request` 全场（含 A5）为 **0**——A5 反向验证表现为**计划期 typed 拒绝**
  （`target_plan_mismatch`），即**在提交前**就被挡住，比运行时偏差更早。
  **唯一问题在我方**：出生夹具引用了**不存在**的 `T_LIGHTNING_BOLT`（引擎报
  `ActorTalents.lua:553: Learning unknown talent`），导致出生期 `native_tick_error` 隔离，需 `abandon` 恢复；
  **已修**：改为真实 id `T_LIGHTNING`，并把非 PHASE_DOOR 的技能改为**可选容错**（未知/学习失败只跳过，
  **不得**中断出生）。
- **#33（S2 实机测试，model A）主目标 PASS**：Phase Door 有效 TL5 的自动路径 `target_sequence` 恰 2 条、
  `hit`→`ball`、**answers 不同**（施法者 (26,7) → 落点 (26,9)）、`native_result=ok`、实际位移至 (25,10)
  落在中心 ±1 内、**随机/视野外落点均未被拒绝**；红线 B1-B5/B7/B8 全清。**但发现新 P1**：合法策略下出现
  **10 条无 `detail` 的伪 `unexpected_target_request`**，可稳定归因到"未加 `cooldown_ready` 守卫的一次
  `start` 遇上原生入口冷却拒绝"（加守卫后归零；该窗口游戏日志只有一行冷却提示）。
- **#34（S2-FIX5，Dev B / 全新 Sol）do_not_merge**：Dev 先修正了我的根因判断——settle 记录**本就有**
  `expected/observed/skippable`，真正的无 detail 来源是 **controller 的同步偏差分支**（`self:record` 不
  notify，日志只收到 `pause()` 的裸 notify），**与实机原始形状吻合**；两端均修。但 Sol 发现
  **`raised` 门过宽**：它只区分"弹过/没弹过"，**未区分"前置拒绝"与"零提示成功返回"**，于是声明非
  optional 条目的描述符可**零提示返回 true 并被报成 `action_complete`**（策略值从未被消费）。附三行复现。
- **#35（S2 rev7，Dev A / 全新 Sol）MERGE，0 findings**：把豁免收窄为 `preflightRefusal = not raised and
  not value`——**零提示真值返回在非 optional 序列下必须报 typed 偏差**，零提示假值仍是普通
  `native_rejected`，一提示后中止仍偏差，尾部 optional 仍 `reduced=true`；**默认 fail-closed、无策展例外**
  （唯一消费者是 3 个 Phase Door 单元，闸门静态可读）。PR #24 合并 `e2f82dfb`；probe 177/177 src+dist。
- **基础设施（非 loop）**：低画质渲染档默认启用（`tests/native/runtime.py`，`main@a344f9b`）——单会话
  CPU **375% → 78%（约 −79%）**，分辨率**刻意保持 1920×1080**（ToME 的 FOV/可见格集由视口决定，改分辨率会
  破坏历史可比性）；`background_saves` **刻意不动**（关掉会让引擎 `savefilepipe` 报
  `cannot resume dead coroutine`，被 runner 计为 Lua 错误）；probe 173/173 → 现在 177/177 均通过。
- **#32 闭环（S2 交付，PR #23 合并 `e01776e6`）**：S2 经 **4 轮 Sol 评审 + 1 次契约修订 + 1 次应用事故**
  收敛。转折点：
  ① 几何分类器（`hit`/`bolt`=actor）**被证伪**——引擎把 `hit` 定义为"命中单个格"，Dimensional Step
  用 `hit` 表达**网格**、Phase Door 的 actor 提示也用 `hit` → 删除，改用**逐条目策展观测签名**；
  ② 第一版"签名记录不相等"仍被**重叠**（`{hit}` vs `{hit,nowarning}`）与 **nil/false** 绕过 →
  经协调者**普查 1.7.6 官方 259 文件**（仅 9 处多段 action，仅 Phase Door 可支持）改判为
  **presence-explicit 语义 + 运行期"恰好一条"**（取代构建期互斥证明）；
  ③ 又抓出 **`T_VAULT` 被误当纯移动准入**——实为"攻击+眩晕+移动"的**混合技能**，且 `then.target='self'`
  可令原生攻击打到玩家而守卫看不见 → **撤回**，归入 S3（`movement_effect_composition_required`）；
  ④ 另修：auto 交还 `respond` 的指纹/预算、成功应答**不可幂等重放**、"同 kind 乱序"探针实为**零匹配**、
  文档 "distinguishable by construction" 过度声称。
  **协调者自身 4 处错误（如实记录）**：Vault 技能 id 张冠李戴（把 Acrobatics 的单段 `T_SKIRMISHER_VAULT`
  误认作两段技能）、称"Vault 已在准入列表"（`T_VAULT` 其实**从未建模**）、技能名误写（实为
  `T_DWARVEN_HALF_EARTHEN_MISSILES`）、把**顺序可区分**与**效果可支持**混为一谈（Vault 归类错误）；
  前两项由 **Dev 主动纠正**（避免"把正常描述符改坏"与"漏建真正需要的技能"）。
- **#30（契约修订，Investigation=B）**：交付 `s2-contract-revision.md`（sha256 `cd41df23…`）——
  经引擎证据裁决**几何不是 actor/grid 的可靠判别器**（`hit`=单格、`setSpot` 全几何填 `target.entity`、
  Dimensional Step 用 `hit` 表达网格、Phase Door actor 提示用 `hit`），改采**逐条目策展观测签名** +
  **N≥2 签名两两不同**（构建期 `request_signature_ambiguous`）+ **异步交还**全链路契约。
  该轮暴露我的**应用事故**（脚本中途抛异常且未写盘，导致 C.4/C.5/C.7 静默缺失、§4.4 悬空引用），
  由 **Dev A 在开工前独立发现并拒绝实施**（正确判定，避免代码与规范自相矛盾），已由 `ed894fb`
  逐字补全并记录改进（逐块写盘 + 逐块校验）。
- **#29（S2 rev2，Dev B / Sol 复用复核）do_not_merge**：Sol 判定 **REV-02/03/04/06/07 PASS、S1 移动
  回归 PASS**，但 **REV-01 与 REV-05 仍 FAIL**，且两项都是**契约层面**而非单纯实现 bug：
  **S2-R2-01**：**光标几何不是 actor/grid 的可靠判别器**（引擎把 `hit` 定义为"命中单个格"，
  Dimensional Step 就用 `hit` 表达**网格**请求；`setSpot` 对任何几何都会填充 `target.entity`），
  因而**误拒合法组合、误放行其它组合**，且**同 kind 的连续请求被乱序时无法观测**却仍返回
  `action_complete`（与"任何乱序都不会收到错值"的规范声明矛盾）；**S2-R2-02**：**异步交还**未接入
  状态机——deviation 在 `native_pending` 提前返回之后才附加，controller 只见 `native_pending` 并进入
  `waiting_native`，`reapAutoInvocation` 丢弃 `root.sequence_deviation`，于是安全暂停路径/租约释放都
  走不到、规则可能被重提交；且 `deviate()` 在提示**仍然存活**时就设 `target_cancelled`，超时兜底因此
  跳过 `cancelTarget`，可能留下**无人拥有的原生目标 UI**。已派 **[Investigation]（模型 B）** 修订契约
  （几何不可靠 → 事后条件校验 / 策展签名 / 混合；异步交还的字段与调用点；真正 yield 的 source+dist 探针
  义务），再据此动实现。
- **#28（S2 首轮实现，Dev A / 全新 Sol 评审）do_not_merge**：Sol 抓到 **2 个 P1**——
  **S2-REV-01**：队列**盲序应答**（`resolveQueued` 只比对声明条目、从不分类**原生**请求的 kind/顺序），
  实测"声明 `actor,grid` 而原生先抛 grid 形状再抛 actor 形状"仍返回 `action_complete, deviation=nil`；
  **S2-REV-02**：`away`/`toward`/`preferred_distance` 选择器**不套用落点包络**，把随机落点报成
  deterministic 并**绕过 `accept.landing`**。另有 4 个 P2（`target_requests` 未按稠密数组校验、
  `request='none'` 可声明但不可执行、typed 偏差只取消提示且**仍持有租约**而未交接交互、
  原生探针 `sd_distinct_values` 只比较几何不比较**应答值**）与 1 个 P3（文档 checks 69→71 过期）。
  已按轮换派 **Dev B** 修复（Dev 序列 A→B）。
- **#27 闭环（Dev 先 A 后 B，Sol 首审 + 复用复核）**：四项 P3 门禁（#60-N2 文档同步、#63-P3-b 测试根、
  #63-P3-c landing 守卫回归、#64/RR-1 oldest-first replay 断言）全部关闭。Sol 首审**只放行 3 项**并按
  "文档不准确"**拦下 #60-N2**（DOC-V4-01 五个子点 + DOC-PROVENANCE-01），Dev B 逐条修正后 Sol **终审
  MERGE、0 findings**。PR #22 合并 `55d9ab33`；`dist` 保持字节一致 `536d5e14`（本批零生产改动）。
- **#26（Test，模型 A，协调者指示提前终止）PASS**：**D-1/R-1 核心通过**——limit=2 全流程
  （deny → 同一 tick 内 fall-through → CD 3→2→1→0 → heal 再次成功施放；tick/revision 持续增长；
  无 `budget_exhausted`/`no_emergency_action` 冻结）；**limit=1 边界也通过**（deny 与被拒后扣动作的
  melee 落在同 tick 4823/4833/4843，CD 7→6→5 正常衰减，无冻结）；D-2 结构化
  `missing={kind='cooldown',...}` 两档均逐条出现；D-4/R-2 的 `log` 与 `replay` 窗口
  `first_seq<=last_seq` 全 PASS；红线全 0、无 unexpected pause/stop。
  **未覆盖（提前终止，非缺陷，已声明）**：limit=1 下 CD 归零后再施放（角色在 CD=5 时死亡；同机制在
  limit=2 已观察）、limit=3 对照、D-3 的定向新敌 instrumentation（本轮群战 `new_enemy`=0 且持续行动）。
- **#25 闭环（轮换生效：Dev=B）**：Sol 的 R-1（limit=1 活锁）与 R-2（replay 窗口顺序）由**模型 B** 修复，
  Sol 复用复核 → **PASS（merge with follow-ups）**：limit=1 下被拒即 fall-through、CD 前进、仅拒绝型终局
  停/释放租约、对抗性拒绝上限 8、replay 2,3,4 报 window 2..4；仅 1 项 P3（缺 oldest-first 的已提交断言）。
  PR #21 合并 `7dfd6c85`；main 重建 dist。
- **#24 闭环（首个 Sol 评审）**：Dev A 交付 D-1..D-4，GPT-5.6 Sol（Codex）独立复核 → **do_not_merge**：
  **R-1 P1** —— `max_actions_per_tick=1`（schema 合法，且 assistant 导入默认 1）时，被原生拒绝的紧急动作
  在 deny 前已 `attempts+1`，下一次评估**先查预算**→ `paused budget_exhausted` 且**持有租约** → 世界冻结、
  CD 永不衰减 ⇒ **同一活锁换 reason**；**R-2 P3** —— `replay` 窗口 extent 反了（`first_seq > last_seq`）。
  Sol 明确指出这是"同机会 fallback / 每次原生尝试都计入上限 / 上限=1"之间的**真实契约张力**，必须显式解决
  而非只测 2/3。**已按轮换派模型 B 修复**（Dev 序列 A→B），评审仍为全新 Sol。
- **#23（模型 B 实机回归）**：**无 P0 回归**（68/68 原生 ok、0 `native_timeout`/`native_aborted`、
  Moonlight Ray 原生目标请求正常结算）——PR #18 在射线类技能上得到正向验证。新发现：
  **D-1 P1**（emergency 治疗被原生拒绝 → `no_emergency_action` 暂停 + 暂停期世界不推进 ⇒ CD 永不衰减
  的活锁，需人工解围并间接致死）、**D-2 P2**（auto `denied` 事件丢掉了命令路径已有的
  `missing={kind='cooldown',...}` 结构化详情）、**D-3 P2**（`new_enemy` 暂停风暴：单场群战 12 次暂停，
  罚站挨打；应做成 preset/mode 可配默认而非插件门禁）、**D-4 P3**（status 日志尾部/`first_seq` 不一致）。
  已派模型 A 修复（D-1 必修，D-2/D-3/D-4 一并）。
- **#22 闭环**：模型 A 修 **N2**（`tests/run.sh` 从脚本自身位置推导 addon 根 + 支持
  `TOME_MCP_ADDON_DIR` + 坏覆盖 fail-fast；旧实现上溯 4 层会**静默跑主检出测试**）与 **N1**
  （`movement_retry` 客户端可见日志携带 `landing`，允许集有界），模型 B 独立复核 → **verdict MERGE**
  （N1/N2 端到端 PASS、证伪干净；3 项 P3 均为环境/加固注记，已登记 TODO #63）。PR #20 合并 `923d0bc6`；
  main 重建 dist `24b99327`。
- **#21 闭环**：模型 A 修 P2-1（approach 被原生拒绝后选次优落点，never-resubmit 三层强制、
  受 `max_actions_per_tick` 约束、非确定性落点与 Rush `authoritative_target` 路径不变）+ P3-2
  （denied 冷却详情），模型 B 做**跨模型独立复核** → `merge with follow-ups`（P2-1/P3-2 PASS、
  证伪干净：无预算绕过/无 exclude 泄漏/无重复提交/无策略限制；3 项 P3 已登记 TODO #62，
  其中 **N2 为 `tests/run.sh` 在备用 worktree 会跑主检出测试的工具链缺陷**）。PR #19 合并
  `8c977429`；main 重建 dist `6d68fdfd`。
- **P0 线程关闭**：模型 B 实测 12/12 `T_RUSH` 经 auto 槽**即时原生结算**（`native_result=ok`、全部
  到达目标相邻），无 `waiting_native`/`settling` 卡死、无 CPU 空转、`native_timeout` 未触发；
  意外 pause/stop = 0。该复测另发现 1 个 P2（approach 被原生拒绝后无备选落点 → `no_available_action`）
  与 2 个 P3（已登记 TODO #61）。
- **#19 闭环**：模型 A 修 P0（#18 由模型 B 实测发现），模型 B 做**跨模型独立复核** →
  verdict `merge with follow-ups`（5/5 断言 PASS，5 项新问题全为 P3，已登记 TODO #60）；
  PR #18 合并 `eb706b7b`，main 重建 dist `2f7c15e4`。
- **模型 B 首次用于 loop #18**（S1 实机测试）：发现确定性 **P0**——auto_combat 槽执行 `T_RUSH`
  原生死锁（waiting_native/settling 永冻、~500% CPU、prompt 不浮出），手动槽同技能可完整结算；
  另 F3/F4 (P2) 与 F5 (P3)。
- 会话计数：模型 A 用于 loop #1–#11、#15–#17（另 #12–#14 为 A′ 偏离）；模型 B 用于 #18。
- 两个任务（docs-antipattern、movement-adapter-factory S1）均已在**第 3 个复审轮**收敛为全 PASS
  并合并（PR #17 `2b5a4cd`、PR #16 `bc3eea0`），无遗留 P0/P1/P2。
- 说明：loop #12–#14（docs 任务）的执行模型为 **A′**（`commandcode/deepseek/deepseek-v4-flash`，
  偏离固定 A）；固定轮换自**下一个独立 loop** 起。
- 说明：#1–#3、#5–#10 是**同一功能的连续迭代**（每次修复上轮 findings），因此"每 loop FAIL"反映的是
  **迭代收敛过程**，不是独立任务的成功率；后续应以**独立任务**为统计单位，并把"同一功能的
  修复轮次"合并为一组观察。

## 配置状态（已完成）
1. **A/B 串已确认并实测**（见上表"固定执行模型与轮换"）。
2. **600K + 自动压缩已配置**：`~/.pi/agent/settings.json` 的 `compaction.reserveTokens=400000`
   （1M − 400K = 600K 阈值）。
3. **轮换生效点**：从**下一个独立 loop** 起，按 A→B→A→B 派发执行代理。
   （备注：`~/.paseo/config.json` 的 `opencode` provider 启用与 B 无关，B 走 pi 的 `opencode-go`。）


## S1 合并后的收尾清单（维护者已同意）
1. **补 DOC-04**：`docs/tome-mcp-0.9.0-movement-s1-implementation.md` 只在
   `feat/movement-adapter-factory`；S1 合并后按文档修复口径（去掉运行期身份/摘要/闭包门控，
   说明"audited"=策展/可观测元数据）修正并提交。
2. **最终核验 `NativeCompatibility` 仅诊断**：grep 确认 `ActorCombat.computed`、`TalentQuery`、
   `Actions` 执行入口不再以 source-diff/identity/digest/closure 决定可用性；替换但可用→使用，
   不可用→typed unknown；执行侧仅保留控制/租约/序列化/pending/native-result 不变量。
3. **更新 `VALIDATION.md`**：记录 v1.6 原则在**代码与文档两侧**的落地——"不追求运行期入口=原生入口的
   严格审计"、"读取无纯度/RNG 门"、"无插件级策略门（限制属 preset 默认）"，并注明本条为现行验收口径。
4. **账本写入** S1 rev8 的最终 loop 结果（该 loop 仍是 A 任务的延续；下一个独立任务起用 B）。

## Loop: X″ 边界重构（refactor/xdoubleprime-bytes → main，合并 `5628fe0`）

| 阶段 | 角色 | 模型 |
| --- | --- | --- |
| rev1 → rev2 修复 | [Dev] | A `commandcode/deepseek/deepseek-v4.1-flash`（thinking high） |
| rev2 评审 | [Review] | **GPT-5.6 Sol** `openai-codex/gpt-5.6-sol`（high）→ DO_NOT_MERGE（2×P1+3×P2） |
| closure 实施（vault/重入/policy_id/clear/UTF-8/文档） | [Dev] | A（同上） |
| closure 评审（fresh） | [Review] | **Sol** → MERGE（P0–P2=0，2×P3） |
| P3 修复 ×2（文档） | [Dev] | A（同上） |
| P3 复核 ×2 | [Review] | **Sol**（复用，复核自身 finding）→ MERGE，最终 P0–P3=0 |
| 独立对抗验证（vault/重入/复现 L5 工件） | 协调者（本对话） | — |

**结果**：X″ 已合入 `main`（`5628fe0`），`dist` sha `1bd60e6b…`。
**序列事实**：本轮 [Dev] 使用模型 A。**下一独立 [Dev] loop 应使用模型 B**
（`opencode-go/glm-5.3-flash`）。[Test] 序列独立计数，最近一轮为 B（`18359eae`），
**下一独立 [Test] loop 应使用模型 A**。

### 重要教训（写入预防口径）
1. **"不传 `svc` 参数"不能阻止闭包共享 `svc`**——回调隔离必须靠**事务前后权威比对**，不能靠参数裁剪。
2. **"唯一表键不可伪造"≠"值不可达"**——`pairs` 仍可枚举；权威必须移出公共表（词法私有）。
3. **P1 计数不等于可无限收敛**：当新 P1 只能由**同进程 Lua**触发时，应停止对抗性加固，
   按 `AGENTS.md` 明确"不与其它 addon 对抗"并**如实收窄声明**（本轮即此决策）。
4. **工具链观察若无法保留复现，不得断言根因**；保留工件后，协调者的独立复现使证据从"未复现"升级为
   "已复现、micro-cause 仍为 hypothesis"。

## Loop: 两条准入 rebase + 合并（S3 arm2 已入 main）

| 阶段 | 角色 | 模型 |
| --- | --- | --- |
| rebase 两分支到 X″ main + 密度校验统一 | [Dev] | **B** `opencode-go/glm-5.3-flash`（high） |
| 独立评审（fresh Sol，含 native 补跑） | [Review] | **GPT-5.6 Sol** → arm2 DO_NOT_MERGE / aprime DO_NOT_MERGE（4×P2+3×P3） |
| 修复 7 项（含新增真机 Earthen/Dwarven 行） | [Dev] | B（同上） |
| 复核（同一 Sol，复核自身 finding） | [Review] | **Sol** → **arm2=MERGE**；aprime=DO_NOT_MERGE（仅 RA-07 P3 开放）+ RR-01/RR-02 |
| RR-01 修复（main 单写者）+ RA-07 defer + RR-02 更正 | 协调者 | — |
| **arm2 合并入 main** | — | merge `0033559` |

**结果**：`main` = `0033559`（含 S3 arm2 + RR-01 修复），dist `3966a68c…`。
合并后独立验证：Lua 全绿、生成器 3× rc=0、**native probe 206/206**、acceptance **101/101**。

**序列事实**：[Dev] 连续两轮使用模型 **B**（rebase + 修复 + A′ 并集）。
**下一独立 [Dev] loop 应回到模型 A**。

### 教训
1. **协调者的时序错误会产生假 finding**：我在 Dev rebase **之后**才提交 `97a69d8`，导致两分支被评审判为
   "仍带撤回前提"（RA-04）。**派发前应先冻结基线**，或在 rebase 后立即更新分支。
2. **"单一来源"声称需逐 sink 核实**：arm2 的 `Actions.normalizeSequence` 仍留有独立 `pairs` 密度循环
   （RA-01）——评审用"全仓库 grep"证伪，而非只看我抽查的 `PolicySchema.lua`。
3. **证据表述必须逐行核对**：我把 flake 说成"0 失败行"，实为 **3 行 Rush 失败**（RR-02）。
   "已知 flake"是**归因**，不是**观察**；未保留游戏日志时，根因应记 `NOT_OBSERVED`。

## Loop: A′ ⊔ S3-arm2 语义并集合并

| 阶段 | 角色 | 模型 |
| --- | --- | --- |
| 并集合并（38 冲突块 → 语义并集） | [Dev] | **B** `opencode-go/glm-5.3-flash`（high） |
| 独立评审（fresh Sol） | [Review] | **GPT-5.6 Sol** → **merge**，P0=P1=P3=0，**1×P2** |
| 补 close-Rush 拒绝行（P2 收尾） | [Dev] | B |

**结果**：`merge/r2-aprime` @ `bf9c6af`，dist `5b32c28a…`。Sol 逐项证伪：arm2 与 A′ 准入**均无丢弃/削弱**；
5 个 meet-point 全部 PASS；X″ 不变量完整；两套特性 native 行 source+dist **231/231**、acceptance **101/101**。

**唯一 P2（APRIME-MERGE-REV-01）**：`bf9c6af` 为修 Rush 成功行而锚定 caster，导致**"紧邻目标的 Rush 原生
拒绝"在当前 head 无主动断言行**——三份 pre-fix 失败会话是**特征化证据**，不是**可执行回归**。
`AGENTS.md` 边界清单 E 的同类问题：**未观测的行不得当作 PASS**。已派 Dev 补一条**确定性真机拒绝行**
（断言 typed `native_rejected` + 位置不变 + UI 收敛 + 单次提交 + 不重放），并要求它**自证该行可失败**。

**序列事实**：[Dev] 连续三轮使用模型 **B**。**下一独立 [Dev] loop 应回到模型 A**。

### 教训（写入预防口径）
4. **修测试以便通过时，必须保留它所覆盖的路径**：把 caster 挪开使成功路径稳定，就同时删除了"贴近"
   这一路径的覆盖。**替换断言前要问：被移除的覆盖由哪一行接管？**（此处答案是"没有"，故补行。）

## Loop: A′ 并集评审的收敛（3 轮，围绕同一测试行）

| 轮 | 发现 | 角色/模型 | 结果 |
| --- | --- | --- | --- |
| 1 | 覆盖缺口（我留的开放问题 + Sol P2） | Sol | `bf9c6af` 锚定 caster 后，"紧邻→momentum 拒绝"失去主动覆盖 |
| 2 | **该行因错误原因通过**（删清冷却仍 233/233） | Sol | 真 P2——正是它本应防止的假阳性 |
| 3 | `game.logPlayer` 在 `host.request` 抛错时不恢复 | Sol（并被我独立预测） | P2，probe-only 卫生 |
| 4 | 无条件恢复（pcall + 幂等守卫 + 先恢复再 re-raise） | [Dev] **B** | Sol 最终：**REV-01/REV-02 均 CLOSED，P0–P3=0，merge** |

**结果**：`main` = `09753d3`（含 X″ + S3 arm2 + A′），dist `5b32c28a…`。
合并后独立验证：Lua 全绿、生成器 3× rc=0、Python OK、**native probe 234/234**、acceptance **101/101**，
dist sha 与 A′ 分支一致（合并干净）。

**序列事实**：[Dev] 本阶段连续 **4 轮**使用模型 **B**。**下一独立 [Dev] loop 必须回到模型 A**。

### 教训
5. **"能通过"与"测的是那件事"是两回事**：新加的回归行在**删掉准备步骤**后仍 233/233 通过——它断言的是
   *形状*（rejected/native_rejected），不是*原因*。**加回归时要同时构造"错误原因证伪"**，否则行会静默
   退化为恒真。
6. **测试接缝（seam）也要满足恢复不变量**：临时替换全局函数（`game.logPlayer`）必须用 `pcall` 包裹并
   **无条件恢复**，否则异常路径会把插装泄漏到后续所有行。
7. **协调者的派发缺陷**：`paseo --cwd <worktree>` 被解析为 workspace 根 → 近期所有代理实际在主 worktree
   工作；且我误归档了仍在工作的 Sol（复用原则要求复核自身 finding 时复用同一代理）。**已记录**在
   `tmp/mcp-play-support/dispatch-cwd-quirk.md`。


## 2026-09-22：SYSREV 系统审核（只审查，不推进 Dev/Test 轮换）

用户明确指定 Codex 内置 subagent；本轮据此使用内置 fresh contexts，保留 Review 固定 **GPT-5.6 Sol / high** 的模型要求，未使用 pi 启动 Review。

| 身份 | 实际角色 / 模型 | 实际结果 |
| --- | --- | --- |
| `/root/protocol` | Review / `gpt-5.6-sol` / high | 平台内容检查中止，无报告，不计入覆盖；另派全新代理 |
| `/root/protocol2` | Review / `gpt-5.6-sol` / high | changes_required；原始 P1=1/P2=1/P3=2 |
| `/root/combat` | Review / `gpt-5.6-sol` / high | changes_required；原始 P1=3/P2=1/P3=0 |
| `/root/architecture` | Review / `gpt-5.6-sol` / high | changes_required；原始 P1=1/P2=5/P3=1 |
| Dev / Test | N/A：本轮没有产品实现或实机游玩代理 | 各自轮换计数不变；下一独立 Dev 仍按前文回到 A |

固定基线 `caefa9a94af85dabd73c0d7e74ef764081b1fb3e`，dist SHA256 `5b32c28ad639a652e6ab83fa3cf88a6badc1b49dbaf753e329f0937af77c75e2`。去重后 **13 项（P0=0/P1=5/P2=6/P3=2）**；边界 checker 两路严重度不同，综合采用架构 Review 的 P1 验证门禁级别，未把它描述为已证运行错误。

本轮重跑 Lua 43 脚本、Python 39 tests、三个生成器均通过；70-member source/dist/manifest 一致。受控模块复现发现测试覆盖外的契约/行为缺口，**native 本轮 NOT_OBSERVED**。这些结果不是跨模型比较实验，不能从发现数量推断模型优劣。

产物：[系统审核报告](tome-mcp-system-review-2026-09-22.md)、[修改方案](tome-mcp-remediation-plan-2026-09-22.md)。原始报告和证据保留在 `/workspace/t-engine4/tmp/mcp-system-review-20260922`，哈希见审核报告。此次仅新增文档和此记录，没有产品修复、打包、提交或合并。


## 2026-09-22：SYSFIX 首批开发已派发

用户要求启动subagent修复上轮报告，沿用其Codex内置代理选择。EXEC-01@1将本轮记为执行方式例外：内置不提供pi的A/B模型，因此不推进A/B轮换；原序列Dev上次B、下一A保持。

| 实际代理 | 角色 | 实际模型/思考 | 范围 | 当前状态 |
| --- | --- | --- | --- | --- |
| `/root/fix_core` | Dev（fresh） | `gpt-6-astra` / xhigh，内置继承 | SYS-04/10/11/12/13 | running，未验收 |
| `/root/fix_policy` | Dev（fresh） | `gpt-6-astra` / xhigh，内置继承 | SYS-01/02/03 + U-01取证 | running，未验收 |
| `/root/fix_tooling` | Dev（fresh） | `gpt-6-astra` / xhigh，内置继承 | SYS-05/06 | running，未验收 |

三位Dev均在独立worktree，以 `366b32b4b53f28c3ef6575290f5b290d358ebfb8` 为基线；共享文件单写者见简报。Test/Review尚未派发，不复用之前的Review进行实现。报告数量/模型优劣暂无任何结果，不预判通过。

### SYSFIX 集成与独立审核派发（继续）

三个Dev已交付PR #27/#28/#29，仍为ready_for_review；core/policy继续各自native夹具补充，身份不变。集成统一入口通过不等于验收。内置fresh Review创建两次因线程额度失败，按EXEC-02改用Paseo全新Codex会话，模型仍固定Sol/high。

| 实际代理 | 角色 / 模型 | 范围 / 当前状态 |
| --- | --- | --- |
| 137119c2-30bc-4f4d-9a4d-7762c9163a6f | fresh Review / codex gpt-5.6-sol / high | runtime、协议、持久化、文档；审核中 |
| de482ffb-434f-468a-8c18-1ff3997e90c5 | fresh Review / codex gpt-5.6-sol / high | tooling、manifest、候选证据；审核中 |

Test尚未派发；其独立序列上次B，下一A。以上不是跨模型对比实验，native首次执行夹具启动FAIL单独保留，不从单次故障推断模型优劣。

### SYSFIX 最终候选验证（2026-09-22）

候选源码 `084642634b1d92dfb5e2880f43998672469798ab`；包 `3a4e186b001971bdebfa9315a33dcac3ddd06c9abd7a1698c9af6caf03f413fb`。三位内置 Dev 已交付，最终 core4bc0bb2 / policydca36dc / tooling06f393f，仍须独立最终验收。Runtime Reviewer 已关闭四项源码修复，tooling Reviewer 已关闭两项 checker finding；原生/证据适用性仍在复核。

新鲜 `[Test]` 代理 `4231c485-6ce6-40c5-84c5-6a096b74edb3` 使用 **pi/commandcode/deepseek/deepseek-v4.1-flash / high**（Test 序列上次 B，本轮 A，下次 B）。会话 `sysfix-live-01` 仅验证固定包 cap1/cap3、公开边界拒绝和 draft clear，不作完整通关或跨模型实验。Dev A/B 计数仍不变（内置执行例外）。原生 probe 由协调者执行，不能记为此 Test 代理的实机发现。

Test 交付4/4 PASS；额外一次非必要手动wait发生于所有断言之后，保留为brief偏离，不计入策略动作。会话在报告创建时即回收，Test代理已归档；最终证据适用性仍由原独立 Review 裁决。

最终两位Sol/high独立Reviewer均ACCEPT：Runtime8个SYS项、evidence3个SYS项；全部本轮6个审核finding关闭。独立Test4/4证据获接受，额外事后wait仍记为非阻塞brief偏差。所有原生/测试会话已回收；固定验证与报告见validation/2026-09-22-system-fixes/acceptance.json。本轮不是可比较的模型实验，不据发现数或通过数评价模型优劣。
