# ToME MCP 功能扩展需求（草案）

> **Supersession banner (v1.6 / `AGENTS.md` + design §8.3).** 本文是 0.8.0/v3 时期的需求草案。
> 其中 §0.3 “只读纯度（不得调用 RNG / `preUseTalent` / 动态 `info`…）”与 §0.7 的“源码一致性校验”
> 前提已被**取代**：当前协议为 **v4**，读取只有两条红线——不提交动作、不泄露玩家未知信息；当前实时
> 的 getter/builder（含动态 `info`/`target`/`preUseTalent`-类构建器，除执行入口外）**可以调用**，
> 允许消耗 RNG/有读副作用。另参见 §0.7 与 R3–R5 的修订。历史需求原文保留作背景。

日期：2026-09-15。基线：ToME / T-Engine 1.7.6（HEAD `624a67329f`）、MCP Bridge 与 Python server **0.8.0**。协议已统一为 **v3**（v1/v2 在测试阶段移除）；字段以 [v3 契约](tome-mcp-v3-talent-query.md) 和 [API 字段](tome-mcp-api-fields.md) 为准，[交互能力设计](tome-mcp-interaction-capabilities-design.md) 仍有参考价值。

> 注：当前实现已升级到协议 **v4**；v3 描述与字段清单为历史。

本文只定义以下 7 项功能扩展需求，**不处理整场战役等流程缺口**（出生、通关、长程规划等仍不在本轮范围）。每项需求都给出原生依据、接口需求、行为边界和验收标准，作为实现与验收的输入，不是实现方案本身。

## 0. 共同约束（对全部需求生效）

1. **单一控制来源。** 一次只有一个未释放执行占用的根命令；接入 `session_id` / `control_token` / `revision` / `command_id`，沿用去重、回执、`stop`、手动接管和 Battle Companion 互斥语义。
2. **只经原生入口。** 不直接改内存字段、不调用 `forceUseTalent`、不跳过冷却/资源/前置检查、不提供任意 Lua、方法名或回调地址。新增动作必须在原生调用发生前重新校验场景、角色、目标与交互归属。
3. **只读边界（v1.6 修订）。** `observe` / `inspect` / `status` **不提交任何游戏动作**，也**不暴露玩家未获知的信息**——这是读取的两条红线。除此之外，读取**可以**调用当前实时的原生 getter/builder（包括 `getTalentTarget`/`t.target`、动态 `info`/描述函数、`preUseTalent`-类构建器等，**执行入口**除外），**允许消耗 RNG / 有读副作用**。报错/缺失/返回 `nil`/类型无效时该值标 `unknown`，不现场篡改游戏状态。
4. **错误语义。** 原生返回 `false` 也可能已消耗资源；`failed` / `uncertain` 不等于未执行。不自动重试，不声称回滚。原生异常隔离写入，直到读档或新 session。
5. **会话边界。** TCP 重连保留游戏 session；读档/重启/切图按既有规则失效旧引用；运行态（socket、队列、协程、租约）不进入存档。
6. **协议版本。** 协议已统一为 **v3**；新增能力直接在 v3 上提供，不再保留 v1/v2 分支。
7. **验证与留证。** 每项需求需有单元回归 + 隔离真实游戏场景；失败与预期故障注入保留；生产 `.teaa` 不含测试 probe。原生插入点可记录构建/源码摘要作为**离线重审/遥测**（不构成运行期门槛）。

## R1. 洗点

### R1.1 目标

在**原生允许的范围内**退还属性点、职业/通用技能点与类别点，并复用原生 `LevelupDialog` 的“取消学习”分支；不提供绕过游戏规则的任意洗点。

**实现状态（2026-09-15）**：已实现 `unlearn_talent`（退还原生 `last_learnt_talents` 窗口内、非战斗的单个技能点）。原生核实后确认：**属性点与已解锁类别在打开新的原生升级对话框之外无法退还**（`incStat(-1)` 与 `learnType(false)` 依赖本次对话框的 `actor_dup` 基线），因此不提供 `refund_stat` / `unlearn_category`，不伪造一个组合对话框来绕过。**F-2 已修**：原先 `playerAudit` 在 `p.alchemy_golem` 存在时返回 `progression_player_busy`；该误判已移除（原生 `LevelupDialog` 只在 `init`/`cancel` 备份/还原魔像，MCP 路径不调用 `cancel`），带魔像角色现可正常成长/洗点。详见下方 R1.4。

