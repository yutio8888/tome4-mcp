# ToME4 MCP 实机测试报告 — 第六轮

- 角色：`MCP_agent-ham-insane-06`（半身人 / 星月术士 Anorithil / Insane / Roguelike，cheat=false）
- 场景：trollmire `level-2`，起始 (0,18)
- 结果：**未死亡，但整局在第 70 回合被硬冻结（桥 + 游戏都卡死），测试提前结束**
- 时长：约 6 分钟（03:36–03:42）
- 最终状态：Lv1、HP 75.65/94、exp 1.80/29.70、(3,20)、world_tick=70（此后永不再涨）
- 结束原因：`use_talent T_COMMAND_STAFF` 打开原生 Chat → 依法 `respond` 后触发游戏内 Lua Error → bridge 进入 `phase=unavailable / control=manual` 的 native-error 隔离态，**且没有任何恢复通道**

> 本次未修改任何仓库/游戏文件，未重启/kill 进程。所有 JSON 均为 `tome-insane6.sh` / `map-insane6.sh` / `mapjson-insane6.sh`（经 `send.sh`）的原始返回。

---

## 1. 时间线（关键节点）

| 时刻 | 事件 |
| --- | --- |
| 03:36:5x | observe：ready，1 级，94 HP，视野内 1 只 large white snake，脚下是 worldmap 出口 |
| 03:37:0x | **`{"set_sustain":...}` / `{"move":...}` 被静默忽略**（见 §2.1），改用 `{"action":{...}}` 后恢复 |
| 03:37:2x | `set_sustain T_HYMN_OF_PERSEVERANCE` 成功（`negative.max` 50→30，原生） |
| 03:37:3x | 向南推进；walk [6,6,6] 到 (3,19)，再下到 (3,20) |
| 03:38:0x | 视野内同时出现 hornet swarm(3,19,16HP)/large white snake(2,20)/giant brown ant(4,21)/forest troll(5,21,125HP) |
| 03:38:1x | Moonlight Ray 击杀 hornet swarm（43 darkness，beam 穿透），exp +1.8 |
| 03:38:2x | Moonlight Ray 被 cooldown 正确拒绝（`native_rejected`，"still on cooldown for 2 turns"） |
| 03:38:3x | Searing Light 打 forest troll 35 直击 + 17 光域，ant 17；被蛇 6+6、蚁 5 反击 → HP 75.65 |
| 03:39:0x | 尝试 **`use_talent T_COMMAND_STAFF`** → 原生 Chat `dialog.choice`（见 §2.2），此后不可收拾 |
| 03:39:1x | respond `[Star]`（补上 `type` 后才成功）→ interaction-2 |
| 03:39:2x | respond `[Light]` → **`native_talent_error`** → 永久隔离，游戏同时冻结 |
| 03:39–03:42 | 尝试 connect/stop/key 全部无效；只读通道仍可用；world_tick 一直 70 |

击杀：hornet swarm ×1。造成伤害：Moonlight Ray 43；Searing Light 35+17+17。**全程未到 2 级，未加点、未拾取、未换层。**

---

## 2. MCP 问题（按严重度）

### 2.1【P0·易踩】未知顶层命令键被静默当成 observe，返回 `ok:true` 且无任何提示

提示词把动作写成 `move(dir 7/8/9…)`、`set_sustain{...}`，但没有说明**必须包一层 `{"action":{...}}`**（控制台 `agent-play.py` 只认 `action/respond/inspect/walk/key/connect/stop/quit/map/list/observe`，其余落进 `else` → 直接 observe）。于是：

```
03:37:07 CMD {"set_sustain":{"talent_id":"T_HYMN_OF_PERSEVERANCE","enabled":true}}
03:37:23 CMD {"use_talent":{"talent_id":"T_HYMN_OF_PERSEVERANCE"}}
03:37:29 CMD {"move":{"dir":8}}
03:37:39 CMD {"move":{"direction":8}}
```
四条命令的返回全是"裸快照"：`ok:true`、`revision` 前后都是 **347**、`world_tick` 0、**没有 `status`/`code`/`energy_spent`**，玩家位置不变：

```json
{"ok":true,"result":{"phase":"ready","actionable":true,"control_lease":"held","revision":347,"world_tick":0,
 "player":{"x":0,"y":18,"life":94}, ..., "pending_command":null}}
```
正确写法（`{"action":{"type":"move","direction":8}}`）立刻返回 `{"status":"completed","code":"action_complete","energy_spent":1000}`。

