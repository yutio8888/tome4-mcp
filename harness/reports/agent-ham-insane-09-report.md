# ToME4 MCP 实机测试报告 — 第九轮（agent-ham-insane-09）

- 会话：`MCP_agent-ham-insane-09` / 半身人 · 星月术士（Celestial-Anorithil）/ **Insane** / Roguelike / trollmire（`level_instance_id: level-2`）
- 接口：v4 console（`tome-insane9.sh` / `map-insane9.sh` / `mapjson-insane9.sh`），全程未重启游戏、未 kill、未改仓库文件
- 结束状态：**存活**，等级 1，位置 (7,23)，HP **94/94**，positive 50/50，negative 40.9/50，`phase=ready`、`actionable=true`、`control_lease=held`，视野内无敌人（安全状态，控制台与游戏进程保持运行）
- 本轮战果：击杀 狼(lv2) / 红软泥(lv2) / **森林巨魔(lv3，rank 2 精英)**；拾取并装备 rough leather cap；加点 mag 16→19；学 Searing Light 2、Moonlight Ray 2、Healing Light 1
- 仓库文件未改动；报告只读证据来自 `tmp/tome-mcp-validation/sessions/agent-ham-insane-09/play-mcp.jsonl`（原始 MCP 响应）、`game.log`、`game/modules/tome/data/talents/celestial/sunlight.lua`

---

## 一、实机过程（精简）

1. 启动即 `observe` → 确认 `phase=ready/actionable=true/control_lease=held`，v4 出生插件给了 3 属性点 + 2 职业点 + 1 通用点，且 `progression_talents` 显示 4 个起始技能 `raw_level=0`。
2. 加点：`spend_stat mag ×3` → mag 19；`learn_talent T_SEARING_LIGHT / T_MOONLIGHT_RAY`（职业）、`T_HEALING_LIGHT`（通用）全部 `progression_applied`。
   - **注意**：学习返回 `previous_value:1 → new_value:2`，即这两个技能创建时已是 1 级（`game/modules/tome/data/birth/classes/celestial.lua:169` 确认 birth 学了 SEARING_LIGHT/MOONLIGHT_RAY/HYMN_ACOLYTE/TWILIGHT=1）；但 `progression_categories`/`progression_talents` 当时对这两个技能报 `raw_level: 0`，两者矛盾（详见 §3.8）。
3. 探索：自写 BFS 前沿规划（读 `mapjson` 的 `cells[].block_status/known`）→ `{"walk":[...]}` 逐段推进，共约 40 步；`mapjson` 的 `cells/exits` 足够做寻路与出口识别。
4. 战斗 3 场，全部用 `use_talent` + **预填 `target_id`**，**没有触发任何 `awaiting_input`**：
   - 狼：`Searing Light`(靶标直击 46 + 落点光域 23) 一击致死。
   - 红软泥：`Searing Light` 69 伤 → 一击致死。
   - 森林巨魔（96.4 HP，lv3 rank2）：`Searing Light` 46+23 → 剩 29.2；`Moonlight Ray` 62 → 击杀。玩家 **零受伤**（94/94）。
5. 拾取/装备：踩到金币自动入袋；`pickup` + `equip` rough leather cap（`item_action_complete`，`combat_armor` 0→1）。
6. 全程资源核算与原生一致：`Sunlight` 技能 `positive = -15`（**回复** 15 点）→ positive 一直显示 50/50 是正确行为；`Moonlight Ray` 花 negative → 50→40.4。

---

## 二、新接口逐项体验

### 2.1 `{"sheet":true}` / `inspect(kind="character", id="self")`

**能用**：一次拿到 45 个字段，含 `stats`（base/bonus 分离）、`resource`、`equipment`（含 `wielder`/`requirements`/`activation.present`）、`inventory`、`base_combat`、`base_resists`、`base_weapon`、`die_at`、`speed`、`unused_*`、`effects`、`sustains`。