### R1.2 原生依据

- [`LevelupDialog:learnTalent(t_id, v)`](../../../../game/modules/tome/dialogs/LevelupDialog.lua) 的 `v=false` 分支执行 `unlearnTalent` 并回退点池；`learnType(tt, false)` 与 `incStat(sid, -1)` 分别回退类别与属性。
- [`LevelupDialog:isUnlearnable`](../../../../game/modules/tome/dialogs/LevelupDialog.lua) 决定可退还范围：默认仅 `last_learnt_talents` 窗口内、且 `not actor.in_combat`（或关卡 `allow_respec == "limited"`）；`item_talent_levels_learnt`、`no_unlearn_last` 等受保护技能不可退还。
- 依赖检查由 `checkDeps` 与原生回滚逻辑保证：退还会因“被其他技能依赖”而失败，不允许产生非法角色。
- **觉醒（prodigy）永不可洗点**（原生 `no_unlearn` / “cannot be unlearned”），R1 不覆盖。

### R1.3 接口需求

| 动作 | 参数 | 说明 |
| --- | --- | --- |
| `unlearn_talent` | `talent_id` | 退还 1 点已学主动/被动技能；仅限原生 `last_learnt_talents` 窗口内且非战斗 |
| `refund_stat` | — | **不提供**：原生只在本次升级对话框内允许退还 |
| `unlearn_category` | — | **不提供**：原生只在本次升级对话框内允许退还 |

- 结果字段：`points_returned`、`pool`、`previous_value`、`new_value`、可选的 `native_message`。
- `inspect(kind="progression")` 扩展：新增 `respec.unlearnable` 列表，给出当前可退还的技能及 `pool`、位置与不可退原因（`not_recently_learnt`、`in_combat`、`protected`、`item_granted`）。
- 每次调用只退还一个点，与现有 `spend_stat` / `learn_talent` / `learn_category` 对称。

### R1.4 行为与边界

- **严格遵守原生规则**（已确认）：不改变 `config.settings.cheat`、不把 `isUnlearnable` 判定替换为“总是可退”。
- **明确不提供任意/作弊洗点**：无开发者模式、无全量重置；`cheat` 配置不纳入需求范围。只能退还原生允许的点数。
- 退还后点池增加、依赖校验与原生回调（含持续技能刷新）照常生效；无条件失败不扣点。
- 精确复用已审核的 `LevelupDialog` 分配/完成/清理路径（与 `Progression.lua` 一致），不新增独立洗点实现。

### R1.5 验收标准

- 单元：可退判定、历史上限窗口、战斗中拒绝、item 授予/保护拒绝、点池回退、历史上的移除、只读守卫（`inspect` 不触发 `unlearnTalent`/`canLearnTalent`/`checkDeps`）。
- 原生（待补）：隔离角色在非战斗状态下退还最近学习的一个技能点，点池与面板一致；窗口外或战斗中请求被原生规则拒绝且不扣点；保存重载后状态保持。属性/类别退还不作为验收项。

## R2. 觉醒点与纹身槽扩展

### R2.1 目标

支持消费**觉醒点（prodigy point）**学习觉醒/进化，并支持消费类别点**扩展纹身/符文槽**。

### R2.2 原生依据

- 觉醒点：角色在 25、42 级获得 `unused_prodigies`（[`Actor.lua`](../../../../game/modules/tome/class/Actor.lua) 升级流程）；学习界面为 [`UberTalent`](../../../../game/modules/tome/dialogs/UberTalent.lua)，提交在 [`LevelupDialog:finish`](../../../../game/modules/tome/dialogs/LevelupDialog.lua) 的 `on_finish_prodigies` 阶段。觉醒可能是职业/种族**进化**（`is_class_evolution` / `is_race_evolution`，影响 `has_evolution`）。
- 纹身槽**单独扩槽按钮**：[`LevelupDialog`](../../../../game/modules/tome/dialogs/LevelupDialog.lua) 的 `b_inscriptions`（文本 “Inscriptions”）在 `inscriptions_slots_added < 2` 时显示；点击后若 `unused_talents_types > 0`，弹出 `Dialog:yesnoPopup` 确认，确认后执行 `unused_talents_types -= 1`、`max_inscriptions += 1`、`inscriptions_slots_added += 1`；否则提示需要类别点。**这是与镶嵌分离的独立原生入口。**
- 实际镶嵌：[`player-inscription` chat](../../../../game/modules/tome/data/chats/player-inscription.lua) 负责放置/替换纹身，并同样提供“用 1 点类别点购买新槽”的选项（条件相同，槽位上限 5）。槽状态存于 `max_inscriptions` / `inscriptions` / `inscriptions_data` / `inscriptions_slots_added`（[`ActorInscriptions`](../../../../game/modules/tome/class/interface/ActorInscriptions.lua)）。

