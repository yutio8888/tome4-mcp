# ToME MCP 接口返回字段清单

日期：2026-09-15。基线：Bridge / Python server **0.8.0**、协议 **3**（v1/v2 已在测试阶段移除）。本文由当前源码提取，用于审阅命名与冗余；不是新契约，字段语义以 [v3 契约](tome-mcp-v3-talent-query.md) 为准。

标记：`?` 条件出现。所有字段均属于协议 3。

## 1. 统一信封

所有 MCP 工具返回 `ToolReply`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `ok` | bool | 工具请求是否处理成功；业务状态另看 `result.status` |
| `result` | object? | 成功时的业务数据 |
| `error` | object? | 失败时的错误 |

`error`：`code`、`message`、`uncertain`、`command_id?`、`response_id?`。
（游戏内部 TCP 信封 `{v,id,ok,result,error}` 不暴露给 MCP 客户端。）

## 2. `tome.connect` / `tome.connect(mode="observe")`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `session_id` | string | 本次游戏加载的会话 |
| `control_token` | string\|null | 控制租约；observe 模式为 null |
| `revision` | int | 当前版本计数 |
| `mode` | `control`\|`observe` | 连接模式 |
| `protocol_version` | 3 | 协议版本（固定） |
| `capabilities` | object | 见 §3 |
| `snapshot` | object | 同 `tome.observe`（§4） |

## 3. `capabilities`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `protocol` | int | 3 |
| `actions` | string[] | 可用动作：`move`、`wait`、`attack`、`use_talent`、`change_level`、`rest`、`spend_stat`、`learn_talent`、`learn_category`、`unlearn_talent`、`pickup`、`equip`、`unequip`、`set_sustain`、`use_item` |
| `connection_modes` | string[] | `["control","observe"]` |
| `talents` | string[] | 当前可尝试原生的技能 ID（mode 允许的已学技能） |
| `talent_execution` | string | `native_interactive` \| `legacy_adapters` |
| `interactions` | string[]? |`target.grid`、`target.direction`、`dialog.confirm`、`dialog.choice`、`dialog.notice`、`inventory.select` |
| `native_tasks` | string[]? |`["task.rest"]` |
| `multi_step` | true? | |
| `unknown_interaction` | string? |`manual_handoff` |
| `limits` | object? |`{responses_per_command, options_per_page}` |
| `native_compatibility` | object? |`{compatible, reason, providers}` |
| `talent_query` | true? | v3 |
| `talent_prefill` | string[]? | v3：`["actor","position"]` |
| `observation` | string | `player` |
| `max_radius` | int | 12 |
| `max_commands` | int | 命令历史上限 |
| `max_rest_turns` | int | 1000 |
| `compact_responses` | bool | 支持 `include_map=false` |
| `event_cursor` | bool | 支持 `events_after` |
| `inventory_read` | bool | |
| `ground_items_read` | bool | |
| `progression_read` | bool | |
| `inspect_kinds` | string[] | `["actor","talent","progression","item"]` |

## 4. `tome.observe` / 快照 `snapshot`

顶层：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `session_id` | string | |
| `level_instance_id` | string | 场景实例；换层后变化 |
| `revision` | int | |
| `phase` | `ready`\|`settling`\|`needs_input`\|`terminal`\|`unavailable` | 运行阶段 |
| `control_source` | `remote`\|`battle_companion`\|`manual` | 当前控制来源 |
| `battle_companion` | object? | 安装了 Battle Companion 时的只读摘要 |
| `world_tick` | int | `game.turn` |
| `player` | object | §4.1 |
| `map` | object\|null | §4.2；`include_map=false` 时为 null |
| `actors` | object[] | §4.3 |
| `talents` | object[] | §4.4 |
| `ground` | object | §4.5 |
| `scene` | object | `{zone_id, zone_name, level}` |
| `dialogs` | object[] | §4.6 |
| `dialogs_truncated` | bool? | |
| `events` | object | §4.7 |
| `pending_command` | object? | 有活动命令时：`{command_id,status,input_owner,execution_released,interaction,native_task}` |
| `truncated` | bool? | 任一列表、地图名称或整体响应被裁剪 |