返回键（原始）：
```json
["base_combat","base_resists","base_weapon","character_scope","combat_scope","combat_values_are_raw","descriptor","die_at","effect_duration_is_raw","effects","effects_truncated","energy","equipment","equipment_truncated","exp","exp_next","exp_scope","faction","id","inventory","inventory_scope","inventory_truncated","level","life","life_regen","max_life","name","rank","regeneration_is_raw","resists_truncated","resources","speed","speed_values_are_raw","stats","stats_are_raw","subtype","sustains","type","unused_generics","unused_prodigies","unused_stats","unused_talents","unused_talents_types","x","y"]
```

`character_scope` 文本清晰：
```json
"character_scope":"stored fields only; gear/effect computed values (effective accuracy/defense/damage/armor/saves/resists) are not evaluated",
"combat_scope":"stored base fields; excludes computed scaling, penetration and target-specific modifiers",
"combat_values_are_raw":true
```

**缺口 / 问题**
1. **面板没有技能**：`sheet` 里没有已学技能、技能等级、剩余冷却、技能类别（`talents: null`，键根本不存在）。面板 + `{"list":{"type":"first","collection":"talents"}}` 才能补齐；而 `list talents` 给的是 `level` 与 `cooldown`（剩余），没有 `base_cooldown`（只有 compact observe 的 talents 里有）。建议面板至少给一个 `talents_summary`。
2. **缺金钱、负重、任务、抗性明细、护甲硬直等**（`encumbrance` 只存在于 item 上，没有总负重/上限）。
3. **`base_combat.combat_spellpower = 3` 极具误导性**：实际 `Searing Light` 按 2 级打出 46 点伤害（mag 19），真实 spellpower 远高于 3。虽然有 `character_scope` 说明，但字段名以 `combat_` 开头，很容易被当成有效战力：
```json
"base_combat":{"combat_armor":1,"combat_atk":0,"combat_dam":0,"combat_def":0,"combat_spellpower":3,"combat_physcrit":0,"combat_physresist":0,"combat_spellresist":0,"combat_mindpower":0,"combat_mentalresist":0,"combat_armor_hardiness":0}
```
   建议：把这类值放进 `base_combat_raw` 或每个数值带 `"evaluated": false`，并补一个 `effective_*`（哪怕是 0 值也要说明未评估）。
4. `inspect(kind="character")` 与 compact `observe` 的 `player` 粒度不一致（见 §2.3）。

### 2.2 compact `observe` 的 `player`

**满足决策**：`id/name/x/y/life/max_life/level/exp/exp_next/life_regen/energy/faction/type/subtype/rank/stats{base,bonus}/descriptor/unused_*` 都在，且 `resources`/`effects`/`talents`/`sustains`/`actors`/`ground` 在顶层平铺，字段名稳定。原始（开局）：
```json
"player":{"id":"tome-1789534336-1480-3-table0x40f4d2c0:level-2:actor-2394","name":"MCP_agent-ham-insane-09","x":0,"y":11,"life":94,"max_life":94,"level":1,"exp":0,"exp_next":29.700000000000003,"life_regen":0.25,"energy":1000,"faction":"allied-kingdoms","type":"humanoid","subtype":"halfling","rank":3,"stats":{"con":{"base":10,"bonus":1},"cun":{"base":13,"bonus":3},"dex":{"base":10,"bonus":3},"mag":{"base":16,"bonus":0},"str":{"base":10,"bonus":-3},"wil":{"base":10,"bonus":0}},"descriptor":{"class":"Celestial","difficulty":"Insane","race":"Halfling","sex":"Female","subclass":"Anorithil","subrace":"Halfling"},"unused_stats":3,"unused_talents":2,"unused_generics":1,"unused_talents_types":0}
```
**缺**：`armor/defense/accuracy/spellpower/saves`（combat 派生值一个都没有，无法判断"我现在能不能扛/打得中"）；`known talents`（只能靠 `talents` 段）；`effects` 的叠层/剩余回合要另取。