### R2.3 接口需求

| 接口 | 参数 | 说明 |
| --- | --- | --- |
| `learn_prodigy` | `prodigy_id` | 消费 1 觉醒点；走 `UberTalent` 暂存 + `LevelupDialog:finish` 提交 |
| `inspect(kind="prodigy")` | `id` 或列表 | 已可见觉醒/进化的 `canLearnTalent` 前置摘要、`readiness`（available/blocked/unknown）、是否进化 |
| `expand_inscription_slot` | 无 | **独立扩槽**：复用 `LevelupDialog` 的 Inscriptions 按钮路径，消费 1 类别点、`max_inscriptions + 1` |
| `inspect(kind="inscriptions")` | `id="player"` | `max_inscriptions`、各槽内容、`inscriptions_slots_added`、`can_expand_slot`、`unused_talents_types` |
| `inscribe` | `item_id`、可选 `mode`：`new_slot`/`replace`、可选 `slot` | 镶嵌纹身/符文，调用原生 `player-inscription` 流程 |

- 快照扩展：`player.prodigy_points`（`unused_prodigies`）、`player.category_points`（现有）、纹身槽摘要。
- `expand_inscription_slot` 的确认使用 `dialog.confirm` provider 回答原生 `yesnoPopup`；已到 2 次上限或缺少类别点时返回原生拒绝，不扣点。
- `player-inscription` 对话作为可回答 provider（`dialog.choice` 或专用 `inscription.select`）暴露，选项文本与 ID 来自当前已渲染列表；其中的 `new_slot` 选项也应在当前显示且条件满足时可用。

### R2.4 行为与边界

- 觉醒学习是**两阶段**：先暂存（可切换撤销），`finish` 时才真正学习；结果需报告暂存态与最终态，重复 `command_id` 不重复扣点。
- 进化型觉醒保留 `has_evolution` 属性变化；未知或改写过的觉醒定义返回 `unsupported` / `needs_input`。
- 扩槽与镶嵌在原生中是两条路径：`expand_inscription_slot` 走 `LevelupDialog` 的独立按钮（只扩槽、不镶嵌），`inscribe` 走 `player-inscription` chat（放置/替换，可选顺带扩槽）。两条路径都必须按原生入口执行，不能互相代替或绕过 `unused_talents_types`/上限检查。
- 镶嵌替换会 `unlearnTalent` 旧纹身并可能影响热键；不读取或伪造隐藏数据，不自动鉴定。
- 槽上限、同类型数量限制、`inscription_forbids`/`restrictions` 全部沿用原生判定。

### R2.5 验收标准

- 单元：觉醒暂存/提交/撤销、点池变化、进化属性、只读守卫；`expand_inscription_slot` 的确认/拒绝/上限/缺类别点；镶嵌 new_slot / replace / cancel、条件不满足时按原生结果处理、点池扣减。
- 原生：隔离角色在 25 级学习一个觉醒并保存重载；用 `expand_inscription_slot` 单独扩一次槽（`max_inscriptions` 增加、类别点减少），再完成一次镶嵌；重复请求不重复扣点；不满足条件时返回原生拒绝或 `needs_input`。

## R3. 扩展学习支持与行为交互接入

### R3.1 目标

把当前只审核标准 Berserker 的 11 类技能树的成长支持，扩展为**由运行时原生检查驱动的通用学习**，并通过**行为交互接入**处理学习过程中出现的原生确认/对话，而不是硬编码白名单或直接拒绝。

### R3.2 现状与差距

