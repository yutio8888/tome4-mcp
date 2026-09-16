# Round 10 实机测试报告 — 半身人 / 星月术士 / Insane / Roguelike

- 会话：`MCP_agent-ham-insane-10`（隔离实例，cheat=false），接口 `tome-insane10.sh` / `map-insane10.sh` / `mapjson-insane10.sh`
- 角色：Halfling / Celestial-Anorithil / Insane / Roguelike，起始 Trollmire 1 层
- **结局：死亡**（Roguelike 永久死亡）。L1，Trollmire 1 层 (38,15)，exp 19.8/29.7，死因：被 2 只 forest troll（rank2）+ wolf + large brown snake + 老鼠群围殴。
- 全程未重启游戏、未改文件、未 kill 进程。

## 一、游玩过程（时间线）

1. 出生在 Trollmire 1 层入口（0,6）。开 `Hymn of Shadows`（sustain，`action_ok:true`）。
2. 沿路探索，拾取并**装备** `scholar's pair of rough leather boots`（+3 spellpower，`equip` 成功）。
3. 遭遇战（全部走原生结算）：
   - wolf（L2）— Moonlight Ray 45 + Searing Light 34 → 击杀（首次用 `use_talent` 无 target 触发 `awaiting_native_input`，用 `respond` 补 actor 目标）。
   - giant brown ant、giant brown mouse、giant brown rat、giant white rat、giant crystal rat、poison ivy → 击杀。
   - **stone troll（L3 rank2，141 HP，armor 7，light resist 110%）**：Moonlight Ray（暗影）硬拼 + Knockback 被击退到角落；staff 近战仅 4/次（armor 7），靠 MR 45×3 + Twilight 充能击杀，掉落 troll intestine。
   - forest troll（rank2）×2、wolf：第一只被 MR 暴击 95 秒杀。
4. 加点：`spend_stat mag`×3（Mag 16→19）；`learn_talent T_MOONLIGHT_RAY`（L2，伤害 45→**63**，暴击 95）；`learn_talent T_HEALING_LIGHT`（generic，**单次治疗 103**）。再次 `learn_talent T_MOONLIGHT_RAY` 被原生拒绝（`native_message:"Prerequisites not met!"`，推测为等级上限）。
5. 拾取：`prismatic rough leather armour of temporal resistance`（**无法穿戴**：requirements str 10，而有效 Str = 10-3 = 7 → `native_rejected` + 日志 "not enough stat"）、`tattered paper scrap`（Lore，触发命令内弹窗）、gold 0.5（走过自动拾取）。
6. 死亡：在 (38,15) 开阔地被 2 forest troll + wolf + snake + 鼠群围攻，HP 从 57 → 23 连续掉血（当时 Healing Light 在 CD、负能量不足无法 MR），被 forest troll 打死。

**关于 exp**：wolf 一次只给 1.2 exp，经核对是原生数值（`Actor:worthExp` = level 2 × rank1 mult 0.6 × exp_worth 1 = 1.2），**不是 MCP 字段错误**。

## 二、Round10 修复项验证（结论：大部分成立）

| 验证项 | 结果 | 证据 |
| --- | --- | --- |
| `observe.sections` 接受 `effects/sustains/resources/stats` | ✅ | `{"observe":{"sections":["effects","sustains","resources","stats"]}}` 正常返回，含 `sustains:[{id:T_HYMN_OF_SHADOWS}]` |
| 未知域报 `invalid_sections`（不再整份 `{}`） | ✅ | `{"observe":{"sections":["bogus","effects"]}}` → `{"ok":false,"error":{"code":"invalid_sections",...}}` |
| 不存在的技能 id 报 `unknown_talent` | ✅ | `{"inspect":{"kind":"talent","id":"T_NOT_A_TALENT"}}` → `code":"unknown_talent"` |
| 并发命令用 `__rid` 关联 | ✅ | 3 条 observe 并发（actors / ground / effects+sustains），各自内容与自身 `__rid` 一一对应，无串包 |
| `inspect talent` 顶层 `range/radius/requires_target/current_costs/affordable/cooldown_remaining/readiness` + `target_geometry` | ✅ | 见证据 I |
| `inspect talent` 传 `target_id`/`x,y` 带 `distance`/`in_range` | ✅ | `x:100,y:100` → `distance:105, in_range:false` |
| `action_ok`（真正生效才算 true） | ✅（常规情况） | 冷却中/资源不足/不邻接 → `action_ok:false` + `native_rejected`/`target_not_adjacent`；成功 → `true` |
| `sheet` 新增 `gold`/`cooldowns` | ✅ | `gold:0.5`，`cooldowns:[{id,name,remaining}]` |
| 物品新增 `container_id` | ✅ | inventory/equipment 每项都有 `container_id` |
| 无弹窗时 `dismiss` → `ok:false` + `details.hint` | ✅ | `code":"no_pending_interaction"`，`details.hint` 存在 |

## 三、MCP 问题与新发现（按严重度）

