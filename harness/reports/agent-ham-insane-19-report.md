# ToME4 MCP 实机测试报告 — 第十九轮（round19）

- 会话：`MCP_agent-ham-insane-19`（半身人 Halfling / 星月术士 Celestial-Anorithil / Insane / Roguelike）
- 起始：trollmire 深度 1，Lv1，cheat=false
- 结局：**死亡**，**Lv5**，exp 248.3，位置 trollmire 深度 3 `(27,29)`
- 死因（`game.log`）：`MCP_agent-ham-insane-19 the level 5 halfling anorithil was seared to death by an elemental crystal on level 3 of Trollmire.`（Elemental crystal 的 Elemental Bolt，51 light 伤害）
- 控制台：`tome-insane19.sh` / `map-insane19.sh` / `mapjson-insane19.sh`
- 本次实机总体完成：L1 全清（含封印门+密室）→ L2（完成 escort「injured seer」，选 +5 Magic 奖励）→ L3 探索并死于 elemental crystal

---

## 1. 结论摘要

**本轮最严重问题（可复现，附原始 JSON）**

1. **P1 `auto_explore` 把友方 NPC 当敌人**：只要视野里有**任何**非玩家 actor（包括护送 NPC），`auto_explore` 一律返回 `enemies_in_sight` 拒绝。根因在桥接自身的前置校验（`overload/mod/mcp_bridge/Runtime.lua:780-784`）：它遍历 `level.entities` 只判断 `Observer.visible()`，**没有**像原生 `RUN_AUTO` 那样判断 `player:reactionToward(actor) < 0`。护送 seer 同行期间 `auto_explore` 完全不可用（只能退回原生按键 `z`）。
2. **P2 原生 yes/no 弹窗（封印门）无法用 `dismiss` 关闭**：桥接把它暴露成只有一个假 `Close` 选项的 `dialog.notice`，`dismiss` 返回 `dismissed:true` 但弹窗立刻重生 → 无限循环。`respond` 也无效（`not_ready`）。只有 `{"key":"KP_Enter"}`（激活焦点按钮 Yes）能真正开门。
3. **P3 死亡 `List` 菜单选择无效（round17 声称的修复并未生效于「选择」）**：`observe.interaction` 确实给出了 `dialog.choice` + 5 个选项（**暴露是对的**），但 `dismiss{option_id}` 返回 `dismissed:true` 而菜单**不执行选择**、`interaction_id` 直接重生（661→662→664）。可用的替代是 `{"key":"KP_Enter"}`（激活当前焦点项，实测打开了 Message Log）。
4. **P4 `key` 通道结果虚报**：按 `z` 触发原生 auto-explore 实际移动了 8+ 格并推进了多回合，`key` 却返回 `status:"stuck", code:"no_progress", moved_steps:1`；按 `a` 成功关闭 Chat 也返回 `stuck/no_progress`。无法据此判断按键是否生效。
5. **P5 `change_level` 触发的 escort Chat 无法应答**：`respond` → `control_lost`（未重连时）／`interaction_expired`（重连后，response 绑定到已释放的 change_level 命令 `cmd-360`）；`dismiss` → `dialog_not_closed`。实测只有 `{"key":"a"}` 能选第一个选项。

其余 round10–19 修复项经实测**大面积正常**（详见第 3 节）。

---

## 2. 游玩经过（简）