**actors 缺 `hostile`/`disposition`**：原始 actor 只有 `faction`，agent 必须自己把 `faction != player.faction` 推断为敌人（console 的 `walk` 实现里也专门写了这段推断逻辑）：
```json
{"faction":"enemies","id":"tome-...:level-2:actor-5614","level":3,"life":96.375,"max_life":96.375,"name":"forest troll","rank":2,"subtype":"troll","type":"giant","x":9,"y":23}
```
建议加 `hostile: true|false` 与 `effects/subtype` 之外的 `dist`。另外 actor 的变化只能在下次 `observe` 看到（无推流），实测可接受。

### 2.3 `observe.sections` 裁剪

**能省流量**（`observe` 不裁剪时含 `collection_refs` 等大块），但当前投影语义有 3 个问题：

1. **未被请求的域会返回"19 个 null 字段"的残桩**，而不是省略。`sections:["talents"]` 原始：
```json
{"ok":true,"result":{"actionable":true,"talents":[{"id":"T_ATTACK","name":"Attack","cooldown":0,"supported":true}, ... 13 项],"player":{"id":null,"name":null,...,"unused_talents_types":null}, ...}}
```
   对 LLM 来说 `player.life: null` 与"未知"无法区分，容易被误读成"血量未知"。
2. **`sections` 里只要出现 `"effects"`（合法域名！）整份响应就废掉**。可复现 3/3 次：
```
$ ./tome-insane9.sh '{"observe":{"sections":["effects"]}}'            # 原始 result = {} （空对象）
$ ./tome-insane9.sh '{"observe":{"sections":["player","effects"]}}'  # 同样坏掉
# console 汇总（原始 result 为空 → 汇总出残桩）：
{"player":{...19 个 null...},"talents":[]}   # 连 phase/actionable/control_lease/revision 全丢
```
   证据（play-mcp.jsonl，`tome.observe` 原始响应）：
```json
--- tool=tome.observe args={"sections":["effects"], ...}
{"ok":true,"result":{}}          # result keys: []
```
   **这是本轮最严重的问题**：`effects` 是文档列出的合法域，一旦带上就丢失全部控制/可行动性字段（`phase/actionable/control_lease/revision`），agent 会直接失去判断能力。
3. **不存在的 domain 名被静默接受**：`sections:["bogus_section"]` → 无报错，返回同一份空投影；`sections:["ground"]`（`ground_items` 才是集合名）同样静默。schema 应拒绝未知 section 名（与顶层未知键会报 `unknown_command_key` 的严格风格一致）。
4. **粒度不一致**：`sections:["player"]` 返回的 `player` 是**整张角色面板**（含 `die_at/equipment/inventory/...`），与 compact observe 的 `player` 不是同一个形状。

**结论**：`sections` 目前"设计意图可用、实现不可靠"。建议：未请求域直接省略、`effects` 修成正常域、未知域名报错、统一 `player` 形状。我实际游玩中最终只敢用 `{"observe":true}` 与 `{"observe":{"sections":["player","actors"]}}`。

### 2.4 `{"status":true}` 直查命令

**好用**，且支持历史 id：`{"status":"cmd-59"}` 能取回已过期窗口外的命令结果（`retained_count: 61`）。
```json
{"ok":true,"result":{"accepted":true,"code":"insufficient_class_points","command_id":"cmd-59","energy_spent":0,"execution_released":true,"history":{"last_accepted_seq":61,"next_command_id":"cmd-62","retained_count":61},"revision":1027,"revision_after":1021,"revision_before":1018,"seq":59,"snapshot":{...},"status":"failed","uncertain":false}}
```
问题：
- 返回体里塞了**完整 snapshot + `collection_refs`（9 个集合引用）+ 完整 history**，很大；`status` 这种高频查询应有 `compact=true` 或默认只回 `status/code/energy/world_tick/revision`。
- **新旧混淆**：`status:"cmd-59"` 的结果里 `revision:1027`（当前）与 `revision_after:1021`（当时）并存，`history.next_command_id` 是**当前**的 `cmd-62` 而不是 `cmd-59` 的下一步。容易误读，建议把"当前快照"字段包一层 `current`。
- `{"status":true}` 取的是**最近一次 action** 的 id（console 侧只在 action/respond 时记录），observe 之后仍返回旧 action；语义可用但值得写明。

