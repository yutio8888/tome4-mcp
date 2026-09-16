# ToME4 MCP 实机测试报告 · 第 7 轮

- 角色：`MCP_agent-ham-insane-07`（半身人 / 星月术士 Celestial-Anorithil）
- 难度：Insane / Roguelike，`cheat=false`
- 会话：`agent-ham-insane-07`（隔离游戏，本轮未重启、未改任何文件）
- 结局：**死亡**（`phase="terminal"`）。L6，在 Ruins of Kor'Pul 1 层 `(11,31)` 被唯一怪 **Ce'Nutira the large white snake**（rank 3.2, L7）击杀，life `-2.886`。
- 进度：清完 Trollmire 1/2/3（击杀 boss **Prox the Mighty**，完成主线任务「Of trolls and damp caves」与 1 次护送），随后进入 Ruins of Kor'Pul 1 并死亡。

---

## 1. 重点问题 1：戒指（FINGER）永远无法装备

### 现象
拾取 `copper ring` 后装备失败，返回 `unsupported_equipment_slot`。

### 复现步骤
1. 在 Trollmire 1 拾取铜戒指，得到 id `tome-1789530513-1648-3-table0x42254110:object-6192`。
2. `inspect item`（原始返回）：

```json
{
  "id": "tome-1789530513-1648-3-table0x42254110:object-6192",
  "type": "jewelry",
  "subtype": "ring",
  "equipment_slot": "FINGER",
  "equipped": false,
  "location": "inventory"
}
```

3. 发送命令：

```json
{"action":{"type":"equip","item_id":"tome-1789530513-1648-3-table0x42254110:object-6192"},"reason":"wear ring"}
```

4. 原始返回（`cmd-35`）：

```json
{
  "accepted": true,
  "code": "unsupported_equipment_slot",
  "command_id": "cmd-35",
  "energy_spent": 0,
  "execution_released": true,
  "input_owner": "remote",
  "revision_before": 774,
  "revision_after": 777,
  "seq": 35,
  "status": "failed",
  "uncertain": false,
  "world_tick_before": 313,
  "world_tick_after": 313
}
```

物品仍留在背包（`equipped=false`），整局都无法装备任何戒指。

### 原因（源码定位）
`overload/mod/mcp_bridge/Items.lua:9` 的可装备槽白名单是：

```lua
local equipment_slots={MAINHAND=true,OFFHAND=true,BODY=true,HEAD=true,HANDS=true,FEET=true,
    CLOAK=true,BELT=true,NECK=true,LITE=true,RING=true,TOOL=true}
```

而 ToME 1.7 引擎里戒指对象的 `obj.slot == "FINGER"`（见上述 `equipment_slot:"FINGER"`）。白名单写的是 `RING`，因此
`Items.lua:188` 的 `if not equipment_slots[record.obj.slot] ... then return failure('unsupported_equipment_slot')`
对戒指恒为真，戒指永远装备不上。

对照：同一白名单里的 `BODY`/`NECK`/`MAINHAND` 均正确，实测 `linen robe of the mountain`（BODY）、
`cleansing copper amulet`（NECK）、`surging elm magestaff of might`（MAINHAND）都能正常装备 → **只有戒指槽的键名写错**。

### 建议
把 `RING=true` 改为（或补上）`FINGER=true`；同时核对是否有其它槽名同样错配（如双戒 `FINGER1/FINGER2`）。

---

## 2. 重点问题 2：`unlearn_talent` 可“免费洗点”（无成本退点重加）

### 现象
不消耗任何物品 / 金币 / NPC 交互，直接退回已加天赋点，并可立即把退回的点加到别的天赋，
等于随地点数重分配（正常 ToME 只在特定 respec 入口、且通常要付费）。

### 复现步骤（角色 L5、正常游玩中，world_tick=82859）
1. 先确认已学：`list progression_talents filter category_id=celestial/sunlight` → `T_SUN_FLARE raw_level=1`。
2. 退点命令：

```json
{"action":{"type":"unlearn_talent","talent_id":"T_SUN_FLARE"},"reason":"test"}
```

3. 原始返回（`cmd-711`，注意 `points_returned=1`、`status=completed`）：

```json
{
  "accepted": true,
  "code": "progression_applied",
  "command_id": "cmd-711",
  "energy_spent": 0,
  "execution_released": true,
  "input_owner": "remote",
  "new_value": 0,
  "point_pool": "class",
  "points_returned": 1,
  "previous_value": 1,
  "revision_before": 87401,
  "revision_after": 87404,
  "seq": 711,
  "status": "completed",
  "uncertain": false,
  "world_tick_before": 82859,
  "world_tick_after": 82859
}
```

