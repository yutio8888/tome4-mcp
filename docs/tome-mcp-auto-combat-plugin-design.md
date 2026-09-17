# AI 与人共用的自动战斗策略插件方案（ToME 1.7.x / MCP Bridge 0.9.0）

状态：设计报告（v1.3 冻结；正文 §0–§16 即规范）。目标读者：插件开发者、MCP 集成方、希望用 AI 或手工调参的玩家。
关联：`docs/tome-mcp-architecture.md`、`docs/battle-companion-mcp-control.md`、
`docs/tome-mcp-0.9.0-level-map.md`，评审 `tmp/mcp-play-support/review-auto-combat.md`。

---

## 0. 一句话目标

做一个**纯数据的战斗策略插件**：同一份策略，**LLM 可通过 MCP 撰写/校验/调优**，
**人可以在游戏内 UI 或 JSON 文件里编辑**，由**原生侧逐回合本地执行**；
它**既能独立用于原版 ToME（无 MCP）**，也能在装有 MCP Bridge 时被观察、dry-run、接管与仲裁。

核心判断：**AI 写策略（数据），原生执行器本地跑战斗，MCP 负责观察/校验/仲裁/接管**。
不让 LLM 逐回合发动作（网络往返 + 回合边界不划算），也不让 AI 写任意 Lua（不可审计）。

### 0.1 产品契约（v1.6：策略忠实执行）
插件是数据策略的忠实执行器 + 玩家已知信息提供者 + 控制仲裁器，不是战术制定者：
```
启动 → 校验策略、能力与控制边界 → 按策略逐机会选择并提交一个原生动作
     → 记录原生结果/不确定性 → 在完整性边界或策略指定的停止条件暂停 → 控制权交还玩家
```
- move、撤退、拉开距离、传送、rest、auto_explore 与 change_level 均为普通策略动作；是否使用、何时使用以及接受何种可见度/危险/随机落点，由策略或命名 preset/mode 明示，插件不得另加战术门槛。
- P1a strict preset 默认只处理当前可见战斗：无可见敌人即结束，不探索、不追击未知区域，不含自动撤退、随机传送或换层规则；这些是该 preset 的默认值，不是插件全局能力边界。
- 插件仅在无法忠实执行时 fail closed：目标/目标请求无法解析，getter/builder/执行入口未经审计或发生 source drift，控制/lease/revision/场景边界失效，预算耗尽，原生拒绝，或无法判定原生动作是否完成。
- 随机落点、视野外坐标、未知通行性或未知危险属于策略信息，不等同于执行不可判定；dry-run/decision/log 必须如实标注，由策略的显式容忍度决定是否提交。不得为改善决策而读取玩家未知信息。
- 没有匹配动作时按策略的 on_unavailable/mode 处理；不得从规则失败中隐式生成等待、巡逻、探索、撤退或换层动作。

### 0.2 规范的效力（v1.2）
**本文件正文 §0–§16 即规范（normative）**；§17 仅为修订历史（non-normative）。
已决定的事项不再列入“需人拍板”；开发者应以正文条款为准，不能再参考旧版或摘要表述。

---

## 1. 目标与非目标

### 1.1 目标
- **G1 单一真相**：策略是一份有版本的严格 JSON；UI 编辑、文件导入、MCP `set` 都改同一份数据，能稳定往返。
- **G2 人机双易用**：AI 用 id/JSON；人用带友好名称的树/列表编辑器；两者互相可读、可 diff、可合并。
- **G3 本地执行**：原生插件在玩家回合以原生速度决策与施法，不依赖外部进程。
- **G4 可独立**：不装 MCP 也能用（自带编辑器、快捷键、预设、角色档案）。
- **G5 可接入 MCP**：装 MCP 时暴露 `tome.policy`/`tome.policy_log`、观察摘要与统一控制仲裁。
- **G6 安全可证**：只读玩家已知信息；只调已审计原生入口（**含动态 getter/builder**）；未知即保守；不跑任意策略代码。
- **G7 可验证可回放**：确定性决策（无 RNG 平局）、dry-run 诊断、有界决策日志。

### 1.2 非目标（v1）
- 不追求"任意职业/任意 mod/任意技能"全覆盖；用**声明式能力目录**逐项支持。
- 不做队友指挥、自动换装/工匠、召唤管理。`change_level` **是受支持的策略动作**（原生场景迁移后
  pause+reset+显式重启）；P1a `strict` preset 的内置规则不含它——那是 **preset 默认**，不是插件全局禁用。
- 不做在线学习/自适应；策略由人或 AI 显式编写。
- 不链接现有 `tome-auto_talent_assistant` 的运行态（见 §12）。
- 不替代 MCP 的逐动作精细控制（Boss/未知场景仍用 A 模式接管）。

---

## 2. 设计原则

1. **数据，不是代码**。策略只允许 JSON 标量/数组/对象；禁止函数名、字段路径、正则、Lua 表达式。
2. **三值信息 + 分层 fail-closed**。条件与信息结果为 `true/false/unknown`。执行完整性未知（控制、目标请求、
   审计/source pin、预算、原生完成状态）必须 fail closed；战术结果未知（视野、通行、危险、随机落点）必须
   如实报告并由策略显式接受条件求值；效果 footprint 无法计算时禁用该动作。
3. **单一真相 + 稳定往返**。UI 编辑与 JSON 导入导出使用同一 schema；规范化序列化（字段顺序固定、数值整型化）。
4. **一次一动作**。每回合（ready→pump）只执行一个耗能动作；instant 技能可在同一 pump 内继续，但受硬上限约束。
5. **只走原生入口**。执行只用原生 `useTalent`/`moveDir`/`restInit`/`autoExplore` 等；原生返回值是最终裁决。
6. **窄而显式的安全目录**。每个受支持技能有 version-pinned adapter，声明静态几何/目标选择/自伤语义/资源检查。
7. **中心仲裁**。`manual`/`remote`/`auto_combat`/`battle_companion` 四类 owner 互斥，带 owner epoch。
8. **人优先的易读性 + AI 优先的严格性**。显示名/说明来自同一份 label 目录；AI 只依赖稳定 id。
9. **冲突即拒绝**。检测到未适配的第三方自动战斗 addon 时拒绝启动，避免双控制。

---

## 3. 架构总览

两种部署形态共用同一内核：

- **独立形态**：只装 `tome-auto-combat`，编辑器 + 快捷键 + 角色档案 + 预设；仲裁器只有 `manual`/`auto_combat`。
- **MCP 形态**：同时装 `tome-mcp-bridge`，仲裁器增加 `remote`；新增 `tome.policy*` 工具与观察摘要。

