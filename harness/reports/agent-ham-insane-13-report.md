# 实机测试报告 — round10 测试对话 13（agent-ham-insane-13）

- **角色**：半身人 / 星月术士（Celestial-Anorithil）/ Insane / Roguelike，起始 1 级
- **区域**：Trollmire 第 1 层（由死亡日志确认）
- **结局**：**死亡**，2 级，位置 (64,7)（下一层楼梯 `>` 旁），被森林巨魔 + 石巨魔 + 白虫群围杀
- **测试时长**：约 1 局（从出生到死亡）

## 一、游玩经过（简）

- 出生在 Trollmire 1 层 `(0,25)` 的 worldmap 出口，向西/北探索，发现 `=`（old road）与 `;`（flower）都是可通行装饰。
- 早期清怪：poison ivy、2× wolf、3× forest troll、black jelly、copperhead snake、large white snake、large brown snake、giant grey mouse、giant white rat，以及多个 white worm mass（会 `Multiply` 分裂）。
- 加点：mag 16→22；技能 MR 3、Searing Light 2、Healing Light 1→2；sustain `T_HYMN_OF_SHADOWS`（+移速/施法速度，reserve negative 20）。
- 战法：`use_talent` + `target_id` 预填，`Moonlight Ray`（beam，穿透，cd3）主输出，`Searing Light`（ball r1，会留下每回合 23 光的 `light area effect`）清群。全程用 `target_geometry.selffire` 判断自伤，自伤球（selffire=true）只在距离 ≥2 时使用。
- 1 级时用 `walk` 逐段揭示地图，最终用自写的前沿探索脚本找到 `>` 楼梯 `(64,7)`。
- 死亡：为抄近路直接 `walk ... stop_on_enemy:"never"` 冲到楼梯，被 forest troll / stone troll 连续重击（73.6→34.6→-7.1）阵亡。

## 二、MCP 问题与验证（含原始 JSON）

### 通过验证（无问题）
- `observe.sections`：`effects/sustains/resources/stats` 合法；省略域不返回 null 残桩；未知域 → `invalid_sections`。
  ```json
  {"ok":false,"error":{"code":"invalid_sections","message":"invalid sections"}}
  ```
- `inspect(kind="talent")`：顶层 `range/radius/target_shape/requires_target/current_costs/affordable/cooldown_remaining/readiness` + `target_geometry` 均存在；未知 id → `unknown_talent`。
- `action_ok` 一致：`failed`→false（`native_rejected`/`blocked`/`not_ready`/`terminal`），`completed`→true。
- 拒绝都带 `native_message` / `hint`，例如：
  - 装备被拒：`"MCP_agent-ham-insane-13 can not wear (main armor): ...rough leather armour of acid resistance... (not enough stat)."`（角色 str=7 < 需求 10）
  - 技能冷却：`"Searing Light is still on cooldown for 2 turns."`
  - 走不动：`{"status":"failed","code":"blocked","hint":"the move did not change position and spent no energy"}`（(61,13) 是 tree）
  - 终局：`{"status":"failed","code":"terminal","action_ok":false}`
- `character` 面板：`gold`、`cooldowns`、`encumbrance.items_total`(数值) 均有；物品 `container_id` 有。
- `set_sustain`：`T_HYMN_OF_SHADOWS` 开启后 negative max 50→30（reserve 20），`sustains` 出现该技能；死亡后自动掉失。
- `learn_talent` / `spend_stat`：`progression_applied` + `new_value`/`previous_value`/`point_pool`；前置不满足 → `native_progression_rejected` + `"Prerequisites not met!"`。
- `list` progression_talents：`filter.category_id` 生效；缺 filter → `invalid_filter` 且给出 `details.allowed_filters`（很友好）。
- `mapjson.exits`：在范围内正确给出 `{"x":64,"y":7,"name":"way to the next level","char":">"}`；出生点给 `<`。
- `status` compact / `wait` 在非 ready 时：`not_ready` + `details.hint`。
- 释放原因：死亡后 `release_reason:"terminal"` + `release_hint`；`needs_reconnect:true`；`{"connect":"control"}` 可重新拿到租约。

### 问题 1（较重要）：死亡弹窗既没有 `interaction`，`dismiss` 也关不掉
死亡后 `observe` 顶层 `interaction` 为 `null`，只有 `dialogs`；且 widget 只有 `text`，没有任何 option/button，因此拿不到任何 `option_id`：
```json
{"phase":"terminal","actionable":false,"control_lease":"held","needs_reconnect":true,
 "interaction":null,
 "dialogs":[{"title":"You have died!","topmost":true,
   "widgets":[{"kind":"text","text":"Death in Tales of Maj'Eyal is usually permanent, ... to survive in the wilds!\n"}]}]}
```
重新 `connect` 后按文档用 `dismiss` 兜底：返回成功，
```json
{"dismissed":true,"scope":"native_dialog"}
```
**但随后每一次 `observe`，`dialogs` 里 "You have died!" 仍然存在**（重复 dismiss 也是 `dismissed:true` 且弹窗不消失）。即：`dismiss` 虚报成功，且没有任何通道能选择死亡菜单项。
（另：未 `connect` 前 dismiss 返回 `{"ok":false,"error":{"code":"control_lost"}}`，这条符合预期。）