4. 复核点数变化：`list progression_talents filter category_id=celestial/sunlight` → `T_SUN_FLARE raw_level=0`（已退掉）。
5. 紧接着把退回的 class 点加到别处（同一 world_tick，未做任何补给/交互）：

```json
{"action":{"type":"learn_talent","talent_id":"T_MOONLIGHT_RAY"},"reason":"test"}
```

原始返回（`cmd-713`）：

```json
{
  "accepted": true,
  "code": "progression_applied",
  "command_id": "cmd-713",
  "energy_spent": 0,
  "execution_released": true,
  "input_owner": "remote",
  "new_value": 4,
  "point_pool": "class",
  "points_spent": 1,
  "previous_value": 3,
  "revision_before": 87407,
  "revision_after": 87410,
  "seq": 713,
  "status": "completed",
  "uncertain": false,
  "world_tick_before": 82859,
  "world_tick_after": 82859
}
```

6. `inspect talent T_MOONLIGHT_RAY` → `level: 4`（原为 3）。

> 结论：`unlearn_talent` → `points_returned=1` → `learn_talent`（别处）三步即完成一次免费 respec，
> 不需要「Talent Respec」道具、金币或城镇 NPC。`unlearn_talent` 走的虽然是原生 `unlearnTalent` 入口，
> 但把只在受限场景才允许的洗点能力开放给了任意时刻的 agent。

### 建议
确认 `unlearn_talent` 的产品意图；若仅供受控 respec，需在 bridge 侧加上与原生一致的 gating（地点/费用/一次性道具），
或至少返回明确错误码而不是静默 `progression_applied`。另外 L5 时用同样方式可反复退点，建议加回归用例。

---

## 3. 重点问题 3：非 MCP 命令触发的原生弹窗无法应答

### 现象
凡是在 **非 MCP 命令**上下文中弹出的原生窗口（原生自动探索 `z`、拾取/升级产生的 Lore、死亡界面等），
`observe.dialogs` 会列出标题和 `widgets(text/button)`，但：
- `widgets` 里没有 `option_id`；
- `pending_command` 为 `null`，没有 `interaction`；
- `respond` 一律返回 `{"error":"No pending interaction"}`。

整局共出现 **16 次** `No pending interaction`。只能改用原生按键绕过，违反“优先 respond、不要用 key”。

### 复现步骤（封印门）
1. 用原生自动探索（控制台 `{"key":"z"}`）走到 Trollmire 1 的 `sealed door (19,10)`，触发 `Dialog:yesnoPopup`。
2. `observe`（原始，节选）：

```json
{
  "phase": "needs_input",
  "actionable": false,
  "dialogs": [{
    "title": "sealed door",
    "topmost": true,
    "widgets": [
      {"kind": "text", "text": "This door seems to have been sealed off. You think you can open it."},
      {"kind": "button", "text": "Open"},
      {"kind": "button", "text": "Leave"}
    ]
  }],
  "pending_command": null
}
```

3. 三种应答都失败：

```json
{"respond":{"type":"option","option_id":"Open"}}  → {"ok": true, "result": {"error": "No pending interaction"}}
{"respond":{"type":"cancel"}}                     → {"ok": true, "result": {"error": "No pending interaction"}}
{"respond":{"type":"option","option_id":"0"}}      → {"ok": true, "result": {"error": "No pending interaction"}}
```

4. 只有原生按键才能继续（`{"key":"Return"}` 后 `phase:"ready"`、门开为 `open door`）。

### 同类窗口
- Lore：`Rod of Recall` / `Sludgegrip` / `Serpent's Glare` / `Nature vs Magic`；
- `Running...`：「You are exploring, press any key to stop.」（有 Close 按钮，无 id）；
- 死亡界面：`You have #LIGHT_RED#died#LAST#!`（有按钮，无 id）。

### 反例（正常工作）
在 MCP 命令内触发的弹窗会被正确接管，例如装备项链触发 `LorePopup`：

```json
"pending_command": {
  "status": "awaiting_input",
  "interaction": {
    "interaction_id": "interaction-1",
    "kind": "dialog.notice",
    "native_ui": "LorePopup",
    "options": [{"label": "Close", "option_id": "interaction-1:option-1"}]
  }
}
```

`respond {"type":"option","option_id":"interaction-1:option-1"}` → `code:"item_action_complete"`，
`response_receipt: {state:"applied"}`。护送多步链（`QuestPopup` → `Chat`）同样可应答。