```mermaid
flowchart LR
    subgraph Human[人类玩家]
      UI[游戏内策略编辑器\n简单模式 / 高级条件树]
      FILE[JSON 导入/导出]
    end
    subgraph AI[LLM / MCP client]
      MCP[tome.policy / policy_log / dry_run]
    end
    UI <--> STORE[(PolicyStore\n规范化 JSON + hash)]
    FILE <--> STORE
    MCP <--> STORE
    STORE --> SCHEMA[PolicySchema\n严格校验 + normalize + 迁移]
    SCHEMA --> EVAL[PolicyEvaluator\n三值条件 + 优先级]
    SNAP[PolicySnapshot\n玩家已知 + 审计 getter + 有界] --> EVAL
    EVAL --> CAT[CapabilityCatalog\n声明式技能/目标/自伤 adapter]
    CAT --> GUARD[执行守卫\nowner epoch / revision / refs / canProject]
    ARB[ControlArbiter\nmanual|remote|auto_combat|battle_companion] --> GUARD
    ARB --> READY[Player.act 返回→ready 通知]
    READY --> SNAP
    PUMP[Game display pump] --> EXEC[AutoCombat 控制器\n一次 onTickEnd 动作]
    EXEC --> EVAL
    GUARD --> NATIVE[原生 useTalent / moveDir]
    NATIVE --> LOG[(PolicyLog 有界环形)]
    LOG --> MCP
    EXEC --> OBS[observe.auto_combat 摘要]
```

### 3.1 模块清单（Lua，放在 `overload/mod/auto_combat/`）
| 模块 | 职责 |
| --- | --- |
| `ControlArbiter.lua` | owner/epoch/lease、原子接管、监听器、reset；统一四类控制源 |
| `PolicyStore.lua` | 保存/加载策略（内存 + 角色档案 + 文件），规范化、hash、版本迁移 |
| `PolicySchema.lua` | 严格 schema 校验；默认值；limits 只可收紧 |
| `PolicySnapshot.lua` | **每个行动机会**取一次“玩家已知”快照；瞬发后重取；审计 getter；截断标记 |
| `PolicyEvaluator.lua` | 条件三值求值、优先级、目标选择、诊断 |
| `AutoCombatCatalog.lua` | 受支持技能的**声明式** adapter（几何/目标/自伤/前置） |
| `AutoCombat.lua` | 执行状态机：ready/pump/onTickEnd、instant 上限、pause/resume/stop |
| `PolicyLog.lua` | 有界决策环形日志 |
| `ui/PolicyEditor.lua` | 游戏内编辑器（简单模式 + 高级树） |
| `io/PolicyIO.lua` | JSON 导入导出、剪贴板、预设 |

### 3.2 MCP 侧改动
- `server/src/tome_mcp/server.py`：新增 `tome.policy`（get/set/validate/dry_run/start/pause/resume/clear/status）与分页 `tome.policy_log`。
- `Runtime.lua`：注册 `policy`/`policy_log` 分发；`control_source` 枚举加 `auto_combat`；`observe` 加 `auto_combat` 摘要；仲裁交接。
- 协议：v4 **增量能力门控**（`capabilities.auto_combat`）或明确升 v5 —— 需拍板（见 §15）。

---

## 4. 执行时机（关键修正）

评审确认：**`Player:automaticTalents` 不是 T-Engine 原生 hook**，而是 `tome-auto_talent_assistant`
自己在 `Actor:act` superload 里自造的钩子；原生同名**方法** `Player:automaticTalents()`
在 `Actor:act()` 内部、进入 `paused/ready` 边界**之前**执行。因此：

- **不要**依赖 assistant 的钩子；**不要**把重评估塞进原生 `automaticTalents()`（此时状态尚未稳定）。
- 复用 **Battle Companion 已验证的形态**：
  1. `Player:act` 包装在原生 `act()` 返回后发**ready 通知**（此时 `game.paused`、energy、无 tick-end 条件一致）；
  2. `Game` 显示循环只做 **pump**；
  3. pump 只排**一个** `game:onTickEnd` 动作，回调再比对 `session/owner epoch`；
  4. 执行前复查：owner epoch、revision、目标引用仍有效、`canProject`；
  5. instant 技能通过下一次 pump 继续，受每 tick 上限约束。
- **owner 互斥**：当 `auto_combat` 是 owner 时，不应存在远程 command；若存在视为仲裁错误并 pause（不让两个 tracker 叠加）。

### 4.1 执行契约（v1.2 冻结，必须实现）
- **启动/恢复先检查边界**：`start`/`resume` 若当前已处于可接受动作的 ready 边界，**直接安排 pump**；
  否则才等下一次 ready 通知。不得出现“按下启动却没有任何动作”。
- **动作机会与状态版本分离**：瞬发不消耗行动机会，但会改变资源/状态/技能可用性；同一行动机会内，
  每次瞬发完成后**重新取相关状态（新快照）**，不得继续用瞬发前的旧值。
- **瞬发预算按“连续执行”计**，不按显示帧重置；到顶后固定结果：停止继续瞬发、按规则处理后续耗能动作，
  或以明确原因暂停——不得静默重置。
- **失效标识（本地运行代际）**：owner 改变、暂停/恢复、替换策略、清空策略，都会推进运行代际
  （可与 owner epoch 合并）；所有排队决策回调执行前比对代际，过期即丢弃。
- **“清队列”只清插件尚未提交的决策**，不等同于撤销已进入原生的技能回调/协程；已提交的原生动作
  继续跟踪到可判定边界，暂停只停止后续自动提交。
- **动作结果 → 预算 → 下一状态（冻结）**：

  | 结果 | 预算 | 下一步 |
  | --- | --- | --- |
  | 执行前明确拒绝且未耗能（冷却/点数/射程） | 计入尝试 | 当前行动机会内**不得原样重试**；能确认状态未变且无原生待完成调用时可改试其他规则，否则暂停 |
  | `native_pending` | 计入尝试 | 内部等待，不再提交；到安全边界重新评估 |
  | 成功 | 计入尝试 | 重取状态；同一行动机会内继续（受预算） |
  | 异常/不可判定 | 计入尝试 | 停止并解释，不自动重试 |

  - **所有真实调用尝试都计入**有界预算（不只数成功动作）。
  - **瞬发预算以一个行动机会为单位**：显示帧、瞬发后重取快照都不重置；只有确认进入下一行动机会才重置。
    到顶后固定选一种：停止瞬发并处理后续耗能动作，或暂停并说明。
  - 危急状态下**预算耗尽不得成为跳过自保门禁、改放普通输出的理由**。

---

## 5. 策略格式（schema v1）

