你是资深架构评审。请对下面这份"AI 自动战斗逻辑如何与 MCP 插件结合"的方案做进一步分析、验证与细化。这是**评审+设计**任务：只读代码，不要修改 addon/游戏文件；可读文件、跑只读 grep/git。把结论写到 `/workspace/t-engine4/tmp/mcp-play-support/review-auto-combat.md`，最后回复 8–15 行摘要。

## 背景与代码位置
- MCP 插件：`/workspace/t-engine4/game/addons/tome-mcp-bridge`（0.9.0，协议 v4）。请求-响应、一次一个动作、等到回合边界；有控制租约与 `control_source`（`remote`/`battle_companion`/`manual`）以及 Battle Companion 的让权协议（见 `docs/battle-companion-mcp-control.md`、`Runtime.lua` 的 `companion()/localCombat()/control_source/battle_companion`）。
- 只读能力：`Observer.inspect(kind="actor"/"character")` 的 `computed` 块（有效属性/速度/暴击/穿透/命中/APR…，逐 getter 审计 fail-closed，见 `ActorCombat.lua`）；`LevelMap.lua` 的 `tome.map`（explored/frontier）；`TalentQuery.lua`（消耗/冷却/射程/afford/readiness）；`Actions.admit`/`Actions.validate`（动作白名单）。
- 多回合原生活动模板：`Runtime.lua` 的 `rest` 与 `auto_explore`（`native_rest`/`native_run`、`stopRun/stopRest`、`nativePhase` settling、`clearUnownedNativeActivity`、`NativeTasks`）。
- 现有自动技能插件：`/workspace/t-engine4/game/addons/tome-auto_talent_assistant`（2.3.9）。读 `ARCHITECTURE.md`、`hooks/load.lua`（`class:bindHook("Player:automaticTalents", ...)` 约 444 行、`useTalent(...)` 调用）、`overload/mod/dialogs/Assistant.lua`（约 10k 行，条件树/打分/目标过滤/定时器，状态在 `actor.Assistant`，对话框配置、随存档序列化，无 JSON/稳定 API）。
- 其它：`tome-battle-companion`、`tome-danger-alert-`（可为 `.teaa`）。

## 待评审方案（我的结论）
核心矛盾：MCP 是"每动作一次网络往返 + 等回合边界"，自动战斗需要"每回合内快速多决策"，因此**不能让 LLM 逐回合驱动**；应让 LLM **写策略（数据）**、原生侧**本地执行**。

- **B（推荐）**：新写轻量原生执行器 `AutoCombat`，挂 `Player:automaticTalents`（与 assistant 同钩子）；只读审计值 → 按策略决策 → 原生 `useTalent` 执行。策略是版本化纯数据：`sustains`、有序 `rules{when<白名单条件树>, then<动作>, priority}`、`targeting`、`safety`、`budget`。候选动作仍过 `Actions.admit`/`TalentQuery`/`canProject` 校验。仲裁复用 `control_source`（新增 `auto_combat`）：MCP `connect control` 抢占时执行器让权，执行器行动前也检查 bridge 租约。MCP 面：`tome.policy`(set/clear/dry_run)、`observe.auto_combat{enabled,policy_id,last_decisions,actions,paused_reason}`、`stop`。
- **A**：现状 MCP 逐动作驱动，保留用于 Boss/危险/手动接管。
- **C（不推荐）**：AI 直接写 Lua 插件（任意代码、不可审计）；仅开发沙箱 + `Compat` 审计。
- **D（折中）**：把 AI 策略翻译成 `actor.Assistant` 结构，复用其引擎（装备/休息/队友/复杂条件），但无稳定 schema、翻译脆弱，作 Phase 3。
- 分阶段：P1 策略 schema v1（sustains+少量伤害规则+治疗/护盾+逃跑+rest/auto_explore）、薄执行器、`tome.policy`+`dry_run`；P2 扩充谓词/选择器/AoE selffire 规避/决策回放；P3 适配 assistant。

## 请你重点分析/验证
1. **事实核对**：`Player:automaticTalents` 的触发时机/频率与调用上下文（是否在玩家回合、能否安全调用 `useTalent`、是否会被 MCP 的 `Tracker`/tick 边界干扰）；assistant 的执行方式与副作用；`control_source`/BC 让权协议的确切检查点；`auto_explore`/`rest` 生命周期能否作为执行器模板。
2. **模型取舍**：B 是否最优？该**复用 assistant 引擎**还是**新写薄执行器**？给出理由与工作量评估；D 的适配层可行性。
3. **策略 schema**：给出具体、可版本化的草案（字段、条件谓词白名单、目标选择器、动作、优先级/互斥、资源预算、失败处理），并说明如何表达：常驻 buff、单体/直线/AoE 选位与 **selffire 规避**（注意 Searing Light 无自伤、Shadow Blast/Starfall 用 `spellFriendlyFire()`）、治疗/护盾阈值、逃跑、rest、`auto_explore`、换层。
4. **校验与 dry-run**：如何在不执行的前提下用当前快照验证策略（条件求值、动作合法性、目标可得性），并给出诊断格式；如何避免"dry-run 执行了动态 getter/RNG"。
5. **仲裁与所有权**：执行器与 MCP 租约如何严格互斥；`control_source` 扩展；抢占/恢复/存档读档/断线的状态机；若同时装了 assistant/BC 如何避免双控制。
6. **安全/反作弊/审计**：数据 vs 代码的边界；执行器只调审计入口的做法是否足够；哪些原生函数必须禁止；如何防止策略越权（读隐藏信息、非法施法、刷资源）。
7. **决策日志与可观测**：日志该记什么（候选、条件求值、被拒原因、资源变化、命中结果），如何通过 MCP/`Journal`/事件回放；如何做回归与 A/B 调参。
8. **性能**：`automaticTalents` 内每回合规则评估的开销控制（缓存/早退/预算）。
9. **测试计划**：单元（策略求值/条件树）、原生 fixture 场景、与 MCP 的交接测试；最小验收集。
10. **风险与未决问题**：列出会推翻方案的因素、必须由人拍板的点、以及一个**最小可用 Phase 1** 的具体清单（文件、接口、测试）。

## 交付
写入 `/workspace/t-engine4/tmp/mcp-play-support/review-auto-combat.md`：
- 结论（B 是否成立/需修正）+ 关键依据（引用文件/行）。
- 逐条回答上面 1–10（有代码证据）。
- 策略 schema 草案（JSON 片段）。
- 执行器架构图（文字/mermaid）。
- 最小 Phase 1 清单（接口、文件、测试、验收）。
- 风险与开放问题。
最后回复 8–15 行摘要。