- [`Progression.lua`](../overload/mod/mcp_bridge/Progression.lua) 目前用 `addCategory(...)` 硬编码 11 个类别；R7（loop 38，2026-09）已移除学习/花费路径上的**源文件/行号身份审计**（原 `D.native`/`sourceLine` 门禁）：定义与玩家方法一律按**结构性检查（存在/可调用/类型）+ 实时调用**处理——被替换但可用的函数会被使用，原生对话框为最终裁判；来源仅作重审遥测（见 `docs/tome-mcp-0.9.0-review-disposition.md` D11 superseded 注）。其他职业/类别仍只能只读摘要。
- v2 已有 `dialog.confirm` / `dialog.choice` / `inventory.select` 等 provider，但学习相关 UI 没有统一接入。

### R3.3 接口需求

- `learn_talent` / `learn_category` 扩展到**任意可由运行时原生检查确认的类别**：
  - 支持情况在运行时由角色现有 `talents_types_def`、类别定义审核和原生 `canLearnTalent` **执行时**检查决定，只读摘要用其保守近似并标注 `readiness`。
  - 类别来源可记录“函数来源 + 定义完整性 + 版本清单”作为**重审提示/遥测**；被第三方覆盖或识别不了的定义按实际调用结果处理（报错/缺失→`unknown`/`unsupported`），**不以“被替换”本身作为拒绝理由**，也不承担其它 addon 实现的责任。
- 新增/复用的交互 provider 覆盖学习流程可能出现的：确认框、类别选择、自定义学习弹窗、进化提示。
- `inspect(kind="progression")` 返回：`supported`、`readiness`（available/blocked/unknown）、`blocked_reason`、点数池、`next_raw_level`、`cost`；可调用实时需求函数求值，不可得时标 `unknown`。
- 快照暴露全部点数池：`unused_stats`、`unused_talents`、`unused_generics`、`unused_talents_types`、`unused_prodigies`。

### R3.4 行为与边界

- “行为交互接入”指：遇到非标准学习 UI 时，桥接按当前栈顶实际渲染内容生成 interaction，用 `respond` 回答；无法识别或没有恢复入口时转 `needs_input`，不静默绕过。
- 一次只分配一个点；无条件失败不扣点；部分失败标 `uncertain` 并隔离写入。
- 保持既有约束：不开放任意 UI 回调、不强制、不洗点（洗点见 R1）、不替玩家选择不可逆剧情。

### R3.5 验收标准

- 单元：多职业/多类别定义的运行时准入、来源可记录为重审遥测（但不以“被替换”为拒绝理由）、点数池、原生回调、只读守卫、interaction 归属。
- 原生：至少两个不同职业（非 Berserker）角色经 MCP 学习技能/类别；一个自定义确认弹窗通过 `respond` 完成；未知 UI 正确转人工。

## R4. 物品丢弃与买卖

### R4.1 目标

补齐物品流转：丢弃持有物，以及在商店中买入/卖出。

### R4.2 原生依据

- 丢弃：[`ActorInventory:dropFloor(inven, item, vocal, all)`](../../../../game/engines/default/engine/interface/ActorInventory.lua)，保留 `item:check("on_drop")`、`removeObject`、`onDropObject`、地面 `on_drop` 地形回调；原生丢弃命令见 [`Actor.lua`](../../../../game/modules/tome/class/Actor.lua)。
- 商店：[`engine.Store:interact(who, name)`](../../../../game/engines/default/engine/Store.lua) 打开 [`ShowStore`](../../../../game/modules/tome/dialogs/ShowStore.lua)；买卖经 `tryBuy` / `onBuy` / `transfer` / `doBuy` 与 `trySell` / `onSell` / `doSell`，堆叠数量走 `GetQuantity`，买确认走 `Dialog:yesnoPopup`；价格由 `descObjectPrice` / `descObject` 提供。

### R4.3 接口需求

| 动作 | 参数 | 说明 |
| --- | --- | --- |
| `drop` | `item_id`、可选 `quantity` | 仅本人携带/装备；调用 `dropFloor` |
| `buy` | `item_id`、可选 `quantity` | 当前已打开且归属于本命令的商店 |
| `sell` | `item_id`、可选 `quantity` | 同上 |
| `inspect(kind="store")` | 无 / `item_id` | 只读读取当前商店库存、已知价格、金币/商店资金；不鉴定、不命名 |

- 新 interaction provider：`store.select`（模仿 `inventory.select`，保留当前筛选/页签与原生回调），用于桥接 `ShowStore` 的 `use`。
- 结果字段：`quantity`、`price`、`gold_before`/`gold_after`（或 `unknown`）、`energy_spent`、物品转移结果、可选的确认回执。

### R4.4 行为与边界