**危害**：agent 会以为"命令成功但游戏没动"，反复重试、误判游戏逻辑（我前 4 个命令全部空转）。**建议**：控制台对未知顶层键返回 `{"ok":false,"error":"unknown_command_key: ..."}`（或至少把命令原样回显）；提示词也请给出 `{"action":{...}}` 的完整示例。

### 2.2【P0·致命】`T_COMMAND_STAFF` 原生对话在正常 respond 路径上触发 native Lua Error，bridge 单向隔离且游戏一起冻结

#### (a) 交互被正确建模（这部分没问题）
```json
{"accepted":true,"code":"awaiting_native_input","command_id":"cmd-13","execution_released":false,
 "input_owner":"remote","status":"awaiting_input","snapshot_scope":"live",
 "interaction":{"answer_types":["option"],"kind":"dialog.choice","native_ui":"Chat",
   "interaction_id":"interaction-1","text":"Call on which aspect of the staff?",
   "options":[{"label":"[Mage]","option_id":"interaction-1:option-1"},
              {"label":"[Star]","option_id":"interaction-1:option-2"},
              {"label":"[Vile]","option_id":"interaction-1:option-3"},
              {"label":"Never mind.","option_id":"interaction-1:option-4"}]}}
```

#### (b) 失败 respond 不再丢 interaction（round3 问题 1 已修复，记录为通过项）
我用**缺 `type`** 的 answer 试了一次：
```json
{"ok":true,"result":{"_error":{"code":"mcp_request_rejected","message":
 "... respondArguments\nanswer\n  Unable to extract tag using discriminator 'type' ..."}}}
```
之后再 observe，`pending_command.interaction` 仍是 interaction-1，重发合法 answer 即成功。**符合预期，感谢修复。**

#### (c) 合法 answer 触发 native Lua Error
```json
{"accepted":true,"code":"native_talent_error","command_id":"cmd-13","energy_spent":0,
 "execution_released":false,"input_owner":"manual","interruption":"native_talent_error",
 "status":"failed","uncertain":true,"world_tick_before":70,"world_tick_after":70,
 "response_receipt":{"interaction_id":"interaction-2","response_id":"resp-00017","state":"applied"},
 "native_message":"...s/mcp-bridge/superload/engine/interface/ActorTalents.lua:56:
   /data/talents/misc/objects.lua:184: calling 'talentDialog' on bad self (table expected, got boolean)
   stack traceback:
     [C]: in function 'talentDialog'
     /data/talents/misc/objects.lua:184: in function </data/talents/misc/objects.lua:168>
     [C]: in function 'xpcall'
     ...s/mcp-bridge/superload/engine/interface/ActorTalents.lua:52: in function <...:39>
     [C]: in function 'xpcall'
     /mod/mcp_br..."}
```
游戏侧日志一一对应（`tmp/tome-mcp-validation/sessions/agent-ham-insane-06/game.log`）：
```
2640 [CHAT] Loading...	command-staff
2641 Just started the chat, and there's no o.factory_settings
2643 [CHAT] loaded	element_starstaff
2661 [CHAT] selected	[Star]	nil	element_starstaff
2665 [CHAT] selected	[Light]	function: 0x43469838	nil
2666 (in chat's set_element) state.set_element is 	true
2667 ##Use Talent Lua Error##	T_COMMAND_STAFF	Actor:	2394	MCP_agent-ham-insane-06
```
即：`engine.Chat` 的原生 answer 回调 `data/chats/command-staff.lua:set_element` 里的 `coroutine.resume(co, true)`（`co` 是 `data/talents/misc/objects.lua:182` 捕获的**天赋 body coroutine**）把 `true` 送回了被挂起的 `T_COMMAND_STAFF.action`，随后 `self:talentDialog(d)` 以 boolean 作 self 抛错。**这不是"手贱按键"路径**——我全程只用 `respond`（round3 是手动 `key` 触发的同一个错误，本轮证明它在纯 MCP 合法路径上也会发生）。

#### (d) 隔离态：不可恢复 + 假线索 + 游戏冻结
隔离后（此后所有 observe 都一样）：
```json
{"phase":"unavailable","actionable":false,"needs_reconnect":true,"control_lease":"released",
 "control":"manual","revision":481,"world_tick":70,
 "dialogs":[],
 "pending_command":{"command_id":"cmd-13","execution_released":false,"input_owner":"manual","status":"failed"}}
```
尝试过的恢复手段（全部失败）：

