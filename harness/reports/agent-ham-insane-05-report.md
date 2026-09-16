# 实机测试报告 — 第五轮（半身人 / 星月术士 / Insane / Roguelike）

会话：`MCP_agent-ham-insane-05`（隔离游戏后台运行，未重启、未 kill、未改任何文件）
控制台：`tmp/mcp-play-support/{tome,map,mapjson}-insane5.sh`
字符：Halfling / Celestial-Anorithil / Insane / Roguelike，cheat=false
日期：本轮结束时角色**存活**（未死亡、未卡死，属"探索完成"收尾）

---

## 1. 最终状态

```json
{"phase":"ready","control":"remote","hp":[112.4,151],"lvl":5,
 "exp":[169.16,279.4],"pos":[59,3],"res":{"air":100,"negative":42,"positive":62},
 "sustains":["Hymn of Perseverance"],"effects":[["Poison",5]]}
```

- 位置：Trollmire **第 3 层**（`level_instance_id = level-4`），坐标 (59,3)
- 等级 5，151 最大生命，经验 169.16 / 279.4
- 装备：`elm starstaff`(MAINHAND) / `brass lantern`(LITE) / `spellwoven linen robe`(BODY,+2 spellpower +15 spellres) / `Prox's Lucky Halfling Foot`(TOOL)
- 背包：`Rod of Recall`(400 充能，回世界地图) / `Eye of the Dreaming One` / `balanced iron dagger of daylight` / `insulating iron helm of constitution`(穿不上：缺 Heavy armour training) / `Scrying Orb`
- 已知技能等级：Searing Light 4、Moonlight Ray 3、Healing Light 3、Hymn Acolyte 2、Twilight 1、Shadow Blast 1、Sun Flare 1、Halfling Luck 1、3 个 Infusion(Healing/Regeneration/Wild) 各 1
- 属性：Mag 27(+5)、Cun 17(+3)、Con 10(+1)、Dex 10(+3)
- 完成：Trollmire 1、2 层全图探索（每层 65×40 全部已知）；护送任务 *Escort: lost defiler* 成功（奖励 +5 Magic）；击杀 **Prox the Mighty**（rank 4 / lvl 8 / 518 HP）

---

## 2. 经过（按时间顺序）

### 2.1 Trollmire 1 层（instance `level-2`，1 级）

- 起手 `{}` observe：phase=ready，negative 30 / positive 50，sustain = Hymn of Shadows。
- 用 `use_talent{T_MOONLIGHT_RAY, target_id}` 开怪（beam，43 伤害），再用 `T_SEARING_LIGHT`（ball r1，35+17 区域）清 great wolf / forest troll / wolf / fox / giant grey rat / midge swarm。
- 学会 Anorithil 的资源循环：`Searing Light` 产 positive，`Moonlight Ray` 耗 negative，`Twilight`（15 positive → ~26 negative，Cun 缩放）补充。
- 用 `mapjson` 合并窗口（自写 /tmp 脚本，非仓库文件）做 BFS 自动探索，注意 `<`/`>` 不踏入以免触发切层。
- 1 级只用 T_ATTACK 近战，实测**命中率极低**（staff dam 10，对 mouse/wolf 连续 4~5 次 miss），只有法术稳定命中——这是可用的实战结论（不是桥的问题，但 `equipment[].combat` 里没有 `atk`/防御字段，无法在桥内自查命中率，见 §3.12）。
- 升到 2 级：Mag+4 / Cun+2；Searing Light→2、Moonlight Ray→2、Healing Light 1、Hymn Acolyte→2。
  - 尝试 `T_SUN_FLARE` 失败：`native_progression_rejected / "Prerequisites not met!"`（实为缺"等级≥4 且 Mag≥20"，字段没说是哪一项，见 §3.6）。
- 找到下行楼梯 `>` (64,5)，`change_level` → Trollmire 2。

### 2.2 Trollmire 2 层（instance `level-3`，2~3 级）