### 2.5 非命令弹窗 `{"dismiss":{...}}`

本轮**未遇到**封印门 / Lore / Running / 死亡弹窗（trollmire 1 层无此内容，且未死），所以无法给正面结论。只测了"无弹窗时"的错误路径：
```json
$ {"dismiss":{"type":"option","option_id":"nope"}}
{"ok":true,"result":{"_error":{"ok":false,"result":null,"error":{"code":"no_pending_interaction","message":"no pending interaction","accepted":null,"uncertain":false}}}}
```
问题：
- 没有弹窗时，错误被**双层包裹**在 `result._error` 里（外层 `ok:true`），与 `tome.act` 失败的 `result.status:"failed"` 风格不统一；理想是顶层 `ok:false`/`isError:true`。
- 错误对象没有 `interaction_id`（此时确实没有 interaction，可接受），但也没有 `hint`/`accepted`（`accepted:null`），排查时只能靠猜。

### 2.6 `failed` / `cancelled` 的 `isError` 语义

**判定规则清楚但不够显眼**：拒绝类动作在 MCP 层是**成功调用**（`ok:true`，无 `isError`），真正的结果在 `result.status` + `result.code`：
```json
// 撞墙移动
{"status":"failed","code":"blocked","accepted":true,"uncertain":false,"energy_spent":0,"native_return":true,"snapshot_availability":"retained","world_tick_before":370,"world_tick_after":370}
// 加点但没点数
{"status":"failed","code":"insufficient_class_points","accepted":true,"energy_spent":0,...}
// 未学技能 / 洗点关闭
{"status":"failed","code":"talent_not_learned",...}   // 用不存在的 T_DOES_NOT_EXIST 也报这个 code
{"status":"failed","code":"respec_not_enabled",...}
```
- **好的地方**：`status:"failed"`、`code`、`uncertain:false`、失败时 `energy_spent:0` 且 `world_tick_after == world_tick_before`、快照 `retained`，情报足够区分"命令没执行"与"执行了但无效"。
- **容易踩坑**：`accepted:true` + 顶层 `ok:true` 会诱导"以为成功了"。建议 `status:"failed"` 时把 `accepted` 改为 `admitted`（表示命令被接纳）或直接 `ok:false`，并在 `capabilities` 里写死"以 `status` 为准"。
- `talent_not_learned` 用于"技能 ID 根本不存在"，code 名不准确（应 `unknown_talent` 或 `talent_not_available`）。

另外 **schema 级拒绝会丢掉结构化内容**，是最不清楚的一条路径：
```json
// tome.list(collection="talent_categories") —— 原始响应
{}
// console 只能靠 MCP 的 is_error + 文本拼出来：
{"ok":true,"result":{"_error":{"code":"mcp_request_rejected","is_error":true,"message":"Error executing tool tome.list: 1 validation error for list_collectionArguments ... Input should be 'inventory','equipment','actors','talents','effects','ground_items','progression_categories','progression_talents' or 'compatibility'"}}}
```
`is_error:true` 是清楚的，但 `structured_content` 为空、没有机器可读的 `code`（要靠 console 合成 `mcp_request_rejected`）。建议用 MCP 的 `outputSchema`/错误结构返回 `code: "invalid_argument"` + 允许值列表。

集合级校验错误也不够可诊断：
```json
{"ok":false,"result":null,"error":{"code":"invalid_filter","message":"invalid filter","accepted":null,"uncertain":false,"acceptance_scope":"not_applicable"}}
// 请求：{"type":"first","collection":"progression_categories","filter":{"limit":50}}
```
`invalid_filter` 不说明"哪个 key 非法 / 接受哪些 key"。

### 2.7 交互错误是否带 `interaction_id`