### 原因（源码定位）
`NativeDialogSeams.lua` / `Interactions.openNotice` 全部以 `Tracker.current()` 为门槛；原生 `z` 自动探索
不在 MCP 命令内，`Tracker.current()` 为空，弹窗落回原生实现，未注册 interaction。
`Interactions.adoptNotice(d, root)` 虽然已存在，但需要 `root.command`，对“无命令”弹窗不生效；
`ObservationDetails.dialogs` 只按 widget 文本投影，天然拿不到按钮回调 id。

### 建议
- 对可关闭的无主原生弹窗（有 `EXIT`/closeable）在 observe 时 adopt 成 `dialog.notice`（提供 `option_id`），
  或让 `dialogs` 暴露可回答的选项 id；
- 至少在 `phase=needs_input` 且无 `interaction` 时给出明确原因/兜底（例如 `unadopted_native_popup`），
  方便客户端决定是否用按键。

---

## 4. 其它问题与观察

### 4.1 物品名残留占位符/颜色标记
ego 物品的 `name` 保留未展开的 `#...#` 占位符，而日志行里是展开后的值：

```
日志：  There is an item here: linen robe of the mountain (+7%) (0 def, 0 armour)
字段：  "name": "linen robe of the mountain (#RESIST#)"
字段：  "name": "cleansing copper amulet of mastery (#MASTERY#)"
```

同理，弹窗标题与 interaction 文本带颜色标记（日志文本已被控制台清洗，二者不一致）：

```
"title": "Lore found: #0080FF#Nature vs Magic"
"text": "#ANTIQUE_WHITE#Quest: #AQUAMARINE#Escort: lone alchemist (level 3 of Trollmire)"
"title": "You have #LIGHT_RED#died#LAST#!"
```

建议：`name`/`interaction.text` 走与日志相同的清洗，或标记 `name_is_raw` 的语义（当前 `name_is_raw:true` 但客户端易误读）。

### 4.2 actor id 不稳定导致 `target_lost`
同一只 red ooze 在可见期间 id 从 `...:level-2:actor-6191` 变为 `...:level-2:actor-15672`；
用旧 id 施法直接返回 `target_lost`（未消耗回合）。建议文档明确“actor id 可能变化、需每次 observe 取新 id”，
或尽量稳定 uid。

### 4.3 `target_geometry` 精度
- `T_MOONLIGHT_RAY`：`{shape:"beam", range:10, piercing:true, selffire:"unknown"}`；
  但我在**贴身（距离 1）**使用时自己未受伤（多次），beams 的 `selffire` 可解析为 `false`。
- `T_SEARING_LIGHT`：报告 `{shape:"ball", radius:1, selffire:"unknown"}`，但引擎里直接伤害是 `type="hit"`（单体），
  半径 1 只作用于残留光域（`sunlight.lua`：`self:project({type="hit"}, ...)` + `addEffect(... radius 1 ...)`）。
  “shape=ball” 会误导 agent 以为它是完整 AoE 核弹。
建议区分“直接命中几何”和“残留区域几何”，或在 `inspect` 里注明。

### 4.4 `respond` 与租约释放的时序
`change_level` 切图会释放租约；若切图过程中弹出交互（如进入新区域立刻触发护送），
在重连前 `respond` 会失败并返回：

```json
{"_error": {"code": "control_lost", "message": "control lost", "command_id": "cmd-721", "response_id": "resp-00731"}}
```

`{"connect":"control"}` 后同一个 `interaction-8` 仍在，respond 成功 `state:"applied"`。
行为可恢复，但错误信息未提示“请先 reconnect”。

### 4.5 其它小项
- `pickup` 必填 `item_id`：裸 `{"action":{"type":"pickup"}}` 返回 `action.pickup.item_id Field required`
  （prompt/规则里写的是裸 `pickup`；且金币会被自动拾取，导致“看起来能拾但校验先失败”）。
- `{"list":{"type":"first","collection":"inventory","limit":50}}` → `extra_forbidden`（不接受 `limit`）。
- `walk` 是控制台层命令、接收**方向数组**；传坐标会得到 `action.move.direction` 校验错误（文档层面易踩）。
- `{"walk":[...]}` 的 `stop_on_enemy:"visible"` 会在敌人 10 格外就停，追远敌需用 `"adjacent"`。
- `attack` 直接命中了 `allied-kingdoms` 的护送 NPC 并造成 47+34 伤害，未见确认/阵营拦截（我误把盟友当目标），
  疑似缺少友伤确认，请评估是否符合预期。
- `spend_stat` 命中每级上限时返回 `stat_level_limit`（明确，good），但未给出上限数值（L5 时 mag 卡在 27）。
- 数值观测（仅记录，未判定为 bug）：L1 时 exp_next=29.7，而 L3 rare 森林巨魔仅给 2.4 exp、L6 rare 黑熊给 6.0，
  升级节奏明显偏慢（Insane 下是否预期由开发侧判断）。