- **`change_level` 后控制租约丢失**：返回 `level_changed`，但之后所有动作都返回 `control_lost`，而 observe 仍报 `phase=ready / control=manual`。用 console `{"connect":"control"}` 恢复（见 §3.1）。
- 全图探索（65×40，全部已知）+ 清怪：forest troll、stone troll、gloomy brown bear、sick honey tree（lvl 10, 247 HP，掉落 honey tree root，经验 +8）、rogue（双持 16 伤害）、各种 jelly/ooze/worm（会分裂/增殖）。
- 打 sick honey tree 时弹出 **"New Class: Summoner" notice 弹窗**，把游戏卡进 `phase=needs_input`，但 `pending_command` **没有 interaction**，`respond` 报 `"No pending interaction"`，只能用 `{"key":"Escape"}` 清掉（见 §3.8）。
- 升到 3 级：Mag+3；Moonlight Ray→3、Healing Light→2。
- 找到 `>` (64,10)，`change_level` → 返回 `awaiting_input / awaiting_native_input`（这次是 QuestPopup）。

### 2.3 Trollmire 3 层（instance `level-4`，3~5 级）

- 落地触发**护送任务** `Escort: lost defiler (level 3 of Trollmire)`。用交互链回答：
  1. `interaction-2`（QuestPopup "Close"）
  2. `interaction-3`（Chat "Lead on; I will protect you."）
  - 期间 `respond` 一度返回 `control_lost`（input_owner 从 `orphaned` 变 `remote` 后才能答，见 §3.1）。
- 护送 NPC `Arariatha, the lost defiler`（`faction:"allied-kingdoms"`）出现在 `observe.actors[]` 里，导致 console `walk` 的 `stop_on_enemy` 永远判定"看到敌人"，auto-explore 直接卡死；改用 `stop_on_enemy:"never"` + 自行按 faction 过滤（见 §3.3）。
- 护送自动完成 → 奖励对话 `dialog.choice / native_ui:"Chat"`，6 个选项，选 `[Improve Magic by +5]`（Mag 23→28）。
- **Boss 战 Prox the Mighty**（rank 4，lvl 8，518.1 HP，带 Knockback + movement infusion，掉落 unique + boss 掉落）：
  - 开场被他连打掉到 54/122 HP（约 11~21/次）。
  - `Infusion: Healing` +50 → `Healing Light`（此时 lvl 2，Mag 28）**一次回 151**，续航成立。
  - 用 `Searing Light`（52~84 + 光区 26~42/回合 4 回合）+ `Moonlight Ray`（63~90）+ 近战（8~10）+ `Hymn of Perseverance`（20% 眩晕/致盲/混乱抗）+ `Halfling Luck`（免费）磨死。
  - 最后一击的响应是 `awaiting_input`，其 `snapshot` 仍是**动作前的旧快照**（血量 47、Prox 49.1 存活），observe 之后才显示已击杀、经验暴涨并升到 4 级（见 §3.7）。
  - 同时弹 "Of trolls and damp caves — Quest Updated!" QuestPopup。
- Prox 尸体堆 7 件：`tattered paper scrap`(lore)、`Rod of Recall`、`spellwoven linen robe`、`Prox's Lucky Halfling Foot`、`balanced iron dagger of daylight`、`insulating iron helm of constitution`、`Eye of the Dreaming One`。
  - 走上去时连续弹 3 个 LorePopup，用 `respond option` 逐个关闭。
  - 用 `pickup{item_id}` 全部拾取（第一次拾取触发弹窗 → `awaiting_input`，关掉再继续）。
  - `equip`：robe 成功；helm 被拒 `native_rejected "... can not wear (on head): ... (missing Heavy armour training)."`（拒绝原因清晰，很好）。
  - 有趣且正确：`Prox's Lucky Halfling Foot` 的 `wielder` 里包含 `on_wear` 的**种族惩罚**（半身人穿戴 -10 三抗/-10 luck），与 `boss-artifacts-maj-eyal.lua:1674` 完全一致——桥的 item 汇总深度正确。