| 手段 | 结果 |
| --- | --- |
| `{"connect":"control"}` ×4 | 仍是 `lease=released / control=manual`，且再次 `needs_reconnect:true` |
| `{"connect":"observe"}` → `{"connect":"control"}` | 同上 |
| `{"stop":true}` | `{"ok":false,"error":{"code":"control_lost","message":"control lost"}}` |
| `{"key":"Escape"}` ×2（先开出 Game Menu 再关掉） | 无变化，`dialogs` 已空但状态不变 |
| 任意 `{"action":...}` | 控制台直接短路：`{"not_ready":{"phase":"unavailable",...}}`（连 server 都没到） |

代码定位（供修复参考，未改动）：
- `overload/mod/mcp_bridge/Runtime.lua:48` `nativePhase()`：`if s.native_error then return 'unavailable' end`（**优先级最高**，且无人清除）；
- `Runtime.lua:449-456` `M.onNativeError` 设置 `s.native_error` 后 `revoke()` + `finish(...,'failed')`，注释写明 "quarantine writes until a fresh game session"；
- `Runtime.lua:172-174` `finish()` 的放行条件是 `root.done and not NativeTasks.current(root) and status~='needs_input' and not root.error` —— **`root.error` 已置位，所以 `execution_released` 永远留在 false**，与 (d) 观察到的 `execution_released:false` 完全一致。
- 于是 `needs_reconnect:true` 成了**假线索**：协议在暗示"重连即可"，但 `access_mode=='control' and control_token==nil` 这个条件恰恰永远成立。

**更糟**：游戏本身也停了——`world_tick` 从错误发生时起冻结在 70，蛇/蚁/巨魔都不再行动（我间隔 25s 两次 observe，HP 与 actor 血量逐字节相同），`level_instance_id` 不变。也就是说这不是"等一会儿会自己缓过来"，而是本局游戏线程被这个坏 invocation 卡住。

**建议**（按性价比）：
1. **最省事**：把这类"对话回调会 `coroutine.resume(body, ...)` 直接复活原生天赋"的技能在 `admit()` 里判为 `needs_input`/`unsupported`（至少把 `T_COMMAND_STAFF` 拉黑），别让 agent 踩雷——因为无论如何本局都会死。
2. 给 native error 提供显式恢复通道（`abandon`/`reset invocation`/让 `connect` 清 `native_error`+`manual` handoff），并在 `finish()` 里允许 `root.error` 情况释放 execution；
3. `phase=unavailable` 时不要在 `meta` 里同时给 `needs_reconnect:true`，或者新增 `recovery:"none"` 之类字段说明"本会话只读"。
4. 若要真修：原生 `command-staff` chat 用 `coroutine.resume(co, true)` 复活 body，与 bridge 的 `Tracker.createBody` 包装协程语义冲突；建议在 `superload/engine/interface/ActorTalents.lua` 的对话 seam 里对"body 被外部 resume"做兼容（例如让 `talentDialog` 的 `coroutine.yield()` 容忍非 table 返回值，或在 chat answer 应用后不再走原生 resume 路径）。

### 2.3【P1·文档】`respond` 的 answer 必须带 `type`，提示词说反了

提示词写"**answer 只放该类型字段**"，但 server schema 是带判别的 union，缺 `type` 直接拒绝：

```json
{"_error":{"code":"mcp_request_rejected","message":
 "... respondArguments\nanswer\n  Unable to extract tag using discriminator 'type'
  [type=union_tag_not_found, input_value={'option_id': 'interaction-1:option-2'}, input_type=dict]"}}
```
必须 `{"type":"option","option_id":"interaction-1:option-2"}`。错误信息本身很清晰（可自我纠正），但提示词/capability 说明应改成"answer 必须含 `type`，再加该类型的字段（如 `option_id` / `x`,`y` / `direction` / `target_id`）"。

### 2.4【P2·准确性】`target_geometry.selffire` 对 beam/ball 都是 `"unknown"`

本轮实测：
```json
T_MOONLIGHT_RAY → {"shape":"beam","range":10,"piercing":true,"selffire":"unknown"}
T_SEARING_LIGHT → {"shape":"ball","radius":1,"range":7,"selffire":"unknown"}
```
字段确实"总是存在"（round3/round5 的缺失问题已修），但两个技能都拿不到确定值。beam 的 `selffire` 恒为 false、Searing Light 这类光域 AoE 需要真实值才能安全选位（我这次被迫用"先站在半径外打一发，事后看日志"来倒推）。建议：beam 直接给 `false`；其余若原生为 nil，则明确标注这是"未探测"而不是让调用方猜——或者在 `inspect(kind="talent")` 里给静态默认值。