本轮没有真正进入"有交互但答错"的路径（3 场战斗用预填 `target_id` 全部一次过，没有 `awaiting_input`）。无交互时：
```json
$ {"respond":{"type":"option","option_id":"nope"}}
{"ok":true,"result":{"error":"No pending interaction"}}     // console 侧短错误，无 code/无 interaction_id
```
这条是 console 层拦下的（没发 MCP），因此看不出 bridge 的交互错误是否带 `interaction_id`。**未验证项**，建议下轮专门造一次（如目标选择里给非法 `option_id`）来确认 `respond` 失败是否回传 `interaction_id` 以便改答。

### 2.8 其它问题与缺口

1. **`inspect(kind="talent")` 的 `range/cost/target_geometry/requires_target` 全为 `null`**，而 `tome.act` 的返回值里却有几何——**打之前拿不到，打之后才给你**：
```json
// inspect talent T_SEARING_LIGHT
{"id":"T_SEARING_LIGHT","level":2,"mode":"activated","range":null,"base_cooldown":5,"cost":null,"target_geometry":null,"requires_target":null}
// act 之后
"target_geometry":{"radius":1,"range":7,"selffire":"unknown","shape":"ball"}          // Searing Light
"target_geometry":{"piercing":true,"range":10,"selffire":"unknown","shape":"beam"}    // Moonlight Ray
```
   实测这两个几何与原生完全一致（`data/talents/celestial/sunlight.lua`: `positive=-15, range=7, radius=1, {type="ball",range=...,radius=1}`），所以**数值是对的，只是暴露位置不对**。建议 `inspect talent` 预先给出 `range/radius/shape/selffire/cost`，否则 agent 只能"试探性开火"。
2. **`selffire` 恒为 `"unknown"`**：Searing Light 的原生 `tg` 没写 `selffire`，而 ToME 默认 `selffire=true`——这是**可静态确定的**，MCP 完全可以报 `true`（Moonlight Ray 是 beam，也报 unknown）。当前值让"不要以自身为 AoE 球心"这条规则对所有技能都退化为保守禁止。
3. **`inventory_id` 冲突**：`rough leather cap(object-5648)` 与 `Scrying Orb(object-7080)` 都报 `inventory_id: 1`：
```json
{"id":"tome-...:object-5648","name":"rough leather cap","inventory_id":1,...}
{"id":"tome-...:object-7080","name":"Scrying Orb","inventory_id":1,...}
```
   物品靠完整 `id` 区分没问题（我全程用完整 id），但 `inventory_id` 作为"背包槽位"不可信，建议改名/修值。
4. **`progression` 的 `raw_level` 与实际不符**：`progression_categories`/`progression_talents` 报 `raw_level: 0`，实际出生已 1 级（`learn_talent` 回 `previous_value:1`，birth 定义也确认）。同类问题：`list talents` 的 `level` 是对的（1），两个集合互相矛盾。
5. **`{"walk":[...]}` 语义与 prompt 不符**：prompt 写"waypoints `[[x,y],...]`，`stop_on_enemy: visible|adjacent|never`"，实际 console 实现是**方向序列**（`[8,8,6]`；`blocked = (stop_on_enemy=='visible' and enemies) or (stop_on_enemy=='adjacent' and adjacent)`，`stop_on_enemy=='never'` 就不拦，行为与命名一致，只是与 prompt 的 waypoint 描述不同）。这不是 MCP 问题，但 prompt 与 harness 必须对齐（我一开始按 waypoint 理解，浪费了一次尝试）。
6. **同一 session 并发两条命令会串响应**（console/`send.sh` 层）：`send.sh` 用"写 FIFO 后取日志下一行"匹配响应，两个进程并发时都会读到同一条新行。复现：
```sh
$ ( ./mapjson-insane9.sh > /tmp/race_map.json & ./tome-insane9.sh '{"observe":{"sections":["talents"]}}' > /tmp/race_obs.json & wait )
# map 调用拿到的"result"键：['actionable','control','control_lease','history','level_instance_id','phase','player','revision','talents','world_tick']  ← 这是 observe 的响应！
# 现象与开局时 map.sh 打印 "origin x=None y=None" 完全一致
```
   **没有报错、静默错配**，对 agent 很危险（会把别人的响应当成自己的观察结果）。至少要在 wrapper 里加 1 秒内禁止并发（flock），或在协议里带 request/response 关联 id。