---

## 5. 正常工作的能力（本轮验证通过）

- `observe` / `map` / `mapjson` / `list`（含 `filter.category_id` 的 `progression_talents`）/ `inspect talent|actor|item`。
- `move` / `walk`（方向数组，遇敌中断并返回 `interrupted` 与敌人坐标）/ `wait`。
- `use_talent`：`T_MOONLIGHT_RAY`(beam)、`T_SEARING_LIGHT`(单体+残留光域)、`T_TWILIGHT`(正→负能量转换：
  positive −14.5 → negative 回满)、`T_HEALING_LIGHT`、纹身；返回 `target_geometry` 与准确 `cooldown`。
- `set_sustain`：`T_HYMN_OF_DETECTION` 开/关（切图后清空，需重开）。
- `attack` / `pickup(item_id)` / `equip`(BODY/NECK/MAINHAND) / `rest{max_turns}`(`code:"native_complete"`)。
- `spend_stat`（`str/dex/mag/wil/cun/con`）。
- `change_level`：`code:"level_changed"`，`control_lease:"released"` + `needs_reconnect:true`，重连后可继续；
  切图触发交互时返回 `code:"awaiting_native_input"` 且 `level_changed:true`。
- 多步交互链：`QuestPopup`(notice, Close) → `Chat`(choice, 2 选项) 均可用 `option_id` 应答，`response_receipt.state:"applied"`。
- 死亡：最终动作返回 `code:"terminal"`，其后 `observe` 为 `phase:"terminal", actionable:false`（未见 `recovery:fresh_load_required`）。
- `unlearn_talent` / `learn_talent` 的错误码清晰：`native_progression_rejected` + `native_message:"Prerequisites not met!"`、
  `insufficient_class_points` / `insufficient_generic_points` / `insufficient_category_points`。
- 观察不改变状态：多次 observe 未消耗 RNG/回合。

---

## 6. 游玩时间线（简）

1. **Trollmire 1**（`level-2`，出生）：清 jelly/ooze/midge；拿到 copper ring（装备失败，见 §1）、
   `linen robe of the mountain`（BODY，装上）；开封印门（按键兜底，见 §3）；进小 vault 拿
   `surging elm magestaff of might`（MAINHAND）、`cleansing copper amulet`（NECK，触发 Lore 交互）、
   healing infusion、shielding/shatter rune。L1→L3。
2. `change_level` 下到 **Trollmire 2**（`(64,5)` 下行阶梯），`connect control` 继续。
3. **Trollmire 2**：清怪升 L3；某次原生 Lore/任务弹窗后租约释放，reconnect 后继续；打到无路可探。
4. `change_level` 下到 **Trollmire 3**：一进图即触发「lone alchemist」护送（3 步交互链全部应答成功），
   击杀 boss **Prox the Mighty**（L3→L5，任务「Of trolls and damp caves」完成），拾得 Sludgegrip 等。
5. 逐层上行回 **世界地图**（`level-7`），走到 `Ruins of Kor'Pul` 入口并 `change_level` 进入（再次触发护送，接受）。
6. **Ruins of Kor'Pul 1**（`level-8`）：护送「lost defiler」成功；随后在 `(11,31)` 被多只 rare/unique 围攻，
   life 9.0 时最后一击返回 `code:"terminal"` —— **死亡**，L6，exp 5.82/380.6。

---

## 7. 待办 / 建议优先级

| 优先级 | 事项 | 位置 |
| --- | --- | --- |
| 高 | 戒指（FINGER）无法装备 | `Items.lua:9` 白名单补 `FINGER=true` |
| 高 | 非 MCP 命令触发的原生弹窗无 `option_id`、`respond` 返回 No pending interaction | `NativeDialogSeams`/`Interactions.adoptNotice`、`ObservationDetails.dialogs` |
| 高 | `unlearn_talent` 免费洗点（任意时刻退点重加） | Progression 侧 gating |
| 中 | `respond` 在租约释放时返回 `control_lost` 但未提示先 reconnect | 错误信息/文档 |
| 中 | 物品名/弹窗标题残留 `#...#` 标记 | 字段清洗 |
| 低 | actor id 不稳定 → `target_lost` | 文档/id 稳定性 |
| 低 | `target_geometry` 的 `selffire` 未解析、Searing Light `shape=ball` 误导 | TalentQuery |
| 低 | `pickup` 必填 `item_id`、`list` 不接受 `limit`、`walk` 语义文档 | RULES/文档 |
| 待评估 | `attack` 命中 allied-kingdoms 无确认 | Actions/Items |
| 待评估 | Insane 经验节奏偏慢 | 数值观测 |