`battle_companion`：`state`、`code?`、`message?`、`actions`。

### 4.1 `player`

身份（来自 actor 摘要）：`id`、`name`、`x`、`y`、`life`、`max_life`、`faction`、`type`、`subtype`、`level`、`rank`。

玩家成长与状态（`Details.player`）：

| 字段 | 说明 |
| --- | --- |
| `level`、`exp`、`exp_next`、`exp_scope` | 等级、当前经验、升级阈值、阈值语义 |
| `unused_stats`、`unused_talents`、`unused_generics`、`unused_talents_types`、`unused_prodigies` | 各点池 |
| `descriptor` | `{race, subrace, class, subclass, class_evolution, sex, difficulty}` |
| `stats` | `{str:{base,bonus}, dex, mag, wil, cun, con}` |
| `stats_are_raw` | true |
| `life_regen`、`regeneration_is_raw` | |
| `die_at` | 死亡阈值 |
| `energy` | 当前行动能量 |
| `resources` | `{air,equilibrium,hate,mana,negative,paradox,positive,psi,stamina,vim}` 各自 `{value,min,max,regen}` |
| `effects`、`effects_truncated`、`effect_duration_is_raw` | `[{id,name,duration,status,type}]` |
| `inventory`、`equipment`、`inventory_truncated`、`equipment_truncated`、`inventory_scope` | §4.8 |

### 4.2 `map`

`x`、`y`、`width`、`height`、`rows`（字符行数组）、`cells`、`radius`、`window{x_min,y_min,x_max,y_max}`、`legend`、`memory_scope`、`merge_scope`、`block_scope`、`names_truncated?`。

`cells[]`：`x`、`y`、`visible`、`known`、`char`，已观察时附地形字段：`name`、`block_status`（`blocked`/`passable`/`unknown`）、`blocked?`、`door?`、`can_open?`、`confirmation_required?`、`opening_blocked?`、`is_exit?`。

### 4.3 `actors[]`（快照内）

`id`、`name`、`x`、`y`、`life`、`max_life`、`faction`、`type`、`subtype`、`level`、`rank`。
（更详细的 `speed`、`effects`、`base_combat`、`base_weapon`、`base_resists` 只在 `tome.inspect(kind="actor")` 中出现，见 §5.1。）

### 4.4 `talents[]`

`id`、`name`、`level`、`cooldown`、`mode`、`supported`、`unsupported_reason?`、`target`、`action_adapter?`、`instant`、`description`；
另有 `activation{admitted,reason?,entrypoint,interaction_coverage}`、`sustained_active`。

### 4.5 `ground`

`items[]`、`truncated`、`radius`、`pickup_scope`、`scope`。
`items[]` = 物品字段（§4.8）+ `location="ground"`、`x`、`y`、`underfoot`、`pile_size`、`pile_truncated`。

### 4.6 `dialogs[]`

`title`、`topmost`、`widgets[{text,kind}]`、`widgets_truncated?`。

### 4.7 `events`

`source`、`entries[]`、`head_cursor`、`oldest_cursor`、`cursor`、`gap`、`cursor_ahead`、`has_more`、`semantics`。
`entries[]`：`cursor`、`op`（`append`/`update`/`remove`/`reset`）、`line_id`、`text`、`observed_world_tick`、`text_truncated`、`reason?`。

### 4.8 物品对象（库存 / 装备 / 地面 / inspect item）

`id`、`identified`、`count`、`name`、`name_is_raw`；
已鉴定时附：`type`、`subtype`、`add_name`、`encumbrance`、`encumbrance_is_per_item`、`combat{...}`、`wielder{...}`、`combat_values_are_raw`、`equipment_slot`、`offslot`、`material_level`、`requirements{required_level,stats,talents[],flags[],unknown?,truncated?}`、`requirements_are_raw`；
附：`activation{present,runtime_checked,power?,max_power?,recharge_per_turn?,talent_cooldown?,use_no_wear}`。
库存/装备内额外：`inventory_id`、`slot`、`container`、`equipped`、`transmogrification_pending`。

## 5. `tome.inspect`

### 5.1 `kind="actor"`