### 5.1 顶层结构
```json
{
  "schema": "tome-auto-combat/v1",
  "id": "anorithil-insane-basic",
  "name": "星月术士 · Insane 基础战斗",
  "class": "celestial/anorithil",
  "updated": "2026-09-16T00:00:00Z",
  "limits": { "max_actions_per_tick": 1, "max_instant_per_tick": 3, "max_consecutive_actions": 200 },
  "sustains": [ { "talent": "T_CHANT_OF_FORTRESS", "priority": 10, "min_resource_pct": 30 } ],
  "targeting": { "default": "nearest_hostile", "tie_break": ["distance", "hp", "uid"] },
  "safety": {
    "pause_on_new_enemy": true,
    "pause_on_unknown_safety": true,
    "flee_below_hp_pct": 25,
    "min_hp_pct": 35,
    "max_selffire_risk": 0
  },
  "rules": [ /* 见 5.3 */ ],
  "logging": { "ring_size": 256, "log_rejections": true }
}
```

### 5.2 条件谓词白名单（v1）

每条谓词都有稳定 id 与人类可读 label/说明（同一份 `catalog/labels` 供 UI 与文档使用）。

| id | 语义 | 取值 |
| --- | --- | --- |
| `always` | 恒真 | `true` |
| `hp_pct` | 自身生命百分比 | `cmp` + `value` |
| `resource_pct` | 指定资源百分比（positive/negative/mana…） | `resource`,`cmp`,`value` |
| `resource_value` | 指定资源绝对值 | 同上 |
| `cooldown_ready` | 技能已冷却 | `talent` |
| `talent_known` | 已学技能 | `talent` |
| `has_effect` | 自身/目标有某效果 | `effect`,`who` |
| `enemy_count` | 可见敌对数量 | `cmp`,`value` |
| `nearest_enemy_distance` | 最近敌人原生度量距离 | `cmp`,`value` |
| `enemy_in_melee` | 有敌人相邻 | `-` |
| `enemy_rank` / `enemy_type` | 最近/指定敌人的 rank/type | `cmp`/`eq` |
| `enemy_hp_pct` | 目标生命百分比 | `cmp`,`value` |
| `ally_count` | 可见友方/召唤数量 | `cmp`,`value` |
| `computed` | 有效计算属性（§5.6） | `field`（**有限枚举 id**，非任意路径）,`cmp`,`value` |
| `map_frontier` | 当前层未知前沿数 | `cmp`,`value` |
| `turn_parity` | 回合奇偶/间隔 | `mod`,`eq` |

**正式语法（冻结）**：谓词的值是“比较键 → 值”的对象，`cmp ∈ {lt,le,eq,ge,gt}`，例如
`{"hp_pct":{"lt":45}}`、`{"nearest_enemy_distance":{"le":7}}`；等值类谓词用其参数键，例如
`{"cooldown_ready":{"talent":"T_HEALING_LIGHT"}}`。所有示例必须通过同一个校验器。
布尔组合：`all`/`any`/`not`，三值逻辑。

### 5.3 规则与动作
```json
{ "id": "heal-low", "priority": 100,
  "when": { "all": [ { "hp_pct": { "lt": 45 } }, { "cooldown_ready": { "talent": "T_HEALING_LIGHT" } } ] },
  "then": { "action": "use_talent", "talent": "T_HEALING_LIGHT", "target": "self" } }
```

动作白名单由已实现 schema 与生成 catalog 共同给出：`use_talent`、`attack`、`move`、`wait`、
`use_item`、`rest`、`auto_explore`、`change_level`。未实现阶段必须按 capability 报告，不得把路线图动作伪报为可执行。

`target` 绑定 actor；`destination` 以纯数据 selector 表达移动请求，并携带显式的
visibility/passability/hazard/landing 接受条件。多次原生选目标用与版本固定 manifest 一致的有序 `target_plan`。
计划器的候选与 tie-break 必须确定；经审计原生动作自身的随机结果允许执行，并在 dry-run/decision/log 标注。
`change_level` 是普通显式动作。原生换层后执行器按场景边界暂停、清除旧 level/target/destination/lease 状态，
并要求在新场景显式重新启动；此生命周期不等于禁止策略选择换层。

目标 selector：`nearest_hostile`、`lowest_hp_hostile`、`highest_rank_hostile`、
`most_dangerous`（按 `computed`）、`cluster_center`（AoE：`min_targets`、`max_selffire`）、`self`、`position`。

**规则字段（v1.6）**：`id`、`priority`（越大越先）、`when`、`then`、可选 `emergency:true`、可选 `enabled`。
`emergency:true` 仅供 preset/mode 调度规则组，**不赋予或撤销动作能力**；撤退、拉开距离、随机传送和换层
均**不要求**该标记。不得靠规则名或优先级推断语义。

**目标绑定（冻结，v1.1 修正）**：每条规则按固定顺序执行，避免“条件检查 A、动作选到 B”：
```
生成候选目标（该 selector 的候选集）
→ 按该技能的目标类型/射程/投射条件过滤（射程合法性是执行器职责，不需玩家手填）
→ 对同一个候选求目标相关条件（target hp/effect/distance 必须指向同一目标）
→ 在合格候选中按 selector 稳定排序（tie_break: distance, hp, uid；不用 RNG）
→ 执行前复查（owner epoch / revision / 目标仍有效 / canProject）
```

**失败语义（三态，v1.2 冻结）**：
- **执行前不可用**（冷却/点数/射程）：按 `on_unavailable: skip|pause|wait`（默认 `skip`，安全类 `pause`）。
- **`native_pending`（正常未完成）**：桥接返回 `{ok=true, code='native_pending'}`（`Actions.lua:282`）；
  执行器进入**内部等待态**，不再提交动作，继续跟踪到可判定的安全边界后再重新评估。
  **这不是失败，也不要求玩家重启。**
- **需要玩家处理**（目标窗口/额外确认/原生交互）：明确暂停并交还交互，不自动确认。
- **异常/结果不可判定**（`uncertain`/`execution_error`）：停止继续执行、显示原因、不自动重试；
  已耗能时保守暂停。区分“**暂时不再提交动作**”与“**要求玩家重新启动**”两件事。

**常驻（sustains）是“维持期望状态”**：表达“希望该 sustain 开启”，执行器先查期望态（桥接 `set_sustain`
已有 `already_in_desired_state`），而不是“条件满足就再切换”；并规定常驻/救急优先级与重复失败重试上限。

### 5.4 策略模式、危急状态与风险信息（v1.6）
执行器不内置固定战术层。命名 preset/mode 必须把下列行为规范化为**显式数据**：无可见敌人时
`stop|evaluate_rules`；低于 `min_hp_pct`/`flee_below_hp_pct` 时 `pause|emergency_only|evaluate_rules`；
以及移动可见度、已知通行性、已知危险与随机落点的接受条件。
- **P1a strict preset 保留旧行为**：无可见敌人停止；低生命进入 `emergency_only` 或暂停；无撤退、随机
  传送、探索或换层规则；目的地要求由该 preset 明示。其它 preset/mode 可选择不同值。