### P1 — 死亡/非命令弹窗无法通过 MCP 关闭，文档字段与实际不符
- 死亡后 `observe` **没有顶层 `interaction` 字段**，弹窗只在 `dialogs` 里只读暴露：
  ```json
  {"phase":"terminal","actionable":false,"needs_reconnect":true,"control_lease":"released","control":"manual"}
  {"dialogs":[{"title":"You have died!","topmost":true,"widgets":[{"kind":"text","text":"Death in Tales of Maj'Eyal is usually permanent, ..."}]}]}
  ```
  `has interaction key: False`
- `{"dismiss":{"type":"option","option_id":"1"}}`：
  - 租约释放时 → `{"ok":false,"error":{"code":"control_lost",...}}`
  - 重新 `{"connect":"control"}` 之后 → `{"ok":false,"error":{"code":"no_pending_interaction",...,"details":{"hint":"no native popup is waiting; observe.interaction lists one when present"}}}`
  - `{"respond":{"type":"cancel"}}` → `{"ok":true,"result":{"error":"No pending interaction"}}`
- 后果：**死亡对话框没有任何可用的 MCP 交互路径**（无 `interaction` 可 dismiss，`dialogs` 又不可操作），会话只能靠外部 UI 结束。提示语 `observe.interaction lists one when present` 与实际字段名（`dialogs`）不一致，会误导调用方。

### P2 — `rest` 会以 `unsupported_interaction` 中断并释放租约，且触发原因不可见
```
{"status":"needs_input","code":"unsupported_interaction","action_ok":true,"world_tick_before":826,"world_tick_after":910}
事件: "Rested for 9 turns (stop reason: unsupported_interaction)."
```
之后 `observe` → `actionable:false, needs_reconnect:true, control_lease:"released", control:"manual"`，但 **`dialogs` 为空、也没有 `interaction`**：即“有一个 bridge 不支持的 UI”却完全无处可查。必须 `{"connect":"control"}` 才能恢复。建议：`needs_reconnect` 时在 observe 里带上原因/最近一次 unsupported 的 `native_ui` 名称。

### P2 — 死亡命令 `action_ok:true`，且死亡后动作返回非标准形状
- 致死那一击：`{"status":"failed","code":"terminal","action_ok":true}`（事件含 "…was dissected to death by a forest troll…"）。`action_ok:true` 与 `status:failed` 语义冲突（`action_ok` 实为“原生动作已执行”，并非“成功”），需要文档澄清或改名。
- 死亡后任何 action（如 `wait`）→ `{"ok":true,"result":{"not_ready":{ <完整 snapshot> }}}`，没有 `code`/`error`。调用方必须自己发现 `not_ready`，容易误判为成功。

### P2 — `observe.sections` 仍为未请求域返回空数组残桩
`{"observe":{"sections":["effects"]}}` 返回键：
```
['phase','actionable','needs_reconnect','control_lease','control','revision','world_tick','level_instance_id','player','effects','talents','history']
talents=[]
```
`talents` 未被请求（也不是 `effects` 的依赖）却仍返回 `[]`。与“省略的域不再返回 null 残桩”的说法不符（其它域确实被正确省略了，只有 `talents` 例外）。

### P3 — `character` 面板没有 `encumbrance` 字段
`sheet` / `inspect character self` 的键里没有 `encumbrance`（`'encumbrance' in sheet == False`）。源码 `ObservationDetails.lua:255` 里是 `if M.finite(p.max_encumber) then result.encumbrance=... end`，本角色 `max_encumber` 非有限值 → 字段被静默省略（既无 null 也无 reason）。本会话想核对装备负重时无法获得该信息。

### P3 — `target_geometry.selffire` 对本职业所有攻击技能恒为 `"unknown"`
`T_MOONLIGHT_RAY`（beam, direct_hit）、`T_SEARING_LIGHT`（ball radius 1），源码里都是 `target = function(self,t) return {...} end`，因此：
```json
{"range":10,"radius":null,"target_shape":"unknown","target_geometry":{"range":10,"selffire":"unknown","shape":"unknown","source":"static talent definition; a dynamic target function can change shape/radius/self-fire at cast time"}}
```
也就是说 round10 里“记录型目标的 selffire 默认值（ball/cone=true、beam/hit=false）”这条**在本职业上完全用不到**——所有伤害技能都是 unknown。这直接导致安全规则“unknown 时不要以自身/附近为 AoE 球心”生效，而实际上 Moonlight Ray 是 beam（selffire=false），Searing Light 的 `project` 用的是 `{type="hit"}`（仅单体），只是额外在地面留下 radius 1 的 light zone。建议：对 `direct_hit=true` 的技能至少给出 `selffire:false` 的静态兜底，或解析常见函数体。