- 丢弃：不强制、不跨容器；`on_drop` 返回真值时拒绝并报告；`quantity` 受堆叠数限制；地面满则按原生结果处理。
- 商店：只有原生 `interact` 打开的 `ShowStore` 且归属于当前 command 时才可操作；不打开任意商店、不绕过 `allow_buy`/`allow_sell`、不修改价格。
- 买入确认与数量选择通过 `dialog.confirm` / `store.select` 回答；`cancel` 不产生交易。
- 卖出的物品可能被 `no_sell`/任务物品等原生规则拒绝；价格读取不得触发鉴定或动态命名副作用。
- 交易是已提交的角色/世界变化，超时、断线、错误一律保留 `command_id` 查询，不重试、不回滚。

### R4.5 验收标准

- 单元：`drop` 各分支（on_drop 拒绝、堆叠、全丢）、`buy/sell` 数量与确认、价格只读守卫、interaction 归属与去重。
- 原生：隔离角色丢弃一件并保存重载；在一处真实商店买入与卖出各一次，金币与背包一致；重复请求不重复交易。

## R5. 技能目标预填与技能信息查询

### R5.1 目标

1. 允许 `use_talent` **预填一次目标**，减少模型往返（经新协议 **v3**）；
2. 提供**只读**技能信息接口，查询资源消耗、射程/距离、目标要求、条件与可用性。

**实现状态（2026-09-15）**：协议 v3、只读查询与一次性预填已实现，单元与 Python 测试通过，契约见 [v3 契约](tome-mcp-v3-talent-query.md)。方向预填与视线（`line_of_sight`）本轮未提供，`capabilities.talent_prefill` 当前只声明 `actor` 与 `position`。**独立验收发现的 F-1（预填绕过原生射程）已修复**：静态射程在动作开始前拒绝，动态射程在第一次 `getTarget` 处校验，越程/自我警告回退原生目标提示，`respond` 的格子答案也校验射程。**F-3 已补**：查询返回 `current_costs`（按原生 `postUseTalent` 公式计算的实时值，含疲劳/效果）与 `base_costs`（存储基础值）；`costs_complete` 标明实时值是否全部可知。原生重新验收待补。

### R5.2 原生依据

- 目标：v1 已可用 `player:useTalent(id, nil, nil, nil, target)` 的 `force_target`；v2 当前刻意不预填（[交互能力设计](tome-mcp-interaction-capabilities-design.md) 规定“将来若增加首个输入预填，必须显式限定消费一次，另行扩展契约”）。
- 查询函数：[`getTalentRange`](../../../../game/engines/default/engine/interface/ActorTalents.lua)、`getTalentRequiresTarget`、`getTalentTarget`、`getTalentCooldown`、`isTalentCoolingDown`、`getTalentLevel`、`getTalentFullDescription`；`preUseTalent` 属构建器读取，**可以调用**（可能消耗 RNG/有读副作用），但不得提交动作。

### R5.3 接口需求

**目标预填**

- 通过协议 3 提供；`use_talent` 可选 `target_id` / `position` / `direction`，**只消费一次**：命中第一次原生 `getTarget`；若原生改为询问其它目标或发出警告，仍按交互流程回答。
- 预填不绕过 `Player:getTarget` 的合法性、玩家目标重定向、范围/投射/自我警告；预填目标在原生流程中被修正或拒绝时，结果如实反映。
- 预填与 `command_id` 去重指纹绑定。

**只读查询**（扩展 `tome.inspect(kind="talent")`）

| 字段 | 来源/规则 |
| --- | --- |
| `range` / `radius` | 调用当前实时的原生 `getTalentRange` 等 getter；缺失/报错/返回 `nil`/类型无效时 `unknown` |
| `requires_target` / `target_mode` | `getTalentRequiresTarget` / 定义字段 |
| `cooldown` / `cooldown_remaining` | 定义字段 / `isTalentCoolingDown` |
| `current_costs` / `costs_complete` | 当前实时消耗（原生 `postUseTalent` 公式，含当前疲劳/效果）；不可知项为 `unknown` |
| `base_costs` | 存储的基础消耗 |
| `affordable` | 用当前快照资源与 `current_costs` 对比，资源不可知时 `unknown` |
| `conditions` / `readiness` | 调用实时需求函数/公式求值；`available`/`blocked`/`unknown`，非最终预检 |
| `distance_to_target` | 当传入 `target_id` 或 `x`/`y` 时，用快照坐标计算直线距离与是否在 `range` 内 |
| `line_of_sight` | 可调用实时 LOS 函数求值（允许读副作用）；缺失/报错/`nil` 时 `unknown` |
| `prefill_supported` | 本连接是否允许预填目标 |

