# agent-ham-insane-03 实机测试报告（半身人 / 星月术士 / Insane / Roguelike）

## 一句话结论
存活（未死），1 级，trollmire level-2 坐标 (41,1)，清怪约 10 只、拾取若干；**因 `use_talent T_COMMAND_STAFF` 弹出的原生对话在 `respond` 被 schema 校验拒绝后丢失 interaction，无法再作答；随后用控制台 `key` 手动选对话触发游戏内 Lua Error，bridge 进入 `phase=unavailable / control=manual` 的 native-error 隔离态，MCP 无法再控制，测试提前结束**。

## 最终状态（原始 observe）
```json
{"ok":true,"result":{"phase":"unavailable","control":"manual","revision":1865,
 "world_tick":1123,"level_instance_id":"level-2",
 "player":{"name":"MCP_agent-ham-insane-03","x":41,"y":1,"life":94,"max_life":94,
           "level":1,"exp":16.92,"exp_next":29.7},
 "resources":{"positive":50,"negative":34.5},
 "actors":[{"name":"forest troll","x":40,"y":2,"life":65.18,"max_life":106.1,
            "rank":2,"level":3}]}}
```
- 状态：**存活**，生命 94/94，正/负能量 50 / 34.5；相邻有一只 65 HP 的森林巨魔。
- 位置：trollmire `level-2`，坐标 (41,1)。
- 等级 1，经验 16.92 / 29.7（差 12.8 升级，全程未升级，故**没有加点机会**）。

## 游玩经过（关键节点）
1. `observe` 确认环境 ready；copper ring、linen wizard hat 等可见。
2. 用 `move` 撞墙，正确返回 `code="blocked"`。
3. 遭遇森林巨魔：`Searing Light`（ball radius1 range7）一次命中相邻两只巨魔；`Moonlight Ray`（beam range10 piercing）串杀。**target_geometry 与实际范围一致且有用**。
4. 拾取：踩金币自动拾取；hat/ring 用 `pickup item_id` 拾取。
5. 用 `walk` + 自己写的 BFS（对地图做可达性/边界搜索）探索整张图，期间击杀：
   - 森林巨魔 ×3、large white snake ×1、wolf ×2、fox ×1、black jelly ×1、green worm mass ×2+（其中一只 `Multiply` 复制）。
6. 治疗/回蓝：`rest` 一次（17 回合，stop_reason `native_complete`）。
7. 遭遇 `forest troll 5487` 时尝试 `use_talent T_COMMAND_STAFF` → 弹出原生 `dialog.choice`（"Call on which aspect of the staff?"），随后流程卡死（见下）。

## 技能 / 物品 / 加点
- 天赋：Attack、Command Staff、Luck of the Little Folk、Hymn of Detection/Perseverance/Shadows、3×Infusion（Healing/Regeneration/Wild）、Moonlight Ray、Searing Light、Twilight。
- 主要输出：Searing Light（直击 32 + 半径 1 区域/地面余焰 16，总 ~48；5 回合冷却）、Moonlight Ray（43 darkness + 余焰，beam 穿透）、Twilight（触发一次光域、回负能）。
- 物品：elm magestaff、brass lantern、linen wizard hat、copper ring、若干金币/材料。
- **加点：无**（没到 2 级，未执行 `learn_talent/learn_category`/`spend_stat`）。

## MCP 问题（按严重度）

### 1)【致命·阻塞】respond 被校验拒绝后 interaction 永久丢失，且 observe 不再暴露
- `T_COMMAND_STAFF` 正确返回交互（原始 JSON）：
```json
{"accepted":true,"code":"awaiting_native_input","command_id":"cmd-106","status":"awaiting_input",
 "execution_released":false,"interaction":{"answer_types":["option"],"kind":"dialog.choice",
 "interaction_id":"interaction-1","text":"Call on which aspect of the staff?",
 "options":[{"label":"[Mage]","option_id":"interaction-1:option-1"},
            {"label":"[Star]","option_id":"interaction-1:option-2"},
            {"label":"[Vile]","option_id":"interaction-1:option-3"},
            {"label":"Never mind.","option_id":"interaction-1:option-4"}]}}
```
- 我提交时多带了一个 `interaction_id`（schema 属 `extra_forbidden`）：
```json
{"_error":{"code":"mcp_request_rejected","message":"... respondArguments\nanswer.option.interaction_id\n  Extra inputs are not permitted [type=extra_forbidden, input_value='interaction-1']..."}}
```
- 之后控制台状态里 interaction 已被清空，再答即得：
```json
{"result":{"error":"No pending interaction"}}
```
  游戏侧仍停在 `awaiting_input`（对话 UI 还在），但**没有任何通道再拿到 interaction_id / command_id**：`observe` 只返回 `dialogs`（文本 widget），不返回 `interaction`，`settle()` 也只在 act/respond 的结果里回填 interaction。