= §4.3 基础字段 + 详细字段：
`type`、`subtype`、`level`、`rank`、`speed{global_speed,global_speed_base,global_speed_add,movement_speed,combat_physspeed,combat_spellspeed,combat_mindspeed}`、`speed_values_are_raw`、`effects[]`、`effects_truncated`、`effect_duration_is_raw`、`base_combat{...}`、`base_weapon{...}`、`base_resists{}`、`resists_truncated`、`combat_values_are_raw`、`combat_scope`；若目标是玩家，再叠加 §4.1 的成长/资源/背包字段。

### 5.2 `kind="talent"`

= §4.4 + v3 的 `query`：

| 字段 | 说明 |
| --- | --- |
| `range` | 数值或 `"unknown"` |
| `requires_target` | bool 或 `"unknown"` |
| `target_type` | 字符串或 `"unknown"` |
| `cooldown_remaining` | 数值或 `"unknown"` |
| `current_costs` | **当前实时消耗** `{resource:number}`；未知项 `"unknown"` |
| `costs_complete` | bool，`current_costs` 是否全部可知 |
| `base_costs` | 存储的基础消耗 |
| `affordable` | bool 或 `"unknown"` |
| `distance`、`in_range` | 传入目标时给出 |
| `readiness`、`readiness_reason` | `available`/`blocked`/`unknown` + 原因 |
| `prefill_supported`、`prefill_modes` | `["actor","position"]` |
| `query_is_advisory` | true |

### 5.3 `kind="progression"`（id=`player`）

顶层：`points{stats,class,generic,category,prodigy}`、`stats[]`、`categories[]`、`readiness_is_advisory`、`scope`、`execution_scope`、`respec{unlearnable[],scope}`、`categories_truncated?`、`talents_truncated?`、`truncated?`、`readiness_reason?`。

- `stats[]`：`stat`、`name`、`base`、`bonus`、`effective`、`point_cost{pool,amount}`、`supported`、`readiness`、`readiness_reason?`、`level_limit?`、`absolute_limit?`。
- `categories[]`：`id`、`name`、`known`、`generic`、`mastery_base`、`improvements_used`、`minimum_level`、`point_cost{pool,amount}`、`supported`、`talents[]`、`operation`、`mastery_increase?`、`readiness`、`readiness_reason?`、`talents_truncated?`。
- `categories[].talents[]`：`id`、`name`、`raw_level`、`max_points`、`mode`、`point_cost{pool,amount}`、`supported`、`description_status`、`requirements{next_raw_level,stats,category_known,lower_talents_required,lower_talents_known,required_level?,status}`、`readiness`、`readiness_reason?`。
- `respec.unlearnable[]`：`id`、`pool`、`position`、`available`、`reason?`。

### 5.4 `kind="item"`

= §4.8 + `location`（`inventory`/`equipped`/`ground`）、`inventory_id?`、`slot?`、`equipped?`、`container?`、`transmogrification_pending?`（地面时用 `x`/`y`/`underfoot`/`pile_*`）。

## 6. `tome.act` / `tome.status` / `tome.respond` 的命令记录

| 字段 | 说明 |
| --- | --- |
| `command_id` | 命令标识 |
| `status` | `queued`/`executing`/`settling`/`awaiting_input`/`running_native_task`/`completed`/`failed`/`cancelled`/`needs_input` |
| `code` | 结果码（如 `action_complete`、`native_rejected`、`target_out_of_range`） |
| `energy_spent` | 本次动作实际消耗能量 |
| `native_return` | 原生返回值（可用时） |
| `world_tick_before`、`world_tick_after` | |
| `revision_before`、`revision_after` | |
| `snapshot` | 结果快照（§4） |
| `interruption?` | 中断原因 |
| `uncertain?` | 原生错误后结果不确定 |
| `turns_executed?`、`max_turns?` | rest/任务进度 |
| `stop_reason?`、`native_message?` | |
| `missing?` | 结构化未满足条目：progression 的 `{kind='stat'|'level'|'talent'|'special'}`，或 `use_talent` 被自身冷却原生拒绝时的 `{kind='cooldown',talent,remaining,required=0}`（P3-2；不扩宽 schema） |
| `hint?` | 人类可读提示（code 仍为权威）；冷却拒绝附带 `talent on cooldown; wait for the listed turns before retrying` |
| `level_changed?` | change_level 成功 |
| `points_spent?`、`points_returned?`、`point_pool?`、`previous_value?`、`new_value?` | 成长/洗点 |
| （协议 3） | `revision`、`input_owner`、`execution_released`、`energy_spent_complete`、`interaction?`、`native_task?`、`response_receipt?` |
| Python 轮询 | `wait_expired?`（等待窗口到期） |