- 不提交任何动作，也不泄露玩家未知信息；可调用当前实时的动态 `info`/`target`/需求函数（允许 RNG/读副作用），不可得时标 `unknown`；不保证施法成功。

### R5.4 行为与边界

- 预填是**优化**不是保证：最终范围、阻挡、重定向、条件仍由原生决定；失败不重试。
- 查询结果用于决策，不构成 `act` 的前置校验承诺；执行时仍重新验证。
- 观察读取回归必须验证：不提交动作、不读到隐藏信息；实时 getter 报错/缺失/`nil` 时结果为 `unknown`（**不**要求零 RNG/零副作用）。

### R5.5 验收标准

- 单元：预填命中首问、原生改问时回退、预填目标非法时拒绝、去重；查询字段与读取边界守卫（不提交动作、不读隐藏信息；实时 getter 不可得→`unknown`）。
- 原生：对有目标技能预填目标完成一次施法；对无目标/错误目标返回正确结果；`inspect` 返回的 `range`/`current_costs`/`readiness` 与实测一致或标 `unknown`。

## R6. 自动探索接口

### R6.1 目标

提供有界、可中断、可查询的**原生自动探索**任务，替代逐格 `move` 的高往返驱动。

### R6.2 原生依据

- [`Player:autoExplore()`](../../../../game/modules/tome/class/interface/PlayerExplore.lua) 生成/更新 `player.running` 路径；
- [`Game.lua`](../../../../game/modules/tome/class/Game.lua) 的 `RUN_AUTO` 负责：检查 `no_autoexplore`、视野内敌人则拒绝、`autoExplore()` 后按 `while enoughEnergy() and runStep() do end` 推进，并支持 `tome.rest_before_explore` 先休息。
- 任务生命周期可复用现有 [`NativeTasks`](../overload/mod/mcp_bridge/NativeTasks.lua) 模式（`rest` 已有同样结构）。

### R6.3 接口需求

| 动作 | 参数 | 说明 |
| --- | --- | --- |
| `explore` | `max_steps`（默认/上限有界）、可选 `rest_first` | 原生自动探索任务 |

- 结果字段：`steps_executed`、`max_steps`、`turns_executed`、`stop_reason`、`position`、`level_instance_id`、累计 `energy_spent`、可选 `native_message`。
- `stop_reason` 至少覆盖：`nowhere`、`enemy_in_sight`、`damaged`、`dialogue`、`control_lost`、`max_steps`、`no_autoexplore`、`inventory_full`（若原生触发）、`native_stopped`。
- 与 `rest` 一致：任务进行中 `status` 返回进度而非完整地图；`stop` 走原生停止；读档/断线不恢复。

### R6.4 行为与边界

- 必须复用原生 `autoExplore` + `runStep`，**不实现自有寻路**；允许 `rest_first` 复用 `tome.rest_before_explore` 语义。
- 视野内出现敌人立即停止，交由上层决策；不代替战斗。
- 严格步数/回合计入上限（含首步）；预算耗尽调用原生停止并报告。
- 原生对话、换层、伤害、控制权变化、`stop` 均可中断；中断后只查询结果，不自动继续。
- 探索产生的日志用 `events_after` 读取，不额外触发感知或随机函数。

### R6.5 验收标准

- 单元：停止原因分类、步数/回合上限、预算耗尽、`stop`、去重、无寻路副作用、只读守卫。
- 原生：隔离角色在已探索地牢执行 `explore`，无敌人时推进若干步后因 `nowhere` 停止；有敌人时 `enemy_in_sight` 停止；中途 `stop` 正常释放；保存重载不恢复旧任务。

## R7. 建立 Git 追踪

### R7.1 目标

把 MCP 相关成果纳入版本管理，且**不污染上游 ToME 历史、不误提交无关文件**。

### R7.2 现状