- 根因（`tmp/mcp-play-support/agent-play.py`）：`respond()` 在调用前执行 `state['interaction']=None`，失败结果里没有 interaction，于是永久丢失；`observe()` 也不回填 interaction。属于**控制台/驱动层 bug**，而非 addon。
- 建议：① `respond` 失败（尤其 schema 校验）时保留/恢复原 interaction；② `observe` 回传 pending interaction（或提供 `status(command_id)` 通道）；③ answer 允许/忽略未知字段，或把精确 schema 写进测试提示。

### 2)【致命·环境】手动 `key` 接管对话后游戏内 Lua Error，bridge 单向隔离
- 为自救，用控制台 `{"key":"a"}` 逐级选对话（选 [Mage] → 选 [Fire]）。`game.log`：
```
[CHAT] selected [Mage] nil element_magestaff
[CHAT] selected [Fire] function: 0x4193e668 nil
(in chat's set_element) state.set_element is true
##Use Talent Lua Error##	T_COMMAND_STAFF	Actor: 2394	MCP_agent-ham-insane-03
```
- 此后 `observe` 永久返回 `phase=unavailable / control=manual`，`world_tick` 冻结在 1123；
  - `{"connect":"control"}` 连续多次无效（`control_source` 仍 manual）；
  - `{"stop":true}` 返回 `{"error":{"code":"control_lost"}}`；
  - 无 pending_command，但无法重新取得租约。即**手动接管是单向门 + native error 隔离**，测试无法继续。
- 备注：`key` 只在 `{"key":...}` 是控制台支持的；测试提示未列为接口，但它是唯一可尝试的恢复路径，结果反而触发 Lua Error。可考虑：native error 后提供显式“重置/放弃 invocation”通道，或让 connect 能清除 manual handoff。

### 3)【中】`pickup` 缺 `item_id` 直接校验失败
- 提示词把 `pickup` 列为动作，但 server schema 必填 `item_id`：
```json
{"_error":{"code":"mcp_request_rejected","message":"... actArguments\naction.pickup.item_id\n  Field required [type=missing, input_value={'type': 'pickup'}]"}}
```
- 正确用法 `{"type":"pickup","item_id":"...:ground-4,9:object-5507"}` 可用，返回 `code="item_action_complete"`。建议在动作文档里注明需要 ground item id（或支持“拾取脚下全部”）。

### 4)【低·观察】地面持续效果不可见
- `Searing Light` 会在地面留 `light_zone`（radius 1、约 4–5 回合），日志里反复出现 `...'s light area effect hits ... for 16 light damage`，能隔回合击杀黑果冻等；但 `observe` 不暴露地图/地面效果，agent 只能从事件文本推断。建议在 observe 里暴露 ground effects（或至少在 events 里标注）。

### 5)【低】`target_geometry.selffire` 未出现
- `Actions.lua` 里 `selffire=typ.selffire==true or nil`，为 false 时省略。Searing Light 得 `{shape:"ball",radius:1,range:7}`、Moonlight Ray 得 `{shape:"beam",range:10,piercing:true}`，都没有 `selffire` 键。与提示词描述（总带 selffire）不一致，建议显式输出 `selffire:false`。

## 已验证正常的功能
- `observe`/`map`/`list`/`inspect`（`inspect(kind="talent",id=...)` 需 `id`；含 `radius/direct_hit/reflectable` 等静态字段，函数型 target_shape 仍 `unknown`）。
- `move` 撞墙 → `code="blocked"`（不再伪成功）。
- `use_talent` 返回 `target_geometry`，与实际命中一致：ball 一次打中相邻两目标、beam 穿透串杀。
- `native_rejected` 带真实 `native_message`：
```json
{"code":"native_rejected","status":"failed","native_message":"Searing Light is still on cooldown for 3 turns."}
```
- `rest` → `code="native_complete"`、`stop_reason`、`turns_executed`。
- `pickup item_id`、`attack`、`wait`、`walk`（遇敌返回 `interrupted` 摘要）均正常。
- 多步原生对话本身被正确建模为 `dialog.choice` + `awaiting_input`（问题只出在 respond 失败后的状态管理）。

## 复现建议
1. 让 Anorithil/任意带 `T_COMMAND_STAFF`（魔杖）角色释放该技能 → 得到 `dialog.choice`。
2. 故意发一个带未知字段的 option answer → 观察 interaction 永久丢失、对话卡死。
3. 观察 `observe` 无法恢复 interaction，`connect control` 也无法恢复控制。

## 原始证据留档
- 控制台原始返回逐条保存在 `tmp/mcp-play-support/agent-ham-insane-03.log`（第 131/132/135 行为本报告问题 1；第 25 行为 pickup；第 12 行为 blocked；第 165/167 行为 control_lost）。
- 游戏侧日志 `tmp/tome-mcp-validation/sessions/agent-ham-insane-03/game.log`（约 2960–2970 行为 `##Use Talent Lua Error## T_COMMAND_STAFF`）。