- 升到 5 级：Mag 27、Cun 17；学 `T_SHADOW_BLAST`、`T_SUN_FLARE`、Searing Light→4、Healing Light→3。
  - 两个新技能学完**立刻进入完整 CD**（Shadow Blast 剩 6、Sun Flare 剩 8）——原生行为（`modules/tome/class/Actor.lua:5196`），非桥问题，但 `inspect` 同时暴露"基础 cooldown"和"剩余"，易误读（见 §3.4）。
  - 实测 `T_SHADOW_BLAST`（ball r3 range 6）**打到了自己 36 点**（`selffire` 是函数，`target_geometry` 里没有该字段，见 §3.5）。
- 收尾：继续清图（stone troll / white wolf / white worm mass / jelly / ooze），角色存活，停在 (59,3)。

---

## 3. MCP 问题清单（附原始 JSON 证据）

优先级：**P0** = 会卡住/误导 agent，**P1** = 字段缺失/歧义，**P2** = 体验/一致性。

### 3.1 【P0】`change_level` 之后控制租约丢失；动作 `control_lost`，但 `observe` 仍报 `phase=ready`

第一次切层（1→2）的动作本身 `completed / level_changed`，其后**所有**动作失败：

```json
{"ok":true,"result":{"_error":{"ok":false,"result":null,"error":{
  "code":"control_lost","message":"control lost","accepted":null,"uncertain":false,
  "command_id":"cmd-660"}},
 "snapshot":{"phase":"ready","control":"manual","revision":7728,"world_tick":5287,
             "level_instance_id":"level-3","player":{"x":0,"y":34,"life":100.08}}}}
```

observe 也显示 `{"phase":"ready","control":"manual"}` —— phase 与可行动性不一致，是本次最大的坑。
恢复方式：console `{"connect":"control"}`（内部 `tome.connect{mode:"control"}`）后 `control:"remote"`。

第二次切层（2→3）更绕：动作返回 `awaiting_input`，而交互的 `input_owner` 先是 `orphaned`：

```json
{"pending_command":{"command_id":"cmd-1688","execution_released":false,
  "input_owner":"orphaned","status":"awaiting_input",
  "interaction":{"interaction_id":"interaction-2","kind":"dialog.notice",
                 "native_ui":"QuestPopup","options":[{"label":"Close"}]}}}
{"respond":{"type":"option","option_id":"interaction-2:option-1"}}
 -> {"code":"control_lost","command_id":"cmd-1688","response_id":"resp-01771"}
```
重新 connect 后同一 respond 才能被接受。

**建议**：切层/场景切换后自动重新获取控制；或在 observe 中把 `control != "remote"` 明确表达为不可行动（`phase:"no_control"`），并让 act/respond 的 `control_lost` 自带"请重新 connect"提示。

### 3.2 【P0/控制台】console `walk` 把动作错误吞成 `status:null / code:null`

```json
[{"status":null,"code":null,"moved_steps":0,
  "player":{"descriptor":{...},"equipment":[...],"inventory":[...],"stats":{...}}}]
```
walk 内部 `if res.get('status') ~= 'completed' then break end`，而错误信封里没有 `status`，于是 `control_lost`、校验失败、甚至 MCP 异常都表现为"静默不动"。我在切层后因此空转了 80 次 auto-explore（每次 1 个 MCP 往返）。

**建议**：把 `res._error` 原样塞进中断条目（`{"error":{...}}`）。

### 3.3 【P0/控制台】`observe.actors[]` 混入非敌对 actor，`walk` 的 `stop_on_enemy` 不按阵营过滤

