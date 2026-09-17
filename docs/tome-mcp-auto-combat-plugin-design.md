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

### 0.1 产品契约（v1.1 冻结，先于一切实现）
**按下启动后，它只负责“处理当前可见战斗”**：
```
启动 → 校验策略/技能支持 → 自动处理当前可见战斗
     → 出现明确风险时暂停并解释 → 无可见敌人时结束 → 控制权交还玩家
```
- **无可见敌人即结束**；不探索、不追击进未知区域、不自动换层。
- **没有可用动作时不空等**：不因规则失败就隐式等待冷却/巡逻，而是**停止并说明原因**。
- 自动等待/巡逻只作为**独立的显式模式**，不从规则失败中隐式产生。
- “接管到什么程度”是产品承诺，必须先冻结；复杂能力（rest/auto_explore/换层/复杂撤退）后移。

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
- **G6 安全可证**：只读玩家已知信息；只调已审计原生入口；未知即保守；不跑任意代码。
- **G7 可验证可回放**：确定性决策（无 RNG 平局）、dry-run 诊断、有界决策日志。

### 1.2 非目标（v1）
- 不追求"任意职业/任意 mod/任意技能"全覆盖；用**声明式能力目录**逐项支持。
- 不做队友指挥、自动换装/工匠、召唤管理、自动换层（放 P1b/P2）。
- 不做在线学习/自适应；策略由人或 AI 显式编写。
- 不链接现有 `tome-auto_talent_assistant` 的运行态（见 §12）。
- 不替代 MCP 的逐动作精细控制（Boss/未知场景仍用 A 模式接管）。

---

## 2. 设计原则

1. **数据，不是代码**。策略只允许 JSON 标量/数组/对象；禁止函数名、字段路径、正则、Lua 表达式。
2. **三值逻辑 + fail-closed**。条件求值结果 `true/false/unknown`；`unknown` 的传播规则显式定义；
   安全类输入为 `unknown` 必须 **pause**，非安全类可 skip 该规则。
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

动作白名单：`use_talent`（带 `target` selector 或 `x/y`）、`attack`、`move`（`direction` 或 `retreat` 一步/多步）、
`wait`、`use_item`、`rest`（P1b）、`auto_explore`（P1b）、`change_level`（默认禁用，需显式 opt-in）。

目标 selector：`nearest_hostile`、`lowest_hp_hostile`、`highest_rank_hostile`、
`most_dangerous`（按 `computed`）、`cluster_center`（AoE：`min_targets`、`max_selffire`）、`self`、`position`。

**规则字段（冻结）**：`id`、`priority`（越大越先）、`when`、`then`、可选 `emergency:true`、可选 `enabled`。
**危急自保必须由 `emergency:true` 显式标记**，执行器再用能力目录验证该动作确实满足自保要求；
**不得靠规则名为 `heal` 或优先级高低推断**。

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

### 5.4 危急状态与自保语义（v1.2 冻结）
执行器按固定三层，策略只能**收紧**不能放宽：
1. **执行边界异常**（owner/场景/原生错误/unsafe unknown）→ 停止或暂停。
2. **危急状态**（`hp_pct < flee_below_hp_pct` 或卫生守卫触发）→ **只**尝试预设中明确允许的紧急自保
   （治疗/护盾/解控/一步撤离）；**无可用方案则暂停并交还玩家，不继续普通输出**。
3. **其余状态** → 执行普通规则（按 priority）。
- `min_hp_pct`：**启动/继续门槛**——低于它不开始/不继续普通规则（进入第 2 层）。
- `flee_below_hp_pct`：第 2 层紧急自保触发阈值；必须 `<= min_hp_pct`。
- **首版默认不出自动撤退**；`move{retreat}` 仅在预设显式启用且通过目的地判定测试后可用。
- 自保动作同样要过 adapter/`canProject`/原生返回；`unknown` 按 §8.1 处理。
- **阈值边界（冻结用例）**：`hp_pct < min_hp_pct` 即禁止普通输出（进入第 2 层）；例如 `min_hp_pct=35` 时，
  生命 30% 不得放普通输出，与是否低于 `flee_below_hp_pct` 无关。
- **Wave 1（D6）阈值诚实化**：`flee_below_hp_pct` 是**独立的暂停原因**（`flee_below_hp_pct`），
  只把控制权交还玩家，不做自动撤退；`sustain.min_resource_pct` 真正门控常驻激活（资源未知则不激活）。
