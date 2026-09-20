# S3 Arm 2 fix2 — review FIX1-01..05 feedback ledger

来源评审：`tmp/mcp-play-support/review-s3-arm2-fix1.md`（sha256
`061f113fbc66baa946f80507bba94ff3b4c2e3e456f99fd0640cce6e0bb1fa7b`，verdict **DO_NOT_MERGE**，
P1 3 / P2 2）。分支 `feat/s3-arm2`（off `11ad091f`）。Role `[Dev]`（model A, rotation）。
**R3 PASS 与 R4 的 movement-postcondition 路径保持不动**；本轮只修 FIX1-01..05 与 R4 的兄弟分支。

**边界声明**：不引入运行期身份/摘要门禁；不新增协议/server 代码；`T_SKIRMISHER_VAULT` 字节级不变。

## 反馈台账

| finding | 处置 | 证据 |
| --- | --- | --- |
| S3-ARM2-FIX1-01（P1，类 C）plan/annotation/landing 的判别合并未在任何成员读取前闭合：scalar annotation 抛 `ANNOTATION_SCALAR_ERROR`；`sequence` plan 的畸形 landing 跳过校验并落到一格回退（`permit nil 1 0`） | **fixed** | `AutoCombatGuard`：新增 `M.PLAN_LANDING_KINDS`（plan kind × 允许 landing kind 的闭合判别表）与 `M.ANNOTATION_KEYS`（annotation 闭合键集）。`landingCandidates` **先**校验 plan.kind → annotation（table 或 nil、未知键拒绝）→ landing（table、闭合键、kind 在 `M.LANDING_KINDS` 且被该 plan kind 允许），然后才读 `plan.x/plan.y`/`landing.center`。cross-kind 畸形 landing 一律 `landing_envelope_unavailable`（unknown），**从不**变成一格度量集、**从不**抛出。`fromLanding` 支持确定性的 `{x,y}` 与 `{center={x,y}}` 两种闭合并集。回归：`test_auto_combat_guard.lua`（scalar annotation pcall 不抛 + unknown；cross-kind 未知键 unknown；step×random 非法 kind-combo unknown） |
| S3-ARM2-FIX1-02（P1，类 B）raised 字段“传输对、值语义不对”：风险模型不查 `act_exclude`（引擎按 `type.act_exclude[a.uid]` 跳过）；`act_exclude=true` 时 guard permit 而引擎报错；live `friendlyfire=false` 不覆盖 manifest 静态默认 | **fixed** | 三重：(1) `M.exclusionOf(actExclude,actor)` 按 **uid** 建模（缺键 ⇒ nil ⇒ 不排除，与引擎一致），非 table ⇒ `'unknown'`；(2) `memberships` 对自身与每个 ally 咨询该 uid 排除，无法复现 ⇒ `friendlies='unknown'` fail-closed；(3) `build` 预检：非 table 且非 nil 的 raised `act_exclude` ⇒ 直接 `reject selffire_risk unknown act_exclude_not_a_table`（引擎必报错 ⇒ 类型化 unknown）；(4) 有效值派生：`effectiveRaised(flag,declared,curated)` —— 显式 live raised 值（且该字段非 dynamic input）**覆盖** curated 静态默认，`false` 作为 **VALUE** 保留，membership/risk 与引擎消费同源。复现（`tmp/s3-arm2-fix2/falsify-fix2.out`）：`ACT_EXCLUDE_UID_TRUE permit 0`、`ACT_EXCLUDE_TRUE reject unknown`、`LIVE_FRIENDLYFIRE_FALSE permit 0`。回归：guard 三条 |
| S3-ARM2-FIX1-03（P1，类 A）稀疏 `when.all`/`when.any` 先过 schema 再被 `ipairs` 截断，隐藏假条件被丢弃并 act | **fixed** | `PolicySchema.denseCount`（唯一验证计数）在 schema、evaluator、assistant 三处共用：`validateCondition` 对 `all`/`any` 先 dense 后 `1..count`；`M.validate` 对 `rules`/`sustains`/`targeting.tie_break` 同样先 dense（非整数键/洞/越界键拒绝）；`PolicyEvaluator.evalCondition`/`isSafety` 用同一 `Schema.denseCount`，非稠密 ⇒ **UNKNOWN**（不再截断成 TRUE）；`AssistantAdapter` 的 `all`/`any`、`talents`、`sustains` 与 `EffectManifest.verify`（catalog）的 `rules`/`sustains` 同规则。复现：`SPARSE_CONDITION_ARRAY schema=false code=invalid_all decision=pause`，`SPARSE_EVAL_DIRECT result=unknown`。回归：policy 5 条 + catalog 1 条 |
| S3-ARM2-FIX1-04（P2，类 D）兄弟安全交接仍 pause+stop 双递进 generation | **fixed** | `AutoCombat:stop`：同因 **paused→stopped** 折叠进已有暂停转换（不再 +1）；`AutoCombatService.nativeDeviation` 去掉额外的 `pause` 组合，只 `nativeDeviated` + 同因 `stop`（no-op）；同步 `sequence_deviation` 路径保留 `pause` 转换，service 的 `stop(step.reason)` 同因折叠。复现 delta：普通 low-HP `ORDINARY_SAFETY_GENERATION` 2⇒**1**、同步 `SYNC_SEQUENCE_GENERATION` 2⇒**1**、异步 `ASYNC_SEQUENCE_GENERATION` 2⇒**1**（`tmp/s3-arm2-fix2/generation-fix2.out`）。**有意保留的多递进**：无（每个外部可见转换恰好一次；`nativeDeviated(terminal=true)` 已在 R4 修复轮单次）。`AutoCombat.lua` 中其余 `generation=self.generation+1` 站点均为独立的 `start`/`resume`/`onOpportunity` 相位转换，不在同一交接内叠加。回归：service 三条精确 delta + 普通 handoff 单条 pause 事件 |
| S3-ARM2-FIX1-05（P2，类 E）`INFEASIBLE` 前提为假、VALIDATION 超额声明 | **fixed** | `EffectFootprint.native` 增加**闭合形状前置门** `M.supportsShape`（仅 hit/ball/beam/bolt/cone/widebeam；`wall`/`triangle` 明确 nil，不再依赖 `Target:getType` 的子串匹配与“恰好未命中”的偶然行为）。**真实 wall 探针**（`movement-composition` 场景）：从真实加载的 `p.talents_def` 里用**真实 target builder**（Ice Wall `T_ICE_WALL` / Materialize Barrier `T_MATERIALIZE_BARRIER`）取真实 raised spec（`type='wall'`, `halflength≠nil`），断言 `EffectFootprint.native(...)==nil`；再用 test-only manifest admission/mutation（同 `mismatch_service` 半径变异的既有手法）把 wall 形状组件挂到生产 guard，断言 `reject selffire_risk unknown native_failed`（**绝不** permit/zero-risk）。信号 `mc_wall_expansion_unknown`。断言 `VALIDATION.md` 撤回“无真实天赋产生 wall”的可行性前提，并改写 fix1/fix2 状态 |

**未修项**：无。`triangle` 仍无真实天赋（评审亦未找到），故 `supportsShape` 对其一并 fail-closed，但无独立原生行。

## 不变量核对

- `T_SKIRMISHER_VAULT` 未触碰（`git diff` 无该标识符变更；V-U6 字节等价检查仍在套件内）。
- 无新协议代码：`git diff 11ad091..HEAD -- server protocol docs/tome-mcp-api-fields.md` 为空。
- 到达序 k→`plan[k]`、S2 presence+exactly-one、读策略、预算、`native_pending`、lease、dry-run、
  确定性 tie-break 全部保持；未新增插件级策略限制；未新增身份/摘要/闭包门禁。
- `landing='random'` 仍被策略作者通过 `accept.landing` 决定（插件不拒绝），只标注不确定性。