### 2.5【P2】隔离态的 `pending_command` 不含任何可行动信息

失败后 `pending_command` 只有 `{command_id,execution_released,input_owner,status}`，没有 `interaction`（`dialogs` 也空）。round3 建议"observe 回传 pending interaction"对手动接管场景很有用；这里的场景是**没有 interaction 可答但状态不是 ready**，调用方完全不知道该做什么。建议至少补 `recovery` 或 `hint` 字段。

### 2.6【P2·工具链】控制台没有 `tome.status` 通道

server 有只读工具 `tome.status(command_id)`（内含 `execution_released`/`interaction` 等），但 `agent-play.py` 的控制台命令表没有对应入口，round4/round5 提到的"失败后先 `{}` 观察"在 native-error 场景下也拿不到东西。建议加 `{"status":"cmd-13"}`。

### 2.7【P3】观察（非缺陷，记录用）

- `set_sustain T_HYMN_OF_PERSEVERANCE` 后 `resources.negative.max` 由 50 → 30；这是原生（诗句占用负能量上限），不是桥的问题。
- `awaiting_input` 时的实时快照可用（`snapshot_scope:"live"`、`phase:"awaiting_input"`、`actionable:false`），符合提示词。
- `tome.act` 的 `native_rejected` 冷确拒绝信息精确（"Moonlight Ray is still on cooldown for 2 turns."），与 `observe.talents[].cooldown` 一致。

---

## 3. 验证正常的部分（建议保持）

1. `mapjson` 的 `rows/legend/exits/cells` 与肉眼所见一致：`origin (0,6)`、worldmap 出口 `<` 精确落在 (0,18)（正好是我起始格）；`cells` 的 `known/visible/char` 与 `rows` 逐格对应，未见冲突。
2. `walk [...]` 带 `moved_steps` 与逐步 `player{x,y,life}`，`stop_on_enemy:"never"` 行为正确；撞墙 `{"status":"failed","code":"blocked","energy_spent":0}` 不耗回合（连撞两次，revision 递增但 tick 不变）。
3. `use_talent` 的 beam 命中与 `target_geometry` 一致（Moonlight Ray 从 (3,20) 向北一发 43 伤害秒杀 hornet swarm）。
4. `list`/`inspect`/`map` 等只读通道在隔离态仍可用（`map` 返回 16×25+exits，`inspect(kind="actor")` 返回 `base_combat`），"保持传输可读"的设计是有效的。
5. `respond` 失败不再丢 interaction（§2.2b）；`_error.code=mcp_request_rejected` 载体清楚。
6. `set_sustain` 走 `{"action":{...}}` 后语义正确（`status:completed`、`energy_spent:0`、`sustains[]` 立刻反映、日志 "activates Hymn of Perseverance"）。

---

## 4. 修复优先级建议

| 优先级 | 项 | 影响 |
| --- | --- | --- |
| P0 | §2.2 native error 无恢复通道 + 游戏一起冻结（且 `T_COMMAND_STAFF` 必踩） | 一局白玩，agent 只能干等到人介入 |
| P0 | §2.1 未知命令键静默 observe | agent 空转、误判，前 4 条命令全废 |
| P1 | §2.3 answer 必须带 `type`（修提示词/schema 说明） | 首次 respond 必然失败一次 |
| P2 | §2.4 `selffire` 恒为 unknown | AoE 自伤不可预判 |
| P2 | §2.5/§2.6 隔离态无可行动信息、无 status 通道 | 无法自救 |
| P3 | §2.7 观察项 | 体验 |

## 5. 原始证据留档

- 控制台逐条原始返回：`tmp/mcp-play-support/agent-ham-insane-06.log`（第 1–56 行为本轮；第 2 行 READY、第 3–5/9–11/13–15 行为 §2.1 的静默忽略、第 34/37 行 interaction-1/2、第 38 行为 §2.2c 的 native_talent_error、第 39–56 行为隔离与恢复尝试）
- 我按命令时间顺序追加的审计流：`tmp/mcp-play-support/agent-ham-insane-06-raw.jsonl`
- 游戏侧日志：`tmp/tome-mcp-validation/sessions/agent-ham-insane-06/game.log`（2640–2667 行为 command-staff chat 与 Lua Error）
- 会话内快照/决策：`.../sessions/agent-ham-insane-06/observed.json`、`decisions.jsonl`、`play-mcp.jsonl`（MCP 层每次 `tome.act/respond/connect` 的入参与返回）

（本轮只读游玩，未修改仓库或游戏文件；结束时未退出游戏。）