1. L1：出生在 `(2,15)`。学 `Chant Acolyte 1`（解锁 Chant of Fortitude/Fortress）、`Moonlight Ray 2`、`Searing Light 2`；开 `Chant of Fortress`+`Hymn of Shadows`；加点 MAG/MAG/CUN。
2. 发现 **Searing Light 是免费高伤主力**：`current_costs={"positive":-15}`（实际回 15 正能量），Lv3-4 时单发 80~104（暴击），且 `project{type="hit"}` 单体、地面光域只打敌人 → **贴脸释放安全**。全程输出以 SL 为主、MR 收尾。
3. L1 探索到 2594/2600、frontier 仅剩 6（隔墙），在东侧 `(64,25)` 找到下行楼梯 → L2。
4. **L2 入口立刻触发 escort Chat**（Mayeba, the injured seer）。由于 P5 无法用 respond/dismiss，用 `key:"a"` 接受。此后 **P1 生效，桥接 `auto_explore` 全程 `enemies_in_sight`**；改用 `key:"z"`（原生 auto-explore）继续，中途在 `(6,38)` 附近由原生探索自然完成 escort（Quest Done）。
5. escort 奖励弹窗（`dialog.choice`，6 个选项：+5 Magic/Willpower、Premonition/Arcane Eye/Vision、解锁 Spell/Divination）同样 **`dismiss` 无效**，用 `key:"a"` 选中 **+5 Magic**。
6. L2 后半段清怪（stone/forest troll、wolf、jelly、worm 等），在 `(64,27)` 找到下行楼梯 → L3。
7. L3：探索中在 `(15,24)` 撞上**封印门**（P2），用 `KP_Enter` 开门；此后经历一次 **`settling` 卡死**（见 4.7），也由 `KP_Enter` 解除。
8. L3 后期在 `(27,29)` 被 3 只怪围住，`Elemental crystal` 的 Elemental Bolt（51 light）把 42 HP 打到 -9 → 死亡。死亡菜单被正确暴露（见 3 节）。
9. 全程未 restart/quit；死亡菜单保持打开状态交给协调 agent。

---

## 3. 已验证正常的 MCP 行为（round10–19）

| 项 | 证据/说明 |
| --- | --- |
| `observe.sections` 合法域 | `["player","actors","effects","sustains","resources","stats","ground","talents","dialogs","events","map","ground_effects"]` 均可用；省略域不出现 null 残桩 ✅ |
| `invalid_sections` | `["player","actors","effects","scene","ground"]` → `{"ok":false,"error":{"code":"invalid_sections"}}`（`scene` 是顶层域但不在白名单，见 4.10） |
| 结构化参数错误 | `spend_stat` 大写 `"MAG"` → `{"ok":false,"error":{"code":"invalid_argument",...}}`；`region` >64 格 → `region_too_large` ✅ |
| `inspect talent` 顶层几何/费用 | `current_costs`、`affordable`、`cooldown_remaining`、`in_range`、`target_geometry`（施法后）均正常；`T_SEARING_LIGHT` 静态 `shape/target_shape:"unknown"`（函数型目标，诚实）✅ |
| 施法后 `target_geometry` | Moonlight Ray `{shape:"beam",piercing:true,selffire:false,damage_scope:"line",range:10}`；Searing Light `{shape:"ball",radius:1,selffire:true,residual_area_radius:1,damage_scope:"area"}` ✅ |
| `unknown_talent` / `target_lost` | 目标 actor 换 id 后施法 → `target_lost`（如 stone troll 死后用旧 id），重新 observe 后正常 ✅ |
| `action_ok` 与 `status` 一致 | `failed → false`（`native_rejected`/`blocked`/`not_ready`/`target_lost`/`enemies_in_sight`）、`completed → true` ✅ |
| `not_ready` 带 hint | `{"status":"failed","code":"not_ready","action_ok":false,"details":{"hint":"the game is not ready for actions (phase=settling)"}}` ✅ |
| `native_message` 透传 | `"Searing Light is still on cooldown for N turns."` / `"You may not auto-explore with enemies in sight."` ✅ |
| `change_level` | `{"status":"completed","code":"level_changed","action_ok":true}`，随后 `control_lease:"released"`，`connect:"control"` 可恢复 ✅ |
| `release_reason/release_hint` | `stop` 后 `release_reason:"stopped"`、`release_hint:"control was stopped explicitly"` ✅ |
| `sheet:true` / `computed`（round19 新） | `computed` 含 `stats/power/crit/speeds/saves/resists/defense/offense/utility/unknown`，`unknown:[]`；死亡前 spell power 27、spell crit 5.9% ✅ |
| `character` 面板字段 | `gold`（19.95）、`encumbrance.items_total`（30.1）、`cooldowns`、装备 `container_id`、物品 `container_id` ✅ |
| `mapfull` / `level_map` 一致性 | 同 8x8 区域逐格比对 `mapfull.rows` 与 `level_map.cells` 完全一致（仅越界列缺失）✅ |
| `mapfull` 语义 | `explored_count`/`frontier_count` 可信（L1 2594/2600 + frontier 6 = 隔墙未知）；`%` 道具、`+` 门、`>` 出口标注正确；视野外怪不渲染 ✅ |
| `tome.map` region | `region` ≤64 格返回 `cells`（含 `char/name/blocked/remembered/visible`），与 rows 视图一致 ✅ |
| 死亡菜单暴露（round17） | `observe` 顶层 `interaction` = `dialog.choice`，选项 `Message Log / Character dump / Restart the same character / Restart with a new character / Exit to main menu`；`dialogs[].kind:"list_menu"` 且 `topmost:true` ✅（但**选择**无效，见 4.3） |
| 封印门 | `move` 撞门未见 `awaiting_input`（本次由原生 auto-explore 触发弹窗）；`KP_Enter` 开门后 `level_map` 显示 `open door`，可通行 ✅ |
| 其它 | `T_COMMAND_STAFF supported:false`；戒指可装备（`titan's copper ring`，+CON/+4 物理抗）；`set_sustain{enabled}` 正常；换层后 sustain/资源保留 ✅ |