- `emergency:true` 只标记可被 `emergency_only` 调度的规则，**不是动作能力或安全授权**。普通规则可以
  撤退、拉开距离、传送或换层；策略对其后果负责。
- 插件报告 player-known 的 reachability/visibility/passability/hazard/landing 信息。视野外、随机或安全性
  未知的落点按**不确定性标注**，并由策略接受条件决定；不得据此读取隐藏状态。
- 移动与效果信息**合取求值**：两部分都必须可计算且都被策略接受。已知自伤/友伤风险由策略容忍度决定；
  风险 footprint 无法确定时仅禁用该动作。`max_selffire_risk` 的度量与内置 preset 默认必须单独冻结。
- owner/场景/lease/revision、未经审计入口或 getter/builder、source drift、预算、原生拒绝或动作完成状态
  不明属于**执行完整性边界**，策略不得放宽。
- `change_level` 成功或开始场景迁移后总是暂停并重置旧场景状态，要求显式重新启动。

#### 5.4.1 Wave 1 D5/D6 取代（v1.6）
D5 对 `change_level` 的移除以及 D6 无条件仅暂停的逃跑行为**被取代**。**重新接纳 `change_level`** 为
capability-backed policy action；原生场景迁移后 pause/reset 并要求 explicit restart。`flee_below_hp_pct`
行为由规范化 preset/mode 选择（`pause|emergency_only|evaluate_rules`）。P1a strict 展开为原
pause/no-change-level 行为，但执行器**不再全局施加**这两项限制。

### 5.5 简单模式 ↔ 高级模式（同一数据）
- **简单模式**：有序技能优先级列表 + 阈值滑杆（HP/资源/敌人距离），生成等价规则。
- **高级模式**：条件树（AND/OR/NOT + 谓词），直接编辑 `rules`。
- 两种模式编辑同一 `rules`；简单模式是高级模式的一个受限视图，**不产生第二份数据**。
- 每个谓词/动作/字段在 UI 显示人类可读 label（来自 `catalog/labels.zh_hans|en`），JSON 里只存 id。

### 5.6 `computed` 谓词引用（与只读接口一致）
策略可引用 `inspect(kind="actor")` 已暴露的有效计算值：`computed.crit.physical`、
`computed.resists.FIRE`、`computed.offense.resistance_penetration.FIRE`、`computed.defense.fatigue`、
`computed.stats.mag`、`computed.speeds.movement` 等。这些值来自**已审计的 getter**（§8）。

**字段是有限枚举，不是任意路径**（P2.5）：`computed` 是**数值比较** `{field, cmp, value}`，
`field` 必须属于固定枚举（`PolicySchema.COMPUTED_FIELDS`，即 `ActorCombat.computed` 暴露的
角色面板路径）；枚举外路径是 schema 错误。getter 被覆盖/缺失/报错时该字段为 `unknown`，
绝不猜测。`has_effect`（`who ∈ {self,target}`，target 为动作将绑定的同一目标）与
`ally_count` 同样来自有界的可见读取，数据不可得时为 `unknown`。

**Getter 安全判据（P2.5，玩家面板/悬浮可见）：** 一次读取是安全的，当且仅当
(a) 玩家可在角色面板或悬浮/提示框中看到该值，且 (b) 它来自**已审计的原生 getter/标量字段**，
在 getter 被覆盖/缺失/报错时 **fail-closed 为 `unknown`**。标量面板数据（属性、速度、暴击、力量、
命中/APR/伤害、防御/护甲/疲劳、豁免、抗性/穿透/亲和、视力、生命、等级/rank、效果列表、技能冷却/
消耗/射程等）安全。**读取不要求"无 RNG/无副作用"**：动态 getter（含 `getTalentTarget`/`t.target`/
`preUseTalent`/`desc` 等）与动态提示文本均**可读**，唯一红线是不得提交动作、不得暴露玩家未获知
信息（见 §8.3）。谓词仍优先使用可回放的标量面板 getter 以获得稳定诊断。

### 5.7 自伤（selffire）建模（重要）
- 只有技能**显式**声明 `selffire` 才是确定值；缺省的面积形状为 `unknown`。
- adapter 记录**实际伤害语义**，而不是只看目标光标形状：
  - `T_SEARING_LIGHT`：伤害是**单体 `hit`** + 地面光域 `addEffect(..., selffire=false, friendlyfire=false)`
    → **无自伤**；`{type="ball",radius=1}` 只是瞄准光标。
  - `T_SHADOW_BLAST` / `T_STARFALL`：`selffire=self:spellFriendlyFire()` → 运行时动态，保守按可自伤处理。
  - `T_SUN_FLARE` / `T_TWILIGHT_SURGE` / `T_MIND_BLAST`：`selffire=false`。
- `safety.max_selffire_risk` 默认 **0**：P1 不允许自动投概率风险；`cluster_center` 选位必须在
  `canProject` + adapter 语义下证明不会命中自身/友军，否则 skip 或 pause。

**v1.5 冻结（v2 效果清单，取代单形状字段）：** 自伤不再由单个 `shape`/`selffire` 字段描述。
每个技能由 `mod.auto_combat.EffectManifest`（schema `tome-auto-combat-adapters/v2`）给出
**独立组件**（cursor / instant / projectile / secondary / ground），每组件记录 `delivery`、
`shape`、`range`/`radius`、`center`、`duration`、`selffire`/`friendlyfire`/`player_selffire` 及
来源。守卫（`AutoCombatGuard`）只从这些规范组件推导风险；条件分支只由已审计标量读取
（`talent_level`/`attr`）解析，无法解析则保留保守并集。footprint 由 `EffectFootprint` 展开
（游戏内使用原生 `core.fov` 后端，已由原生探针对 `ActorProject:project` 逐格验证）。源文件
哈希/定义行由 `tools/generate_effect_manifest.py` 生成并由 `EffectManifestDrift` 校验；不匹配
返回 `adapter_source_drift`，绝不使用过期元数据。动态技能见 `EffectManifest.UNSUPPORTED`。

---

## 6. 人机双编辑

### 6.1 人类路径
- 快捷键打开编辑器（如 `Ctrl+A`），树/列表显示，实时校验。
- **预设**：按职业/难度内置（星月术士 Insane、狂战 Insane…），一键套用后微调。
- **导入/导出**：JSON 文件与剪贴板；按角色保存档案；可选全局档案。
- **审查 AI 提案**：AI `set` 后，UI 高亮变更行，玩家 accept/reject；也可"以当前为基线 diff"。
- 内置**决策日志查看器**（§10）：看"为什么这一回合这么做"。