```json
{"name":"Arariatha, the lost defiler","faction":"allied-kingdoms","rank":2,"level":3,"x":1,"y":23}
```
护送开始后它一直跟着我，`walk` 的 `visible/adjacent` 判定只看 `actors` 是否非空 → auto-explore 单步都走不出去。
**变通**：`stop_on_enemy:"never"` + 客户端按 `faction=="enemies"` 自行过滤。
**建议**：observe 给 `hostile:true/false`，或 console 的 walk 按 faction 过滤。

### 3.4 【P1】新学技能立刻满 CD；`inspect` 的 `cooldown` 语义易混

```json
{"code":"native_rejected","native_message":"Shadow Blast is still on cooldown for 6 turns."}
{"code":"native_rejected","native_message":"Sun Flare is still on cooldown for 8 turns."}
```
原生行为（`modules/tome/class/Actor.lua:5196 if not self.talents_cd[tid] ... self.talents_cd[tid] = cd`），不是桥的 bug。
但 `inspect` 同时给 `cooldown:10`（基础值）与 `query.cooldown_remaining`（剩余），名字接近；建议把基础值改名 `base_cooldown`，或对"刚学会"补一个 `cooldown_reason:"learned"`。

### 3.5 【P1】`target_geometry` 缺 `selffire` → 我用 Shadow Blast 打了自己 36 点

```json
{"action":{"type":"use_talent","talent_id":"T_SHADOW_BLAST","x":50,"y":15}, ...}
-> "target_geometry":{"radius":3,"range":6,"shape":"ball"}      // 无 selffire
-> log: "MCP_agent-ham-insane-05 hits MCP_agent-ham-insane-05 for 24 darkness damage."
        "MCP_agent-ham-insane-05's darkness area effect hits MCP_agent-ham-insane-05 for 12 darkness damage."
   hp 127.2 -> 90.7
```
原因：`Shadow Blast` 的 `selffire = self:spellFriendlyFire()` 是**函数**，桥只在原生直接给布尔时才写该字段（round4 已记录同类现象）。
**建议**：把 selffire 求值一次后输出布尔（哪怕 `native_precheck_not_run` 也可给 `"selffire":"dynamic"`），否则 agent 无法安全使用 AoE。

### 3.6 【P1】动态字段恒为 null / 需求不透明

```json
{"name":"Sun Flare","query":{"current_costs":{"positive":30},"range":0,"radius":null}}
```
实际半径是 `math.min(8, floor(combatTalentScale(t,2.5,4.5)))`（我读源码才知道 lvl1=2）。
同类：generic 天赋 `readiness` 恒为 `unknown / native_precheck_not_run`；加点失败只给
```json
{"status":"failed","code":"native_progression_rejected","native_message":"Prerequisites not met!"}
```
没说缺哪一项（实为 divi_req2：角色等级 ≥4 且 Mag ≥20）。建议 `native_progression_rejected` 带上缺失项（等级/属性/前置天赋/类别点）。

### 3.7 【P1】动作为 `awaiting_input` 时返回的 `snapshot` 是动作前旧快照（会误判生死）

击杀 Prox 的最后一击：
```json
{"status":"awaiting_input","code":"awaiting_native_input","native_return":true,
 "snapshot":{"player":{"life":47.0,"level":3,"exp":34.12},
             "actors":[{"name":"Prox the Mighty","life":49.1}]}}
```
紧接着 observe 才显示：`life:151, level:4, exp:121.72`，Prox 已消失。若 agent 只看动作返回，会以为"没打中 / 自己只剩 47 血"并做出错误决策（我差点重复施法）。
**建议**：awaiting_input 时标注 `snapshot_stale:true`（或 `snapshot_scope:"before_action"`）。

### 3.8 【P1】部分原生弹窗不进 interaction 系统：`phase=needs_input` 但无 `pending_command.interaction`

