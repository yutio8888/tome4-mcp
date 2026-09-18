# ToME MCP 0.9.0 — Anorithil 回归轮（D-1 P1 活锁 + D-2/D-3/D-4）

日期：2026-09-18。Branch `fix/emergency-deny-livelock`，off `main@3fe98ed`。Role `[Dev]`。merge=no。

来源实机报告：`/workspace/t-engine4/tmp/mcp-play-support/agent-ham-anor-reg-01-report.md`
sha256 `7efc9512567671c61b9a1536ae00cdfa67fd29ee0e6cbc4e5f722e8073e4b21d`。
PR #18/#19/#20 合并后**无 P0 回归**（68/68 native ok、0 timeout/abort、Moonlight Ray
原生目标请求均即时结算），但发现下列缺陷。

## 根因与修复

### D-1（P1）— emergency 原宏拒绝后的“暂停活锁”

**根因**：`PolicyEvaluator.evaluate` 在 `emergency_only` 层（低于 `min_hp_pct` 时）一旦没有
emergency 规则命中，就返回 `pause no_emergency_action`。当 emergency 规则**命中但被原生拒绝**
（治疗冷却中）时，控制器把该规则 `deny` 后循环继续，但 evaluator 仍在下一次迭代把同一层判为
“无 emergency 动作”并暂停。由于玩家满能量且未行动，ToME 不推进世界 tick（原生语义），治疗的
10 回合冷却**永不衰减**；之后每次 `start` 立即重演 `denied → paused`，`acted` 冻结在 49。

**为什么这是插件完整性问题而非策略问题**：“命中且被原生拒绝”不等于“无可执行动作”；同一机会内
仍有 normal 规则（melee/barrier）可用。暂停会让世界停摆，属于插件无法正确执行（时间无法推进 ⇒
冷却无法恢复），符合 AGENTS 的 fail-closed 边界。

**修复**（`PolicyEvaluator.lua`）：
1. emergency 层内，若某条 emergency 规则在**本机会**被 `denied`，则继续评估其后的 normal 规则
   （同一机会、按 priority + id 确定性 tie-break）。fall-through 只是普通策略求值，**不是**插件级
   策略限制，也不禁止该动作。
2. 仅当确实没有任何可用规则时，reason 用**被拒动作的 typed 原因** `action_denied`（而非
   `no_emergency_action`）；没有任何 emergency 规则命中时仍保留 `no_emergency_action`。
3. 控制器 `AutoCombat:step` 已按冻结语义处理 `denied`（跳过本机会重提交，但允许下一规则），
   无需新增门禁。

**影响面**：`budget_exhausted` 语义不变（仍先于层评估）；`emergency` 仍只是调度标签。

> **R-1 fix2 更新（2026-09-18）**：上句已被
> [docs/tome-mcp-0.9.0-anor-reg-01-fix2-feedback.md](tome-mcp-0.9.0-anor-reg-01-fix2-feedback.md)
> 取代：`max_actions_per_tick` 改为计量**产生原生动作的提交**，settled no-energy 拒绝不消耗预算，
> limit=1 同机会 fall-through 照常；`budget_exhausted` 只在完成 max 次有效动作后触发；refusal
> 终点与规则循环耗尽（无有效动作时）改为 stop 交接，不再持有 lease 冻结世界。

### D-2（P2，N1/P3-2 follow-through）— auto denied 事件丢结构化详情

命令路径 `Actions.execute` 对自身冷却中的 `use_talent` 原生拒绝返回
`missing={kind='cooldown',talent,remaining,required=0}` + `hint` + `native_message`，但 auto 的
`denied` 事件只带 `{kind,reason,rule,generation}`。

**修复**：
- `Runtime.mapAutoCombatOutcome`（生产映射）透传 `missing`/`hint`/`native_message`（有界、
  类型守卫）。
- `AutoCombat:deny` 把上述字段（以及适用时的 `landing`）放入 notify 事件。
- `AutoCombatService.start` 的 notify 回调把它们写入 policy log。
- `PolicyLog.add` 新增 `missing`/`hint`/`native_message` 的有界投影（显式字段白名单；
  `landing` 加 `type=='string'` 守卫，即评审 P3-c）。

### D-3（P2，策略/preset 层）— `new_enemy` 暂停风暴