### 6.2 AI 路径
- `tome.policy`：`validate`（只校验）、`dry_run`（对当前快照求值）、`set`（写入但不一定激活）、
  `start/pause/resume/clear/status`。
- `tome.policy_log`：分页读取决策与拒绝原因，形成"观察→改策略→再验证"的闭环。
- AI 只依赖稳定 id 与 schema；人类可读名称不进入 AI 逻辑。

### 6.3 往返与版本（v1.1 修正）
- **规范化序列化**：字段白名单、固定顺序、无注释；**只对本来要求整数的字段整数化**，不改合法小数语义；
  保证 `parse(serialize(p)) == p`。
- `schema` 版本 + **迁移器**（`v1→v2`）；未知字段拒绝（`additionalProperties=false`）。
- 策略 `hash`（内容哈希）用于日志与 UI diff。
- **版本三态（冻结）**：`draft`（编辑中）→ `approved`（人工确认）→ `running`（不可变，正在执行）。
  修改只能产生新 draft；apply 时取消旧决策并从新的安全边界继续。**`set` 不得在未获本地权限时直接激活**。
- **简单/高级共享同一 `rules`**：高级里超出简单模式表达能力的条件，切回简单模式时只能**保留/只读**，不得丢失。
- **角色持久化（P1 必交付）**：策略、预设选择与玩家参数随角色保存；**运行态不保存**；读档后为停止状态。

---

## 7. 校验与 dry-run

**两级校验**：
1. **Schema 级**：严格类型/上限/白名单；拒绝未知字段与非法值。返回 `policy_invalid` + 逐字段错误。
2. **规划级（dry_run）**：用**当前只读快照**对策略求值，不执行任何动作：
   - 每条规则 → `true/false/unknown`，被选中的动作/目标，拒绝原因（冷却/资源/射程/selffire/adapter 不支持）。
   - 允许调用审计过的动态 getter/builder（`getTalentTarget`/`t.target`/`preUseTalent` 等）：本项目**不要求读取无 RNG/无副作用**，
     唯一红线是不得提交动作、不得暴露玩家未获知信息（§8.3）；`tie_break` 仍用稳定排序以保证诊断可回放。
   - 产品语义是“**预览此刻会选什么**”，**不是**“证明该动作一定安全/一定成功”。
- 诊断格式：
```json
{ "policy_hash": "…", "schema": "tome-auto-combat/v1", "snapshot": { "revision": 1234, "level_instance_id": "level-3" },
  "selected": { "rule": "heal-low", "action": "use_talent", "talent": "T_HEALING_LIGHT", "target": "self" },
  "rules": [ { "id": "heal-low", "result": true }, { "id": "moonlight", "result": false, "reason": "cooldown_not_ready" } ],
  "unsupported": [ { "rule": "firebeam", "talent": "T_FIREBEAM", "reason": "no_adapter" } ] }
```

---

## 8. 安全、反作弊与审计

- **数据 only**：策略不含可执行内容；执行器是实现方，不是策略的一部分。
- **只读玩家已知**：快照只含玩家可见信息（可见敌人/自身/已知地图）；不读隐藏实体、未识别物品属性。
- **Getter 安全判据（P2.5，玩家面板/悬浮可见）**：一次读取安全 iff (a) 玩家可在角色面板或
  悬浮/提示框中看到该值，且 (b) 来自**已审计的原生 getter/标量字段**，被覆盖/缺失/报错时
  **fail-closed 为 `unknown`**（实现见 `ActorCombat.computed` + `ActorCombat.field`，谓词枚举见 §5.6）。
  动态 getter 与动态提示文本**可读**（不要求无 RNG/无副作用）；唯一红线是不得提交动作、不得
  暴露玩家未获知信息（见 §8.3）。谓词优先使用可回放的标量面板 getter 以获得稳定诊断。
- **审计 getter**：planner 使用的计算属性纳入 `NativeCompatibility` 的 digest/identity/closure（复用
  `ActorCombat` 的 fail-closed 思路）；被覆盖/缺失 → `unknown`。
- **能力目录**：每个受支持技能一个 version-pinned adapter，声明：
  - 静态几何（`range/radius/shape/target_type`）与 `direct_hit`；
  - 目标选择要求（如必须是 hostile/单体/AoE 最少目标数）；
  - **自伤语义**（显式/动态/无），必要时按运行时 `target_geometry` 复核；
  - 资源与前置只作**提示**；最终以原生 `useTalent` 返回为准。
- `Actions.admit`/`TalentQuery` 是 **advisory**，不能单独作为安全证明；执行前需 adapter + `canProject` + 原生返回。
- **冲突即拒绝**：检测到 `tome-auto_talent_assistant`（或其它已知自动战斗 addon）→ 拒绝启用自动，避免双控制。
- **原子接管**：任何 owner 变更（手动输入、MCP connect、场景切换）先停执行器并清 epoch，再交接。
- **原版 `automaticTalents` 也纳入排他**：owner 为 `remote`/`auto_combat` 时必须抑制原生自动施法
  （桥接已在 `superload/mod/class/Player.lua` 对 `hasControl` 做此事，本插件需同样处理）。
- **旁观连接不抢控制**。

### 8.1 `unknown` 的作用范围（v1.1 修正，不能一票否决）
| 未知/异常 | 规范行为 |
| --- | --- |
| 控制权、当前角色、场景边界、lease/revision、原生动作是否结束不明确 | **整个执行器暂停** |
| 必需目标/目标请求无法解析，或原生入口/getter/builder 未审计、source drift | **禁用该动作**；若已提交或影响唯一控制边界则暂停 |
| 某范围技能的友伤/效果 footprint 无法计算 | **禁用该动作**，不否定其它报告完整的动作 |
| 移动落点随机、视野外，或通行性/危险为 unknown | 保留 unknown 注解，**按策略显式接受条件求值**；不得读取隐藏状态来消除 unknown |
| 仅用于目标优化的属性不明确 | 跳过依赖它的规则，或用策略规定的简单 selector |
| 玩家学了一个策略未使用的未适配技能 | 显示“未支持”，**不阻止启动** |

三值逻辑要**尊重短路**：技能已明确在冷却，就不必因其伤害属性未知而暂停全部自动战斗。

### 8.2 保证的边界（v1.1 修正）
- **执行保证**（可强证明）：不越权执行、不重复提交、不使用失效目标、不读取禁止信息、不调用未支持的规划函数。
- **战斗策略目标**（不承诺）：尽量避免已知友伤、合理治疗、减少危险动作。
- 插件保证“**按受控规则执行**”，**不保证**“不会做出导致死亡的战术选择”。验收措辞必须区分这两类。