```json
{"phase":"needs_input","control":"manual",
 "dialogs":[{"title":"Option unlocked: New Class: #LIGHT_GREEN#Summoner (Wilder)","topmost":true,
             "widgets":[{"kind":"text","text":"In the wilds, ..."}]}],
 "pending_command":{"command_id":"cmd-893","status":"needs_input","input_owner":"manual"}}
{"respond":{"type":"cancel"}} -> {"error":"No pending interaction"}
```
只能 `{"key":"Escape"}`。之后出现的 QuestPopup/LorePopup 才被建模为 `dialog.notice` 并可 `respond option`。
**建议**：只要 `dialogs[]` 有 topmost 弹窗，就至少导出一个 `option/cancel` 交互（或提供 `tome.dismiss`）。

### 3.9 【P2】交互 id 每次刷新，失败回执不自带当前有效 id

```json
{"code":"option_expired","message":"option expired"}
{"code":"answer_type_mismatch","message":"answer type mismatch"}
```
后者发生在 answer_types 明确列了 `cancel` 的 QuestPopup 上（提交 `{"type":"cancel"}` 被拒）——建议核对 cancel 分支。
另外这两个错误都不带当前 `interaction_id`/`options`，agent 必须再 observe 一次才能继续；带上会更省往返。

### 3.10 【P2】`events.entries` 会含没有 `text` 的 `remove` 条目

```python
[e.get('text') for e in s['events']['entries']]  # -> [..., None, None, None]
```
`semantics` 已解释 remove 的含义，但消费方必须对缺字段容错。建议统一带 `text`（或明确 `op:"remove"` 时无 `text`）。

### 3.11 【P2】`list` 的 `items` 类型不一致

- `collection:"inventory"` → `items` 是 **array**
- `collection:"ground_items"` → `items` 是 **object**（空时 `{}`）

同一字段两种 JSON 类型，客户端要写两套解码。建议统一为 array。

### 3.12 【P2】其它小项

- `inspect{kind:"actor", id:"self"}` → `{"code":"actor_not_visible","message":"actor not visible"}`；建议支持 `self` 别名或在错误里说明需要完整 actor id。
- `equipment[].combat` 只有 `apr/dam/damrange/physcrit/physspeed`，**没有 accuracy/defense**，导致无法在桥内解释"为什么近战一直 miss"（我实测 staff 近战 miss 率 >70%）。建议补 `combat_atk/combat_def`（`wielder.combat_def` 已有，武器 atk 缺）。
- `map.exits` 只覆盖当前 ±12 窗口：在 (1,6) 时 `exits:[]`，而在 (0,21) 有 `<`。不能用 `exits` 判断"地图上没有楼梯"（`cells[]` 里的 `is_exit` 同样只在窗口内）。`map` 已带 `memory_scope/merge_scope/window` 说明，建议在 `exits` 旁也标注 `scope:"window"`。
- console `walk` 每步都回整个 `player`（equipment+inventory+stats，约 2.5 KB/步），一次 70 步的 walk 结果极难阅读；建议精简为 `{x,y,life,phase}`。

---

## 4. 做得好的部分（建议保持）

1. **`actors[]` / `player` / `resources` / `effects` / `sustains` 字段准确**：`life_regen:0.25` 正好解释了"日志伤害 vs 血量差"（日志 `hits ... for 13 physical`，血量差 12.77 = 13 − 0.25）。同理可推断 forest troll 有 ~1~2/回合回血（`actors[]` 未暴露 `life_regen`，属可改进的小缺口）。
2. **`target_geometry` 对静态天赋完全准确**：Moonlight Ray `{shape:beam,range:10,piercing:true}`、Searing Light `{shape:ball,radius:1,range:7}`、Shadow Blast `{shape:ball,radius:3,range:6}`，且实测 beam **穿透多个目标**（一次 MR 同时打到 honey tree + bear + bee swarm，日志三条命中）。
3. **`native_message` 与快照字段一致**：冷却拒绝里的剩余回合数与 `observe.talents[].cooldown`、`inspect.query.cooldown_remaining` 完全一致。
4. **`x/y` 目标与 `target_id` 两种寻靶都能用**：本轮绝大多数施法用 `{"x":..,"y":..}`，全部成功。
5. **`progression_categories` 非常好用**：一次给出每个类别/天赋的 `raw_level/max_points/point_cost/requirements/readiness`，加点决策不需要猜。
6. **非法 collection 名的报错已可自我纠正**（round4 的 `accepted:null` 问题已修）：
   `Input should be 'inventory', 'equipment', 'actors', 'talents', 'effects', 'ground_items', 'progression_categories', 'progression_talents' or 'compatibility'`。