- 仓库 `origin` 为 `yutio888/t-engine4`，`upstream` 为只读官方仓库，当前分支 `codex/hd2d`，HEAD 停在 2023-06-29 官方提交。
- `.gitignore` 已用白名单放行 `game/addons/tome-mcp-bridge/` 等 addon，但 `tools/`、`documentation/`、临时/大文件尚未规划。
- MCP 相关共约 35 项 untracked，包含源码、测试、文档、验收 JSON/PNG、`.teaa` 包以及 `__pycache__`、`.venv`、`egg-info` 等。

### R7.3 需求

1. **建立独立分支**（如 `feature/tome-mcp`）承载 MCP 成果，不改写既有历史、不强推 `upstream`。
2. **提交范围**（应跟踪）：
   - `game/addons/tome-mcp-bridge/`：Lua 源码、`hooks/`、`superload/`、`overload/`、`README.md`、`VALIDATION.md`、`dist/manifest.json`、测试脚本与 fixture 源码、`tools/`（打包/生成脚本）。
   - `tools/tome-mcp-server/`：Python 源码、`pyproject.toml`、`README.md`、测试。
   - `documentation/` 下的 MCP 契约、设计、验收、战役报告。
3. **忽略范围**（加入 `.gitignore`）：`__pycache__/`、`*.pyc`、`.venv/`、`*.egg-info/`、`build/`、`.DS_Store`、`tmp/`、本地 venv、临时日志，以及所有 `*.teaa` 与 MCP 验收 `*.png`。
4. **大文件策略（已确认）**：**不跟踪 `.teaa` 与 `.png` 文件**。仅提交 `manifest.json`、SHA-256 与复现脚本/说明；`.teaa` 与验收 PNG 保留在本地或另行分发，用哈希保证可追溯。
5. **不提交**与 MCP 无关的既有未跟踪内容：`.DS_Store`、`.build-deps/`、`tome-chn-mod.teaa.bak-before-numeric-diff`、`tome-chn-mod/`、`documentation/asset-audit-*`、`game/addons/tome-danger-alert-/`、`game/addons/tome-battle-companion/` 等，除非用户单独确认。
6. **可追溯性**：保留 `dist/manifest.json` 的逐文件 SHA-256；提交信息按功能分组；确保提交后 `git status` 对 MCP 部分干净。
7. **验证**：提交前后核对 `package.py` 输出哈希不变；不修改任何已冻结的历史验收证据。

### R7.4 验收标准

- `git status` 显示 MCP 源码/文档/测试已跟踪，缓存与临时文件被忽略；
- 检出的新工作副本能按 README 运行 Lua 单元与 Python 单元测试；
- `dist/manifest.json` 记录的 SHA-256 与 `package.py` 输出一致（`.teaa` 本身不提交）；
- 未提交任何用户未确认的无关文件。

## 8. 依赖关系与建议顺序

| 顺序 | 需求 | 依赖 |
| --- | --- | --- |
| 1 | R7 Git 追踪 | 无（可先行，保护后续改动） |
| 2 | R5 技能查询与预填 | 无（查询先于依赖它的 R1/R3 决策） |
| 3 | R1 洗点 | R5（可退性查询）、R3（共用 LevelupDialog 路径） |
| 4 | R2 觉醒与纹身槽 | R3（学习路径）、R5（前置查询） |
| 5 | R3 通用学习 | R5 |
| 6 | R4 丢弃与商店 | 无强依赖 |
| 7 | R6 自动探索 | R4（背包满中断可用） |

R5 与 R7 可并行；建议先落 R7 保护工作区，再实现 R5，其余按表推进。

## 9. 统一验收框架

| 层次 | 要求 |
| --- | --- |
| Lua 单元 | 新动作/查询的校验、去重、边界、读取边界守卫（不提交动作、不读隐藏信息；实时 getter 不可得→`unknown`） |
| Python / 官方 SDK | 新工具 schema、严格参数联合、超时与回执、不重发 |
| 原生隔离场景 | 每项需求至少一条真实游戏路径，保留命令、日志、存档与哈希 |
| 回归 | 现有 Lua/Python 单元与原生 v3 套件（native / interactions）不回退 |
| 包一致性 | `package.py` 输出与源码逐字节一致，manifest 更新 |

## 10. 明确不在本需求范围

- 整场战役打通、出生/创建角色、长程任务记忆、远程 HTTP 部署（用户已说明流程缺口暂不处理）。
- 任意 Lua 执行、跳过原生规则的作弊式洗点（R1 已确认完全不提供）。
- 未适配的第三方自定义 UI 全自动处理；无人工恢复入口时仍需重载。