### 8.3 读取政策：动态 getter 允许（v1.4 冻结，替代此前"纯度"假设）
- 本项目**不要求**读取函数"无副作用/不消耗 RNG"。ToME4 本身没有严格的 RNG seed 系统，
  读值路径消耗随机数不影响正确性；把"无 RNG/无状态变更"当作读取门槛是**错误**的方向，
  此前多次因此过度保守（排除可用 getter、加"绊线"、拒绝动态文本），**本版正式废弃**。
- **唯一执行边界**是真正提交动作的原生入口（`useTalent`/`attack`/`use_item`/`rest`/
  `auto_explore`/`change_level` 等）。除此之外**审计过的原生动态方法均可调用**，例如
  `getTalentTarget`/`t.target`、`preUseTalent`、`getTalentRange`/`getTalentRadius`/
  `getTalentRadius`、`canProject`、`spellFriendlyFire`、`desc`/`info`、`getTalentRequires` 等。
- **"审计"只保证可定位与可信**：函数来自原生文件（源路径 + 摘要 + 身份 + 依赖闭包），
  被覆盖/缺失/报错时 fail-closed 为 `unknown`。它**不**意味着"纯函数"，也不要求证明无副作用。
- **读取的两条红线**（除此之外不加限制）：
  1. 不得提交动作（不得调用 `useTalent` 等执行入口）；
  2. 不得把玩家未获知的信息喂给 planner（隐藏实体、未识别物品属性、未探索地图）。
- **安全由执行前 adapter 门禁 + 原生返回保证**，而不是靠禁止读取；未知/不可审计时保守处理
  （见 §8.1），但不因"可能有副作用"而放弃读取。
- **明确废弃的过度保守假设**（未来不得再引入）：
  1. "读值必须无 RNG/无状态变更，否则排除或加 RNG/状态绊线"；
  2. "不得调用 `t.target`/`getTalentTarget` 等动态构建器来做执行前判定"；
  3. "动态提示文本一律不得读取"；
  4. "必须为每个 getter 单独建立纯函数证明"。

---

## 9. 仲裁与生命周期

### 9.1 `ControlArbiter`
- owner 枚举：`manual`、`remote`、`auto_combat`、`battle_companion`；每个 owner 持有 `epoch`。
- 规则：任一时刻一个 owner；接管是**原子**的（停旧、清队列、发监听、置新）。
- 所有排队动作在执行回调里**再次比较 owner epoch**，过期即丢弃。

### 9.2 生命周期
| 事件 | 行为 |
| --- | --- |
| `start` | 校验策略 → 置 owner=auto_combat → **若已 ready 直接安排 pump，否则等下一次 ready 通知**；推进运行代际 |
| `pause` | 停执行器、清**未提交**决策、推进运行代际、保留策略 |
| `resume` | 若已 ready 直接安排 pump；推进运行代际；strict 模式下确认当前已知新敌人集合 |
| 应用/清空策略 | 推进运行代际；`clear` 不删除已批准的快照 |
| `manual` 输入 | owner→manual，pause（可配置是否断开 MCP） |
| MCP `connect control` | 原子接管 → owner=remote |
| 场景切换/读档/存档 | pause + reset 快照；换层后需重新 start |
| 新可见敌人 | strict：暂停（与 Battle Companion 一致）；见下方恢复语义 |
| 死亡/终局 | 停止并记录 |
| 未知安全输入 | 按 §8.1 范围处理 |

**strict 模式的恢复语义（v1.2 冻结）**：`resume` 表示**确认当前已知的新敌人集合**；
之后又出现**未确认**的新敌人，仍会触发 strict 暂停。例如：启动时见 A；B 出现→暂停；
玩家恢复（确认 A、B）；随后 C 出现→仍暂停。同一敌人离开视野后又回来是否重算，用同一遭遇内的
**稳定引用（uid）**判定并在日志中写明。确认新敌人只解除这一项暂停原因，**不得**绕过低生命、
场景异常或未完成原生动作等其他守卫。

### 9.3 独立（无 MCP）形态
- 仲裁器只有 `manual`/`auto_combat`；无 `remote` owner。
- 快捷键 start/pause；编辑器与日志查看器照常可用。

---

## 10. 决策日志（追踪；确定性回放为可选项）

环形缓冲（默认 256 条），每条记录：
```json
{ "tick": 12345, "revision": 678, "policy_hash": "…", "level_instance_id": "level-3",
  "selected_rule": "moonlight", "action": "use_talent", "talent": "T_MOONLIGHT_RAY",
  "target": { "id": "…", "distance": 6 }, "rule_results": {"…": true},
  "rejections": [ { "rule": "shadow", "reason": "selffire_risk" } ],
  "resources_before": {"negative": 40}, "resources_after": {"negative": 30},
  "native_result": "completed", "pause_reason": null }
```
- 确定性：`tie_break` 用 `distance/hp/uid` 稳定排序，**不用 RNG**。
- 该日志是**决策追踪**：保存结果与拒绝原因。若要做**确定性回放**，还需额外保存输入、adapter 版本、
  策略运行态（`policy_hash`/schema/owner epoch/快照 revision）；否则只能称“追踪”而非“回放”。
- MCP 分页读取；人类在 UI 里查看；可导出用于回归对比。

---

## 11. MCP 接口

### 11.1 `tome.policy`
| 子命令 | 参数 | 说明 |
| --- | --- | --- |
| `get` | — | 返回 draft / approved / running 三个版本与各自 hash |
| `validate` | `policy` | 只做 schema 校验，不执行 |
| `dry_run` | `policy` | 对当前快照求值，返回 §7 诊断 |
| `set_draft` | `policy`, `expected_hash` | 写入草稿；`expected_hash` 不匹配当前 **draft** hash 则拒绝（`policy_conflict`） |
| `approve` | `expected_hash` | 认证 draft；CAS 对象是 **draft** hash；不匹配拒绝 |
| `activate` | `expected_hash` | 把 approved 提升为 running 并请求租约；CAS 对象是 **approved** hash |
| `deactivate` | — | 停止执行并清空 running（保留 draft/approved） |
| `clear` | — | 清空草稿；**不删除已批准版本** |
| `start`/`stop`/`pause`/`resume` | — | 控制执行器 |
| `status` | — | owner、lease、三个版本 hash、是否运行、最近决策摘要 |
| `log` | `limit` | 最新优先的有界决策事件 tail |
| `replay` | `after_seq`,`limit` | 旧→新分页的 §10 追踪 + run header |
| `presets`/`preset`/`export`/`import` | — | 预设与导入导出 |
| `import_assistant` | `document`/`config`,`store` | 仅生成（D7/P3）：助手导出→草稿+warnings；`store` 才写 draft |

> **名称冻结（D10）**：实现中的 `set_draft`/`approve`/`activate`/`deactivate`/`log`/`replay`/
> `presets`/`preset`/`export`/`import`/`import_assistant` 即为规范名称；`tome.policy_log` 是
> 最新优先的有界 tail，分页追踪是 `replay`。错误码以 `invalid_policy` 为准（非 `policy_invalid`）。