---

## 4. MCP 问题（附原始 JSON）

### 4.1（P1，严重）`auto_explore` 对友方 actor 误报 `enemies_in_sight`

现象：视野内只有护送 NPC `Mayeba, the injured seer`（`faction:"allied-kingdoms"`）时，连续多次：

```json
{"status":"failed","code":"enemies_in_sight","action_ok":false,
 "native_message":"You may not auto-explore with enemies in sight.","hint":null}
```

同刻 `observe.actors` 只有该友方 NPC。代码证据（`overload/mod/mcp_bridge/Runtime.lua:780-784`）：

```lua
-- Mirror the native RUN_AUTO guard: a visible hostile refuses the command.
for _,actor in pairs(s.game.level.entities or {}) do
    if actor~=p and actor.__is_actor and Observer.visible(s.game,actor) then
        return {ok=false,code='enemies_in_sight', ...}
```

原生 `Game.lua` 的 `RUN_AUTO` 守卫是 `self.player:reactionToward(actor) < 0 and self.player:canSee(actor) and self.level.map.seens(x,y)`。建议桥接加上 `p:reactionToward(actor) < 0`（并显示具体 actor/方位，模仿原生日志）。
影响：一旦有 escort/召唤物/中立 NPC 同行，`auto_explore` 直接废掉（本局退化到原生按键 `z`）。

### 4.2（P2，严重）封印门 yes/no 弹窗：`dismiss` 假成功且无限重生

```json
{"phase":"needs_input",
 "interaction":{"kind":"dialog.notice","native_ui":"nativePopup","prompt":"sealed door",
   "text":"This door seems to have been sealed off. You think you can open it.\nOpen\nLeave",
   "options":[{"disabled":false,"label":"Close","option_id":"interaction-636:option-1"}]}}
```

`{"dismiss":{"type":"option","option_id":"interaction-636:option-1"}}` → `{"ok":true,"result":{"dismissed":true,...}}`，但弹窗**立即重生**（`interaction_id` 变化），循环 20+ 次无进展。原生实现是 `Dialog:yesnoPopup`（`game/modules/tome/class/Grid.lua:65-67`），只有 Yes/No 两个按钮、焦点在 Yes。
**有效替代**：`{"key":"KP_Enter"}` → `phase:"ready"`，`level_map` 该格变为 `open door`。
建议：把 yesnoPopup 暴露为真实 Yes/No 选项；`dismiss` 无法真正关闭时应回 `ok:false/code:dialog_not_closed`。

### 4.3（P3，严重）死亡 `List` 菜单可暴露但不可用 `dismiss` 选择