- **Wave 1（D1/D2）自保与自伤**：`emergency:true` 可声明任意 `use_talent`/`attack`，安全性由执行前的
  版本固定 adapter guard 在实际绑定目标上判定（射程/`canProject`/几何/自伤/友伤 + `max_selffire_risk`）；
  `max_selffire_risk==0` 为硬拒绝，`>0` 为暂停阈值。

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
消耗/射程的静态值）安全。动态渲染的提示文本**不得**用于决定谓词，也不得自动鉴定物品；
它仅允许作为**信息性读取**（供 planner 理解），且必须满足：来源为已审计原生函数、
经 RNG/状态**绊线**验证为纯函数、且实体已鉴定/已知；无绊线则保持排除（见 §8）。
谓词只使用无 RNG 的标量面板 getter。

### 5.7 自伤（selffire）建模（重要）
- 只有技能**显式**声明 `selffire` 才是确定值；缺省的面积形状为 `unknown`。
- adapter 记录**实际伤害语义**，而不是只看目标光标形状：
  - `T_SEARING_LIGHT`：伤害是**单体 `hit`** + 地面光域 `addEffect(..., selffire=false, friendlyfire=false)`
    → **无自伤**；`{type="ball",radius=1}` 只是瞄准光标。
  - `T_SHADOW_BLAST` / `T_STARFALL`：`selffire=self:spellFriendlyFire()` → 运行时动态，保守按可自伤处理。
  - `T_SUN_FLARE` / `T_TWILIGHT_SURGE` / `T_MIND_BLAST`：`selffire=false`。
- `safety.max_selffire_risk` 默认 **0**：P1 不允许自动投概率风险；`cluster_center` 选位必须在
  `canProject` + adapter 语义下证明不会命中自身/友军，否则 skip 或 pause。

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
   - **纯度由“该函数是否经过纯读取审计”决定，不由函数名决定**：名叫 `target`/`info` 也要被审计拒绝则不调用；
     不触发 RNG（`tie_break` 用稳定排序）。
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
  **动态提示文本不得决定谓词**：它不得用于任何 `when` 条件，也不得自动鉴定实体；仅当来源为
  已审计原生函数、经 RNG/状态**绊线**证明为纯函数、且实体已鉴定/已知时，才可作为 planner 的
  信息性读取；无可用绊线的来源保持排除。谓词只使用无 RNG 的标量面板 getter。
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
| 未知/异常 | 建议行为 |
| --- | --- |
| 控制权、当前角色、场景边界、原生动作是否结束不明确 | **整个执行器暂停** |
| 某范围技能的友伤/几何不明确 | **禁用该动作**，不否定其它已验证动作 |
| 仅用于目标优化的属性不明确 | 跳过依赖它的规则，或用规定好的简单 selector |
| 当前唯一自保动作是否安全不明确 | 暂停并交给玩家 |
| 玩家学了一个策略未使用的未适配技能 | 显示“未支持”，**不阻止启动** |

三值逻辑要**尊重短路**：技能已明确在冷却，就不必因其伤害属性未知而暂停全部自动战斗。

### 8.2 保证的边界（v1.1 修正）
- **执行保证**（可强证明）：不越权执行、不重复提交、不使用失效目标、不读取禁止信息、不调用未支持的规划函数。
- **战斗策略目标**（不承诺）：尽量避免已知友伤、合理治疗、减少危险动作。
- 插件保证“**按受控规则执行**”，**不保证**“不会做出导致死亡的战术选择”。验收措辞必须区分这两类。

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
- **模式**：strict（`pause_on_new_enemy=true`）；`max_selffire_risk=0`；**默认无自动撤退**；
  **不含 rest/auto_explore/change_level**。
- 不进入首版的动作/选择器不进 schema（仅在能力目录/路线图说明）。
- **协议**：v4 **增量能力门控**（`capabilities.auto_combat`）；后续语义无法兼容再升 v5。
- **`expected_hash` 指向唯一对象**：写 draft（`set_draft`）与 `approve` 比较 **draft** 当前 hash；
  `activate` 比较 **approved** 版本 hash；不匹配返回 `policy_conflict`。（实现与 UI 一致：
  approve 为 draft 的 CAS，activate 为 approved 的 CAS。）

P1a **不做**：队友/装备/物品/召唤管理、rest、auto-explore、换层、assistant 翻译、在线学习。

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