**版本与控制契约（v1.2 冻结）**：
- `get`/`status` 必须区分 draft/approved/running；**停止运行不让已批准版本消失**。
- UI 与 MCP 同时改同一策略时，提交必须携带 `expected_hash`；不匹配则拒绝，不做静默覆盖。
- AI 可直接 `activate`，但必须来自**本地明确授权**；未授权时只能写草稿。
- **“已认证”≠“此刻持有动作控制权”**：MCP 委派给 `auto_combat` 后，连接仍可 observe/pause，
  但要执行普通 `act` 必须先重新取得 `remote` 控制（唯一 owner）。

### 11.2 其它
- `tome.policy_log`（最新优先的有界 tail）；`tome.policy` `replay`（旧→新分页追踪）。
- `observe` 增加 `auto_combat:{enabled, policy_id, policy_hash, actions, paused_reason, last_decisions:[…]}`。
- `control_source` 枚举加 `auto_combat`。
- `capabilities.auto_combat`：schema 版本、支持谓词/动作/selector、adapter 列表、limits、executor 版本。
- 错误码（实现名，D10）：`invalid_policy`、`policy_conflict`、`control_conflict`、`control_not_held`、
  `invalid_argument`、`not_approved`、`not_activated`、`execution_not_available` 等；完整注册表见
  `protocol/v4/vectors/error-codes.json`。

---

## 12. 与现有插件的关系

- **`tome-auto_talent_assistant`**：不复用其运行态/引擎。它的 hook 自造、状态存 `actor.Assistant`、
  含 RNG 与换装/队友/休息等副作用、初始化埋在万行 UI 实现里，**不是稳定 ABI**。
  两者并装 = 双控制 → **拒绝启用自动**（与 Battle Companion 的做法一致）。
  Phase 3 可选做一个**固定版本 + 显式字段映射**的"只生成配置、不直接启用、人工确认"的适配器。
- **`tome-battle-companion`**：沿用其 ready/pump/`onTickEnd` 调度与"执行前检查控制权"的模板；
  同装时由仲裁器决定唯一 owner。
- **MCP Bridge**：提供观察（`inspect`/`tome.map`）、审计 getter、控制租约与仲裁；
  本插件的 `remote` owner 与 Bridge 的控制租约是同一条链。

---

## 13. 兼容与本地化

- **职业覆盖**：以 adapter 目录逐职业推进；未覆盖技能在 dry-run 中显式列出，不静默降级。
- **Mod**：modded talent 通过新增 adapter 支持；load order 变化导致身份审计失败 → fail-closed（不可用而非弱审计）。
- **本地化**：谓词/动作/字段的 `labels.zh_hans.lua`、`labels.en.lua`；JSON 只存 id。

---

## 14. 测试与验收

- **单元（Lua）**：`test_policy_schema`、`test_policy_evaluator`（三值逻辑）、`test_policy_purity`
  （无 RNG、无未审计 getter）、`test_control_arbiter`、`test_auto_combat_controller`、`test_auto_combat_catalog`。
- **原生 fixture**：常驻/治疗/普通攻击/单体/直线/AoE（含 selffire）/一步撤退/未知暂停/目标丢失/
  dialog/manual+remote 接管/save-load-death。
- **MCP 集成（Python）**：`tome.policy` schema 与错误映射、dry-run、分页日志、接管。
- **安全验收**：手动接管后无旧动作继续执行；原生失败但耗能时不误重试；弹出目标窗口时不提交第二个动作；
  读档后保留设置但不恢复自动战斗；无非法施法；无隐藏信息读取；**执行器级安全依赖未知必暂停，动作级未知按 §8.1**。
- **可用性验收（v1.2 含通过标准）**：

  | 指标 | 回答的问题 | 通过标准 |
  | --- | --- | --- |
  | 从套用预设到首次成功运行需要多少操作 | 上手是否方便 | **全程无需编辑 JSON**；≤ 5 步操作 |
  | 普通战斗中需要多少次人工重新启动 | 是否真的减少操作 | 固定样本中非预期暂停为 0 |
  | 每 100 次决策的非预期暂停次数及原因 | 保守策略是否过度打断 | 预期暂停有清单，其余为 0 |
  | 试点构筑常用技能的实际覆盖率 | 是否真正可用 | 试点构筑日常技能 100% 有 adapter |
  | 玩家能否从暂停提示直接知道如何继续 | 日志是否有实际价值 | 每类暂停提示自含恢复步骤 |

- **首轮原生验证场景（必须覆盖）**：启动时角色**已 ready**；瞬发后资源/状态改变（重新取快照）；动作排队后
  **暂停再恢复**；运行中应用新策略；技能进入 `native_pending`；低生命时自保技能不可用；
  已确认一名新敌人后又出现另一名未确认新敌人。这比加第二个职业更能检验底座。

---

## 15. 路线图与工作量（1 名熟悉 ToME/Lua/MCP 的工程师）

| 阶段 | 内容 | 估计 |
| --- | --- | --- |
| **P1a 首个可用闭环** | 模块骨架 + `tome.policy`/`dry_run`/status/日志；**简单编辑器（不写 JSON）+ 角色持久化 + 一个完整试点构筑**（治疗/护盾/资源恢复/稳定输出全流程可用）；常驻/普攻/一个静态单体/一个 beam/fixture 验证的 Searing·Shadow Blast·Starfall adapter | **3–5 周** |
| **P1b 原生活动** | 抽出通用 `NativeActivity`，纳入 `rest`/`auto_explore`；自动换层默认关闭 | +2–3 周 |
| **P2 调优** | 更多谓词/选择器、决策回放、A/B 调参、更多职业 adapter | +2–3 周 |
| **P3 适配** | 固定版本 assistant 配置适配器（只生成、人工确认） | 6–10 周起（持续维护） |

### 15.1 首版基线（冻结）
- **试点构筑**：半身人 / 星月术士（Halfling / Celestial-Anorithil）。
- **技能白名单**（仅这些进入 P1a 可提交 schema，每个都有 adapter）：`T_CHANT_OF_FORTRESS`、
  `T_HYMN_OF_SHADOWS`、`T_HEALING_LIGHT`、`T_BARRIER`、`T_TWILIGHT`、`T_MOONLIGHT_RAY`、
  `T_SEARING_LIGHT`、`T_ATTACK`（普攻）。
- **模式（P1a `strict` preset）**：`pause_on_new_enemy=true`；风险容忍度按 §5.4 的度量冻结；
  内置规则**不含**自动撤退、随机传送、rest/auto_explore/change_level。