```json
{"phase":"terminal",
 "interaction":{"kind":"dialog.choice","interaction_id":"interaction-661","prompt":"You have died!",
   "options":[{"label":"Message Log","option_id":"interaction-661:option-1"},
              {"label":"Character dump","option_id":"interaction-661:option-2"},
              {"label":"Restart the same character","option_id":"interaction-661:option-3"},
              {"label":"Restart with a new character","option_id":"interaction-661:option-4"},
              {"label":"Exit to main menu","option_id":"interaction-661:option-5"}]}}
```

`{"dismiss":{"type":"option","option_id":"interaction-661:option-1"}}` → `{"ok":true,"result":{"dismissed":true,"scope":null}}`，但菜单**没有执行**「Message Log」，而是重生为 `interaction-662`（再试 664）。即：暴露正确，但选择路径未生效、且返回了成功的假象（不是 `dialog_not_closed`）。
**有效替代**：`{"key":"KP_Enter"}` 激活当前焦点项（实测打开 Message Log），随后 `dismiss` 该 `nativePopup` 的 `Close` 可正常关闭、死亡菜单回归。

### 4.4（P4，中）`key` 通道结果虚报 `stuck/no_progress`

按 `z` 触发原生 auto-explore，玩家从 `(2,32)` 移到 `(10,29)`（8 格、多回合），返回：

```json
{"phase":"ready","actionable":true,"status":"stuck","code":"no_progress","moved_steps":1,"native_activity":null}
```

按 `a` 关闭 escort Chat（游戏确实推进） → 同样 `{"status":"stuck","code":"no_progress","moved_steps":1}`；而同一动作在别的时刻又回 `{"status":"settled","code":"key_applied"}`。`moved_steps` 也与实际移动不符。

### 4.5（P5，严重）`change_level` 触发的 escort Chat 无法应答

换层后立刻出现 `Chat`（`native_ui:"Chat"`，`dialog.choice`）。当时（未重连）`respond`：

```json
{"ok":false,"error":{"code":"control_lost","message":"control lost","command_id":"cmd-360","response_id":"resp-00369"}}
```

`connect:"control"` 后短暂出现 `QuestPopup`，`dismiss` 关闭后 Chat 重挂为 `interaction-213`，再 `respond`：

```json
{"ok":false,"error":{"code":"interaction_expired","message":"interaction expired",
 "command_id":"cmd-360","response_id":"resp-00370"}}
```

（response 绑定到已释放的 `change_level` 命令；`Runtime.lua:1223` 要求 `s.active==command`。）
而 `dismiss` 该 Chat：

```json
{"ok":false,"error":{"code":"dialog_not_closed","message":"The native popup could not be closed by the bridge.",
 "details":{"hint":"... otherwise answer it with a native key. Last attempt: dialog_not_closed"}}}
```

**有效替代**：`{"key":"a"}`（Chat 走 `__TEXTINPUT`，`a/b/c...` 选选项，见 `game/engines/default/engine/dialogs/Chat.lua`）+ `__TEXTINPUT`）。同理，escort 奖励弹窗也只有 `key:"a"` 生效。

### 4.6（中）`explore_interrupted` 高频且无可见原因

单次调用只推进约 5 格 / 30–50 tick，就返回：

```json
{"status":"completed","code":"explore_interrupted","action_ok":true,"details":null,"native_message":null}
```

此时 `dialogs/interaction/actors/ground/events` 全为空；统计样本中 **40/40 连续调用**都是 `explore_interrupted`。`code` 语义暗示「被打断」，但没有任何可观察原因，使用者只能盲目重发（也直接导致本局 4.7 的 key 轮询路径）。建议：要么改名（如 `explore_step_budget`），要么在无真实中断时继续跑到真正停下或 `nothing_left`。
（对比：`nothing_left` + `native_message:"There is nowhere left to explore."` 语义清晰 ✅。）

### 4.7（中）`settling`/`needs_input` 卡死，`stop`+`connect` 无法恢复

背景：连续 `key:"z"` 与 `auto_explore` 交错，pending 命令进入 manual handoff：

```json
"pending_command":{"command_id":"cmd-919","execution_released":false,"input_owner":"manual","status":"needs_input"}
```

`observe` 顶层无 `interaction`、`dialogs:[]`。此时：