单场 Troll 群战触发 12 次 `new_enemy` 暂停（每只游荡怪进视野即暂停），角色罚站挨打。按插件
职责边界，"是否因新敌暂停"应是 preset/mode 默认值而非插件硬门禁。

**修复**：
- `PolicySchema` 新增校验过的 mode 字段 `on_new_enemy='pause'|'continue'`（默认保守 `pause`）。
- `PolicyEvaluator.newEnemyMode` 解析该字段；legacy `safety.pause_on_new_enemy=false` 映射为
  `continue`。
- `AutoCombat:checkEnemies(mode)`：`continue` 就地刷新已知敌集合并继续同一机会行动；`pause`
  保持旧语义。
- `PolicyPresets.anorithil_p1a` 设为 `mode.on_new_enemy='continue'`，并令
  `safety.pause_on_new_enemy=false` 保持一致。
- `PolicyEditorModel` 以 mode 字段为准，编辑时同步 legacy boolean。
- `capabilities.auto_combat.modes.on_new_enemy` 暴露允许值。

### D-4（P3）— status 日志尾部/first_seq 不一致

`status.log` 报 `count/first_seq/last_seq` 描述**整个 ring**（94/1/94），但 `log.events` 只返回被
请求 limit 界定的尾部窗口（64 条），客户端据此无法判断实际返回范围（报告 §D-4）。

**修复**：`PolicyLog.status(log, entries)` 增加 `window={count,first_seq,last_seq}` 描述**实际返回的
窗口**，并加 `semantics` 说明 ring 字段与 window 字段的区别。`status`/`log`/`replay` 均传入实际
返回的 entries。早期条目通过 `tome.policy` `replay`（`after_seq` 游标分页）读取。

## 验收

| ID | 结果 | 证据 |
| --- | --- | --- |
| D-1 | **PASS** | 单测 `test_auto_combat_policy.lua`（fall-through/`action_denied`）、`test_auto_combat_controller.lua`（无停摆、CD 恢复后再次使用）、`test_auto_combat_service.lua`（端到端 no pause loop）；原生探针 `critical:fallthrough`/`heal-recovered`/`action-denied`（真实 `native_rejected` + 生产映射 cd detail） |
| D-2 | **PASS** | 单测 `test_auto_combat_execution.lua`（生产映射）、`test_auto_combat_catalog.lua`（PolicyLog 有界/类型守卫）、`test_auto_combat_controller.lua` + `test_auto_combat_service.lua`（denied 事件带 `missing`/`native_message`/`hint`）；原生探针 `critical:denied-detail` |
| D-3 | **PASS** | `test_auto_combat_policy.lua`（mode 校验 + legacy 布尔映射）、`test_auto_combat_controller.lua`（continue 不暂停且刷新敌集）、`test_auto_combat_io.lua`（anorithil preset 非停摆）、`test_auto_combat_editor_model.lua`（编辑同步） |
| D-4 | **PASS** | `test_auto_combat_service.lua`（ring extent + window 一致性，`first_seq==63`/`90`） |
| Whole | **PASS** | Lua 41/41；Python 39 OK；三个 `--check` 退 0；auto-combat 探针 source `anor-live-src-05` 与 dist `anor-live-dist-01` 各 **126/126**；原生验收 source `anor-live-accept-src-01` 与 dist `anor-live-accept-dist-01` 各 **101/101**；不变量（预算、native_pending 不重提交、手动收回租约、dry-run、确定性 tie-break、P0 结算）由上述套件覆盖并通过 |

## before/after 原生或单元复现（D-1）

同一 evaluator 场景（`heal` 命中但 `denied`，6 敌贴脸、`melee` 可用，`emergency_only` 层）：

- **修复前**（`main@3fe98ed` 的 `overload/`，脚本 `tmp/anor-livelock-evidence/prefix/repro.lua`）：
  `decision=pause reason=no_emergency_action rule=nil` → “LIVELOCK: the run parks and needs
  external input to advance time”。
- **修复后**（`tmp/anor-livelock-evidence/repro-fixed.lua`）：
  `decision=act reason=nil rule=melee fallback=true` → “FALLTHROUGH: an applicable rule acts,
  so the run keeps advancing ticks”。

## 原始证据（tmp/ 已 git-ignore；提交仅摘要 + sha256）

见 `docs/tome-mcp-0.9.0-anor-reg-01-todo.md` 的“证据”节与 `VALIDATION.md` 本轮条目。