- schema/catalog/capability 必须诚实区分“执行器已支持”与“该 preset 未使用”；preset 缺省**不得**被
  解释为插件全局禁用。未进入该 preset 的动作/选择器仍按 capability 报告。
- **协议**：v4 **增量能力门控**（`capabilities.auto_combat`）；后续语义无法兼容再升 v5。
- **`expected_hash` 指向唯一对象**：写 draft（`set_draft`）与 `approve` 比较 **draft** 当前 hash；
  `activate` 比较 **approved** 版本 hash；不匹配返回 `policy_conflict`。（实现与 UI 一致：
  approve 为 draft 的 CAS，activate 为 approved 的 CAS。）

P1a `strict` preset **不生成**这些规则：队友/装备/物品/召唤管理、rest、auto-explore、换层、assistant 翻译、在线学习；
其中 `rest`/`auto_explore`/`change_level` 是**执行器已支持**的动作，只是该 preset 未使用。

---

## 16. 首版基线（已定）与仍待确认

**已定（见 §15.1，不再需要拍板）**：试点构筑与技能白名单、strict 模式、`max_selffire_risk=0`、
无默认撤退、不含 rest/auto_explore/change_level、协议 v4 增量能力门控、`expected_hash` 对象。

**仍待确认（不阻塞 P1a 开工）**：
1. daily 模式的风险定义与 preset 默认（**默认仍为 strict**，作为 P1b 之后）。
2. manual 输入是 pause 还是断开 MCP transport（无论哪种，owner 必须先回 manual）。
3. `rest`/`auto_explore` 进入 P1b 的具体版本；自动换层是否永久 opt-in。

---

## 附录 A：完整示例策略（星月术士）

```json
{
  "schema": "tome-auto-combat/v1",
  "id": "anorithil-insane-basic",
  "name": "星月术士 · Insane 基础战斗",
  "class": "celestial/anorithil",
  "limits": { "max_actions_per_tick": 1, "max_instant_per_tick": 3 },
  "sustains": [
    { "talent": "T_CHANT_OF_FORTRESS", "priority": 20 },
    { "talent": "T_HYMN_OF_SHADOWS", "priority": 10 }
  ],
  "targeting": { "default": "nearest_hostile", "tie_break": ["distance", "hp", "uid"] },
  "safety": { "pause_on_new_enemy": true, "pause_on_unknown_safety": true,
              "flee_below_hp_pct": 22, "max_selffire_risk": 0 },
  "rules": [
    { "id": "heal", "priority": 100,
      "when": { "all": [ { "hp_pct": { "lt": 45 } }, { "cooldown_ready": { "talent": "T_HEALING_LIGHT" } } ] },
      "then": { "action": "use_talent", "talent": "T_HEALING_LIGHT", "target": "self" } },
    { "id": "barrier", "priority": 95,
      "when": { "all": [ { "hp_pct": { "lt": 60 } }, { "cooldown_ready": { "talent": "T_BARRIER" } } ] },
      "then": { "action": "use_talent", "talent": "T_BARRIER", "target": "self" } },
    { "id": "twilight", "priority": 90,
      "when": { "all": [ { "resource_pct": { "resource": "negative", "lt": 25 } },
                         { "cooldown_ready": { "talent": "T_TWILIGHT" } } ] },
      "then": { "action": "use_talent", "talent": "T_TWILIGHT", "target": "self" } },
    { "id": "moonlight", "priority": 70,
      "when": { "all": [ { "nearest_enemy_distance": { "le": 10 } },
                         { "cooldown_ready": { "talent": "T_MOONLIGHT_RAY" } } ] },
      "then": { "action": "use_talent", "talent": "T_MOONLIGHT_RAY", "target": "nearest_hostile" } },
    { "id": "searing", "priority": 60,
      "when": { "cooldown_ready": { "talent": "T_SEARING_LIGHT" } },
      "then": { "action": "use_talent", "talent": "T_SEARING_LIGHT", "target": "nearest_hostile" } },
    { "id": "attack", "priority": 10,
      "when": { "all": [ { "enemy_in_melee": true } ] },
      "then": { "action": "attack", "target": "nearest_hostile" } }
  ],
  "logging": { "ring_size": 256, "log_rejections": true }
}
```

## 附录 B：字段/谓词/动作目录（供 UI 与文档共用）
- 每个 id 对应：`en`/`zh_hans` 显示名、说明、参数 schema、取值约束、是否"安全类"。
- UI 渲染与文档生成都读这份目录；AI 的 JSON 只用 id。目录本身纳入 addon 版本管理。

## 附录 C：术语
- **owner / epoch**：当前控制来源与其代际；用于执行前校验，防止过期动作落地。
- **adapter**：某技能的声明式安全描述（几何/目标/自伤/前置）。
- **三值逻辑**：`true/false/unknown`；`unknown` 按安全语义 pause 或 skip。
- **dry-run**：只对当前快照求值、不执行。

---

## 17. 修订历史（非规范；以正文为准）

1. **先冻结合同**：见 §0.1 —— 只处理当前可见战斗，无可见敌人即结束，不探索/不换层，无动作不空等。
2. **战斗语义**：§5.3 新增目标绑定流程、两阶段失败语义、sustains 期望态；附录 A 修正 searing 目标
   （条件与动作绑定同一目标）与 retreat 优先级（不再默认"撤退优先于治疗"）。
3. **安全收敛**：§8.1 未知作用范围表、§8.2 执行保证 vs 策略目标、原版 `automaticTalents` 排他、旁观不抢控制。
4. **首版范围提升**：简单 UI + 角色持久化 + **一个真实试点构筑**（治疗/护盾/资源恢复/稳定输出全覆盖）
   进入 P1；预设按构筑而非"每类动作一个样例"。
5. **版本不变量**：§6.3 三态 draft/approved/running；`set` 不直接激活；简单/高级不丢条件。
6. **文档一致性**：冻结谓词语法（§5.2，`{"<pred>":{"<cmp>":<value>}}`）；`computed` 用有限枚举 id；
   整型化只覆盖整数字段；日志改名"决策追踪"；动作白名单与 capabilities/UI 必须一致。
7. **可用性验收**：§14 新增指标（上手操作数、人工重启次数、非预期暂停率、试点覆盖率、暂停可操作性）。

> **首版默认不包含自动撤退**：`move{retreat}` 仅在预设显式启用且通过目的地判定测试后可用（见 §5.4）。

仍待拍板项见 §16；其中 "daily 模式"（`pause_on_new_enemy`）需要明确风险定义与“每个 encounter 只暂停一次”
的状态，且**默认仍为 strict**。执行架构的边界契约（启动时已 ready、暂停/改策略失效旧决策、瞬发预算与
瞬发后快照、目标窗口暂停规划、无进展短路、规则/深度/候选/日志上限）见 §4 与 §9。