- `act`（wait）→ `{"status":"failed","code":"not_ready","details":{"hint":"... phase=settling"}}`；auto_explore → `not_ready`。
- `connect:"control"` 无效（`Runtime.lua:966-971` 只把 `orphaned` 收回，`manual` 不收回）。
- `stop:true` 只把租约释放（`release_reason:"stopped"`），pending 命令仍在。
- `abandon:true` → `not_isolated`（要求 `native_error`）。

**有效替代**：反复 `{"key":"KP_Enter"}`（期间夹杂 `key:"5"` 会触发原生 Resting 弹窗）后，`phase` 从 `settling`→`needs_input`，关闭 Resting 弹窗并再次 `KP_Enter` 后回到 `ready`，pending 清空。

### 4.8（低）`equip` 紧接 `pickup` 报 `item_not_owned`，重试即成功

`pickup`（`item_action_complete`）后立即 `equip` 同一 `item_id` → `{"status":"failed","code":"item_not_owned","action_ok":false,"hint":null}`；重新 observe 后用**同一个 id** 再 `equip` → 成功。疑似使用了 pickup 前的快照。

### 4.9（低）`learn_talent` 被原生拒绝时无原因

`T_DUCK_AND_DODGE`（需 DEX 前置）→ `{"status":"failed","code":"native_progression_rejected","point_pool":null,"previous_value":null,"new_value":null}`，无 `hint`/`native_message`。建议附上未满足的前置。

### 4.10（低）杂项字段/文档

- `observe.sections` 白名单不接受 `scene`（`{"ok":false,"error":{"code":"invalid_sections"}}`），但 `scene` 是顶层域且始终返回；文档 `tome.observe` 说明也把 `scene` 列为顶层域，容易误用。
- `sections:["stats"]`（或 `["resources"]`）返回的是 **`player.stats`**，顶层无 `stats` 键，与其它域的形状不一致。
- `enemies_in_sight` 失败有 `native_message` 但 `hint:null`（round13 声称失败命令一定带 hint）。
- `equip` 成功时 `equipment_slot:null`。
- `inspect(kind="talent", id="T_SUN_FLARE")` 的 `radius:null`（函数型 radius 未求值）；`range:0` 正确。
- `inspect(kind="compatibility", id="self")` → `invalid_inspect`（可能需要 session_id 而非 `self`，文档未说明）。
- `observe.events` 在大量战斗回合中几乎不产出条目（例如连杀多只怪后 `cursor` 前进但 `entries:[]`），仅偶发 `Talent ... is ready to use.`。若这是设计（只记录 player_visible_log 的特定行），建议在 `semantics` 中说明。

---

## 5. 关键 raw 证据保存

- 死亡快照：`/tmp/death_observe.json`（`phase:"terminal"`，`interaction-664` 五个选项）
- 封印门弹窗：见 4.2（`interaction-636`）
- 卡死 pending：见 4.7（`cmd-919` / `input_owner:manual`）
- `stale_revision` 于连续 auto_explore 循环中出现过一次：

```json
{"ok":false,"error":{"code":"stale_revision","message":"Observe the current state before acting.","uncertain":false,"command_id":"cmd-64"}}
```

---

## 6. 建议优先级

1. **P1** `Runtime.lua` 的 auto_explore 前置校验加入 `reactionToward(actor) < 0`（并输出 actor/方位）。
2. **P2/P3** 让 `dismiss` 对 yesnoPopup 与 `List` 菜单做**真实选择**；做不到就回 `ok:false/code:dialog_not_closed`，不要假成功。
3. **P5** `change_level` 引发的 native Chat/QuestPopup 应重挂到 session 并被 `respond` 接受（或至少 `dismiss` 可选）；同时修复 `input_owner:"manual"` 后 `connect:"control"` 不能收回的问题（4.7）。
4. **P4** `key` 的 `moved_steps/status` 应反映原生推进（或明确说明不追踪）。
5. **4.6** `explore_interrupted` 语义/行为收敛。
6. 文档：`sections` 白名单补 `scene`（或明确 scene 不可选）、失败命令补 hint、`learn_talent` 拒绝给前置原因。