7. **免费动作如实反映**：`T_HALFLING_LUCK`、hymn 切换等 `no_energy` 动作 `energy_spent:0` 且 `world_tick_before==world_tick_after`。
8. **`{"map":true}` 现在带 `cells[]`**（round4 报告里说没有），`cells` 与肉眼所见一致（我做了 3 层、数千格的 merge 校验，无冲突）；`node/blocked/block_status/door/is_exit/name` 齐全。
9. **物品链路完整**：`ground.items[].id` → `pickup` → `inventory`/`equipment` 都能闭环；`equip` 的 `wielder` 甚至包含 `on_wear` 的种族修正（Prox's Lucky Halfling Foot 对半身人 -10 三抗/-10 luck，与源码一致）。
10. **`rest` 的停止原因清晰**：`{"status":"completed","code":"native_complete","native_message":"all resources and life at maximum"}`，且 CD 随真实回合递减。
11. 撞墙 `move` 返回 `{"status":"failed","code":"blocked"}`（不耗回合），切层 `change_level` 无楼梯时返回 `native_rejected "There is no way out of this level here."` —— 语义清楚。

---

## 5. 实战结论（非 MCP 问题）

- Anorithil 在 Insane 前期强度全靠 `Searing Light`（光区 4 回合，伤害 1/2）与 `Moonlight Ray`（beam 穿透）的轮转，配合 `Twilight` 把 capped positive 转 negative；1 级近战基本打不中，**不要靠 T_ATTACK 输出**。
- Insane 上 rank 4 的 Prox the Mighty（518 HP）单挑可行，关键在 `Hymn of Perseverance`（20% 眩晕/致盲/混乱抗）+ `Healing Light`（Mag 28 + lvl2 时一次回 151）+ 3 个 Infusion；一旦 `Infusion Saturation` 上脸就只能靠 Healing Light。
- 护送任务奖励可选 `[Improve Magic by +5]`，对法系是即时收益（Mag 28 → 输出约 +20%）。
- `Shadow Blast` 半径 3 但**是 selffire**，近距离用等于自残；`Sun Flare`（self 中心 r2、range 0、30 positive、附 4 回合致盲、无 selffire）才是近身保命 AoE。

---

## 6. 建议的修复优先级

| 优先级 | 项 | 影响 |
| --- | --- | --- |
| P0 | §3.1 切层丢控制 / phase 与可行动性不一致 | 会让 agent 长时间空转、误判 |
| P0 | §3.2 console `walk` 吞错误 | 同上，且掩盖真实原因 |
| P0 | §3.3 `actors[]` 混入友军 + walk 不分阵营 | 有护送任务时 auto-explore 完全不可用 |
| P1 | §3.5 `selffire` 动态时缺失 | AoE 会自伤，agent 无法预判 |
| P1 | §3.7 `awaiting_input` 返回旧 snapshot | 会误判生死/伤害 |
| P1 | §3.8 notice 弹窗无可用交互 | 只能按键，违反"优先 respond" |
| P1 | §3.6 动态字段 null / 需求提示 | 决策依据缺失 |
| P2 | §3.4 §3.9 §3.10 §3.11 §3.12 | 一致性与体验 |

（本次未修改仓库/游戏文件；所有 JSON 证据均来自 `tome-insane5.sh`/`mapjson-insane5.sh` 的原始输出。）