7. **资源字段准确性（正面结论）**：`positive/negative` 变化与原生一致，`Searing Light` 回复 positive（`positive=-15`）所以 50/50 不动、`Moonlight Ray` 扣 negative（50→40.4），没错。

---

## 三、问题清单（按严重度）

| # | 严重度 | 问题 | 证据/影响 |
| --- | --- | --- | --- |
| 1 | **高** | `observe.sections` 含 `"effects"`（或任意未知域名）→ 返回空 `result {}`，丢失 `phase/actionable/control_lease/revision`；`["player","effects"]` 同样中招 | §2.3（原始 `result:{}`，3/3 复现）。会让 agent 失去可行动性判断 |
| 2 | **中高** | 同一 session 并发命令静默串响应 | §2.8.6（map 调用收到 observe 响应） |
| 3 | **中高** | `inspect(kind="talent")` 的 `range/cost/target_geometry/requires_target` 为 null，几何只在 `act` 返回后才可见；`selffire` 恒 `unknown` | §2.8.1/2.8.2（数值本身与原生一致） |
| 4 | 中 | `sections` 未请求域返回 19-null 残桩；未知 section 名静默接受 | §2.3 |
| 5 | 中 | MCP 层 `ok:true` 但动作 `status:"failed"`，同时 `accepted:true`，易误判 | §2.6 |
| 6 | 中 | schema 级拒绝 `structured_content` 为空，只能靠 `isError` + 文本；无机器可读 code | §2.6 |
| 7 | 中 | `sheet` 无技能/冷却/负重/金钱；`base_combat.combat_spellpower=3` 误导 | §2.1 |
| 8 | 低 | `status` 返回体过大且新旧 revision 混排 | §2.4 |
| 9 | 低 | `inventory_id` 冲突（两件物品同 id 1） | §2.8.3 |
| 10 | 低 | `progression_talents`/`progression_categories` 的 `raw_level` 与 `list talents.level` 矛盾 | §2.8.4 |
| 11 | 低 | `dismiss` 无弹窗时双层 `result._error`，`accepted:null` 无 hint | §2.5 |
| 12 | 低 | `talent_not_learned` 用于"技能 ID 不存在"；`invalid_filter` 不说明原因 | §2.6 |
| 13 | 低（文档） | prompt 的 `walk` 描述（waypoints）与实际（方向序列）不符 | §2.8.5 |

## 四、未验证 / 下轮建议

- `{"dismiss":{...}}` 在**真实**非命令弹窗（封印门 / Lore / Running / 死亡）上的行为，本轮未遇到；建议下轮先造一个 Lore/封印门场景。
- `{"respond":{...}}` 答错时是否回传 `interaction_id` 便于改答（本轮 3 场战斗都靠预填 `target_id` 一次通过，没进过 `awaiting_input`）。
- `awaiting_input` 的实时快照（`snapshot_scope:"live"`）与 `base_cooldown` 本轮也没触发到（`list talents` 给的是剩余 `cooldown`）。
- 死亡/`recovery:"fresh_load_required"` 只读降级、切层后 `{"connect":"control"}` 均未覆盖。

## 五、亮点（保持）

- `use_talent` 预填 `target_id`（console 支持短 id `"5614"`）非常顺：3 场战斗 0 次交互往返，`Searing Light`/`Moonlight Ray` 的 `target_geometry` 与原生一致。
- `mapjson` 的 `cells[{known,visible,block_status,is_exit,name}]` + `exits` 足以做 BFS 寻路（配合 `block_status` 判定通行，比看字符可靠）。
- 失败动作的 `status:"failed"` + `code` + `energy_spent:0` + `world_tick` 不变，能可靠区分"没执行"。
- 资源（positive/negative）与原生完全一致；`control_lease=held`、`revision`、`history.next_command_id` 全程稳定，`expected_revision` 冲突一次都没发生。