### P3 — 错误响应形状不一致
三种并存：
1. 顶层错误信封：`{"ok":false,"error":{"code":"invalid_sections"|"unknown_talent"|"no_pending_interaction"|"control_lost",...}}`
2. `ok:true` + 内嵌错误：`{"ok":true,"result":{"error":{"code":"unknown_command_key","keys":["bogus"],"hint":"..."}}}`
3. `ok:true` + 内嵌字符串错误：`{"respond":{"type":"cancel"}}` → `{"ok":true,"result":{"error":"No pending interaction"}}`
另外只有 MCP 层 pydantic 校验错误带 `is_error:true`（如 `pickup` 缺 `item_id`、`move` 缺 `direction`），bridge 自己的错误都没这个字段。

### P3 — 其它易踩的 schema/字段细节
- `pickup` **必须** `item_id`：`{"action":{"type":"pickup"}}` → `mcp_request_rejected`，`action.pickup.item_id Field required`。
- `move` **只接受 `direction`**（1..9），传 `x/y` 直接 `extra_forbidden`。
- `respond` 目标形状是 `{"respond":{"type":"actor","target_id":"<id>"}}`；用 `actor_id` 或 `{"actor":{"target_id":...}}` 都会被忽略并报 `answer.actor.target_id Field required`（推荐改用 `action.use_talent.target_id` 预填，可完全免去交互）。
- `mapjson.cells` 里**不标玩家**（玩家格的 char 是地形 `.`），只有 `rows` 字符串里有 `@`；靠 cells 找玩家会拿到 `None`。
- `walk` 的停止条目没有 `status`/`code`，只有 `stop_reason`：
  ```json
  {"enemies":[{"name":"wolf","x":6,"y":24}],"interrupted":{...},"moved_steps":0,"player":{...},"stop_on_enemy":"adjacent","stop_reason":"blocked_on_enemy"}
  ```
  且 `walk` 返回**每步一条**累计条目，长序列响应非常冗长（一次 13 步 ≈ 13 份 snapshot）。
- **纹身/注入（infusion）无法从任何 collection 枚举**：`inventory`/`equipment` 都不含它们，只能从 `observe.talents` 拿到 `T_INFUSION:_*` 并用 `use_talent` 施放（实测 `T_INFUSION:_HEALING_3` 成功，治疗 50；`T_HEALING_LIGHT` 治疗 103）。
- `attack` 目标 id 会变：同一只 wolf 的 id 由 `actor-5508` 变成 `actor-5506`，写死 id 会得到 `target_lost`（本条与既有说明一致，实测确认）。

## 四、原始 JSON 证据摘要

见 `/tmp/round10-evidence.txt`（关键原文）以及本会话的所有请求/响应；下面内联关键片段：

```json
// 死亡弹窗（observe，注意没有 interaction）
{"phase":"terminal","actionable":false,"needs_reconnect":true,"control_lease":"released","control":"manual",
 "dialogs":[{"title":"You have died!","topmost":true,"widgets":[{"kind":"text","text":"Death in Tales of Maj'Eyal is usually permanent, ..."}]}]}

// dismiss（有租约）
{"ok":false,"error":{"code":"control_lost","message":"control lost","accepted":null,"uncertain":false}}
// dismiss（重连后）
{"ok":false,"error":{"code":"no_pending_interaction","message":"no pending interaction","details":{"hint":"no native popup is waiting; observe.interaction lists one when present"}}}
// respond cancel
{"ok":true,"result":{"error":"No pending interaction"}}

// 死亡后 wait
{"ok":true,"result":{"not_ready":{"phase":"terminal","actionable":false,"needs_reconnect":true,...}}}

// rest 中断
{"status":"needs_input","code":"unsupported_interaction","action_ok":true,"world_tick_before":826,"world_tick_after":910}
"Rested for 9 turns (stop reason: unsupported_interaction)."

// sections 残桩
{"observe":{"sections":["effects"]}} -> keys 含 "talents": []

// Command Talent 预填（顺利路径，推荐）
{"action":{"type":"use_talent","talent_id":"T_MOONLIGHT_RAY","target_id":"<actor>"}}
-> {"status":"completed","code":"action_complete","action_ok":true}
   事件: "casts Moonlight Ray." / "hits Forest troll for 63 darkness damage."（暴击 95）
```

## 五、做得好的地方（值得保留）

- `use_talent` 带 `target_id` 预填可完全绕开 `awaiting_native_input`，体验显著优于裸施法。
- `inspect actor` 的 `base_combat/base_resists/base_weapon/speed` 与游戏定义逐项吻合（wolf dam 5.7 精确匹配 `levelup(5,1,0.7)`），可直接用于战斗决策。
- `effects` / `sustains` / `resources` 分域读取稳定，`resources.negative/positive` 数值与原生扣费/回复一致。
- `list progression_categories` / `progression_talents`（含 `point_cost.pool`、`requirements.next_raw_level`）足以规划加点，`learn_talent`/`spend_stat` 全部按原生规则生效。
- 命令内弹窗（Lore）走 `{"respond":{"type":"option","option_id":"interaction-3:option-1"}}` 处理正常，`response_receipt.state:"applied"`。