**影响**：agent 无法通过 MCP 处理死亡菜单（复活/放弃/导出角色），只能靠外部重启。
**建议**：死亡 notice 应暴露为顶层 `interaction` 并给出可选项；或让 `dismiss` 在无法关闭时返回 `ok:false`（而不是 `dismissed:true`）。

### 问题 2：`walk` 在已有可见敌人时直接 `moved_steps:0`
`stop_on_enemy:"visible"` 下，只要屏幕内已有敌人，`walk` 立刻以 0 步结束并报 `blocked_on_enemy`（其实并没有被墙挡住）：
```
d=8 moved=0 blocked_on_enemy -> (35,12)
d=6 moved=0 blocked_on_enemy -> (35,12)
```
`stop_on_enemy:"adjacent"` 在有相邻敌人时同样 0 步。结果是"有敌人时无法用 walk 移动/逃跑"，只能用单步 `move`。
**建议**：把 `stop_reason` 区分成 `enemy_visible`/`enemy_adjacent`，或在无路可走时才叫 `blocked`；更理想的是照常走但每步前检查。

### 问题 3：`Searing Light` 静态几何与运行时不一致（`direct_hit` 却 selffire=true）
`inspect(kind="talent", id="T_SEARING_LIGHT")` 静态给：
```json
{"direct_hit":true,"damage_scope":"single","radius":1,
 "target_geometry":{"damage_scope":"single","radius":1,"residual_area_radius":1,"selffire":false,...}}
```
实际施放返回：
```json
{"target_geometry":{"damage_scope":"area","radius":1,"range":7,"residual_area_radius":1,"selffire":true,"shape":"ball"}}
```
round13 文档说 `direct_hit` 技能 `target_geometry.selffire:false`，但 Searing Light 是 `direct_hit:true` 而运行时 `selffire:true`，紧贴施放会打到自己（球 r1）。静态 `damage_scope:"single"` 也不对（实为 area/ball）。
**建议**：`direct_hit` 不能作为 `selffire` 的依据；静态几何对函数型 target 应给 `unknown`，别给 `single/false` 这种会误导的确定值。
（正面：`residual_area_radius:1` 对应真实的持续 `light area effect`，每回合对范围内敌人造成 23 光伤害——这个字段很准很有用。）

### 问题 4：`observe` 不暴露当前区域名/层数
只能从死亡日志 `"... on level 1 of Trollmire."` 才知道区域。`level_instance_id` 给的是 `level-2`（引擎层实例号），容易被误读为"Trollmire 第 2 层"。
**建议**：`observe` 增加 `zone`（名称）与 `zone_depth`。

### 问题 5：`mapjson.legend` 不全
legend 只有 `{"?":"unknown","@":"player","A":"perceived actor"}`，而实际地形 `#`(tree，阻挡)、`.`(grass)、`;`(flower)、`=`(old road) 都不在 legend 里（虽然 `cells[].name` 有）。

### 问题 6（可能为设计使然，仅记录）：连续 `move` 的能量/tick 上报
同向连续两次 `move`：
```json
cmd-108 {"type":"move","direction":4} -> {"action_ok":true,"energy_spent":0,"world_tick_before":801,"world_tick_after":801} pos(30,13)->(29,13)
cmd-109 {"type":"move","direction":4} -> {"action_ok":true,"energy_spent":905.34,"world_tick_before":801,"world_tick_after":811} pos->(28,13)
```
第一次位置变了却 `energy_spent:0` 且 world_tick 不变（前一次是 `use_talent` energy_spent≈970，疑似剩余能量结转）。看起来像能量模型的表现，但"0 能量却成功移动"对上层判断回合推进不友好。

### 其它观察
- `walk` 的返回是数组，元素里没有 `action_ok`（只有 `status`/`code`），与单动作返回结构不一致（阻塞时 `{"status":"failed","code":"blocked"}`）。
- 未验证项：换层（死在楼梯上，没来得及 `change_level`）、`key` 通道、`abandon`、戒指装备、`unlearn_talent`、`T_COMMAND_STAFF` 拒绝。

## 三、结论
整体 bridge 很稳：observe/act/inspect/list/progression/map 字段准确、错误结构化、`action_ok` 语义一致、`native_message`/`hint` 到位。主要待修是**死亡菜单无法通过 MCP 处理（interaction 缺失 + dismiss 虚报成功）**，其次是 `walk` 的 `stop_on_enemy` 语义与 `Searing Light` 静态几何误导。角色最终在 Trollmire 1 层为抄近路冲楼梯而被双巨魔+虫群击杀（Insane，正常）。