`response_receipt`：`{response_id, interaction_id, state(queued/applied/rejected), code?}`。

`interaction`：`interaction_id`、`sequence`、`kind`、`revision`、`prompt?`、`text?`、`answer_types[]`、`consumed`、`native_ui?`；
目标类另有 `origin{x,y}`、`range?`、`radius?`、`candidate_actor_ids[]`、`candidates_truncated?`；
非目标类另有 `options[{option_id,label,disabled}]`、`options_offset`、`options_total`、`options_next?`。

`native_task`：`task_id`、`kind`、`status`、`turns_executed`、`native_max_turns?`、`automation_max_turns`、`stop_reason?`、`native_message?`。

## 6.1 `tome.policy` / `tome.policy_log`（自动战斗）

`policy_log` 的 `status.log`（及 `policy status`）报**保留 ring** 的 `count`/`first_seq`/`last_seq`/
`total`/`limit`，以及**实际返回窗口**的 `window={count,first_seq,last_seq}` 与 `semantics` 说明
（早期条目通过 `tome.policy` `replay` 游标分页读取）。`window.first_seq`/`last_seq` 是**返回事件中最旧/
最新的 seq**，与返回顺序无关：`log.events` 为最新优先的有界 tail，`replay` 为旧→新的分页追踪，二者
报出一致的窗口（`first_seq <= last_seq`）。`total` 是累计写入的事件数，ring 淘汰后可以大于 `count`。

`status`：`mode` 含已校验的调度值 `on_no_enemy`、`on_low_hp`、`on_new_enemy='pause'|'continue'`
（`on_new_enemy` 由 preset/mode 选择，非插件级门禁）。

policy 决策事件的 `denied` 条目可携带原生拒绝的结构化详情：`missing`（如
`[{kind='cooldown',talent,remaining,required=0}]`）、`hint`、`native_message`，与 `tome.act` 命令路径
一致（有界且类型守卫）。

## 7. `tome.stop`

`stopped: true`、`snapshot`（§4）。

## 8. 字段命名审阅与本次调整

MCP 仍处测试阶段，允许破坏兼容；下列命名问题已在本轮统一（见提交记录）。

| # | 原问题 | 已采用的命名 |
| --- | --- | --- |
| 1 | talent 用 `readiness_reason`，progression 用 `reason` | 统一为 `readiness_reason` |
| 2 | `costs` 作用域语义不同 | v3 实时值改 `current_costs`，基础值统一 `base_costs`；移除 `costs_are_final` |
| 3 | “原始/最终”标记不统一 | 统一为正向 `*_is_raw` / `*_are_raw`（`combat_values_are_raw`、`requirements_are_raw`、`speed_values_are_raw`）；移除 `=false` 型标记 |
| 4 | 截断标记分散 | 顶层新增 `truncated` 汇总（任一列表/地图/响应被裁剪），具体 `*_truncated` 保留 |
| 5 | 省略地图双信号 | 只保留 `map=null`，移除 `map_omitted` |
| 6 | 需求对象 `level` 多义 | 改为 `required_level` |
| 7 | `cost{pool,amount}` vs `costs{资源}` | progression 统一为 `point_cost{pool,amount}` |
| 8 | `phase` 与 `status` 概念重叠 | 保留字段，文档明确：`phase` 是运行阶段，`status` 是命令生命周期 |
| 9 | `mode` 与 `control` 易混 | 快照改 `control_source`（连接仍用 `mode`） |
| 10 | `unlearn_talent` 未列入能力 | 已加入 `capabilities.actions` |

已删除的旧字段：`costs_are_final`、`query_is_final`、`readiness_is_final`、`map_omitted`、`observation_truncated`（现为 `truncated`）。v1/v2 协议已在测试阶段移除。
