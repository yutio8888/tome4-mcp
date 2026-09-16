# ToME4 MCP 实机测试报告 — 第十六轮（round16）

- 会话：`MCP_agent-ham-insane-16`（半身人 Halfling / 星月术士 Celestial-Anorithil / Insane / Roguelike）
- 起始：trollmire 深度 1，Lv1，cheat=false
- 结局：**死亡**，Lv2（exp 42.8 / 67.1），位置 trollmire L1 (41,33)，死因 `water imp`
- 局内总信息：探索 2583 格、击杀石头/森林巨魔、狼、鼠、蜂巢树（drenched honey tree，rank2/275HP）等；解锁 Class: Summoner
- 控制台脚本：`tome-insane16.sh` / `map-insane16.sh` / `mapjson-insane16.sh`

---

## 1. 结论摘要

**本轮最严重问题（可复现、附原始 JSON）**：死亡后原生 `List` 死亡菜单**只出现在 `observe.dialogs[]`**（`kind:"list_menu"`），**顶层 `interaction` 始终为 `null`**，因此 `dismiss` 无法选择菜单项（"Restart the same character / Exit to main menu" 等），bridge 永久卡在 `phase:"terminal"`。这与 round15 声称的「终局列表菜单会重挂到 session 并从插件顶层暴露为 `interaction`，`dialog.choice` 带 options」不符。

其余 round10–16 的修复项经实测**大面积正常**（详见第 3 节），只有上述终局菜单暴露 + 少量小瑕疵（见第 4 节）。

---

## 2. 游玩经过（简）

1. 出生在 trollmire L1 出口 `(0,31)`。开 `Hymn of Perseverance`。
2. 用 `walk` 逼近，遇 rank2 stone troll（136HP，带再生，近战砍不动），用 Moonlight Ray（beam，~60/发）+ 微伤近战磨死。
3. 靠 `mapfull` 的 `frontier_count` + 自建 BFS 做系统性探索（脚本见第 6 节）；期间发现：
   - 升级到 Lv2：+3 属性全加 Magic(→22)、Moonlight Ray→3、Chant Acolyte→2。
   - **Searing Light 是"免费"nuke**：`inspect` 的 `current_costs={"positive":-15}`（负数=反而+15 positive），施放实测**不消耗 negative**、positive 回满，伤害 ~44–70，成了主力输出。而 Moonlight Ray 消耗 negative 10。
   - 装备 "cleansing rough leather cap of strength" 后，**施法会被 anti-magic 打断**：`sear failed native_rejected False "MCP_agent-ham-insane-16's Searing Light has been disrupted by anti-magic forces!"`。卸下该帽后恢复正常（装备时还弹了 "Lore found: Nature vs Magic"）。建议文档提示"cleansing=反魔法，法系别穿"。
4. 探索到 L1 尽头：可到达区域全部清空（自建 BFS `reachable frontier = 0`），拿到 `Surefire`（弓）、acid 长弓/投石索、iron helm 等；踩钱自动拾取。
5. 打开 (32,32)/(34,32)/(37,28,30) 的封印门，进入北侧密室，击杀 drenched honey tree（期间触发解锁 Summoner 的 Lore）。
6. 在手动 `goto (64,34)`（下降楼梯）途中，路径沿 y33 走廊经过 `water imp`，第一次 `walk` 正确在 `enemy_visible` 停下（曾提示 life 已从 70 掉到 28.9），但我误判后又重复发 walk 继续赶路，被 water imp 打死。**属测试者失误，非 MCP 缺陷**。

---

## 3. 已验证正常的 MCP 行为（round10–16）

| 项 | 证据/说明 |
| --- | --- |
| `observe.sections` 合法域 & 无 null 残桩 | `sections:["player","effects","sustains","resources","stats"]` 只返回这 6 域，无多余 null 键 |
| `invalid_sections` | `{"observe":{"sections":["player","bogus"]}}` → `{"ok":false,"error":{"code":"invalid_sections"}}` |
| 结构化参数错误 | `rest.turns` / `spend_stat.amount` → `{"ok":false,"error":{"code":"invalid_argument",...extra_forbidden}}` |
| `inspect talent` 顶层几何 | Moonlight Ray 施法后 `target_geometry={"shape":"beam","piercing":true,"selffire":false,"damage_scope":"line","range":10}`；Searing Light `{"shape":"ball","radius":1,"selffire":true,"damage_scope":"area","residual_area_radius":1}` |
| 静态几何诚实 | 函数型 target 静态给 `target_shape:"unknown"`、`selffire:"unknown"`、`damage_scope:"unknown"`（不谎报 single/false）✅ |
| `unknown_talent` | `{"inspect":{"kind":"talent","id":"T_NOPE"}}` → `unknown_talent` |
| `action_ok` 与 `status` 一致 | `failed → action_ok:false`（含 `native_rejected`/`blocked`/`target_lost`/`terminal`/`not_ready`）；`completed → true`；pending 的 `awaiting_input` 为 `null` |
| `native_message` 透传 | "Moonlight Ray is still on cooldown for N turns." / "You do not have enough Negative energy..." / anti-magic 打断文本 |
| `not_ready` 带 code+hint | 死亡后 `wait` → `{"status":"failed","code":"not_ready","action_ok":false,"details":{"hint":"...phase=terminal"}}` ✅（round11） |
| `target_lost` | 目标 actor id 变更后施法 → `target_lost` |
| 顶部 `interaction`（命令内 Lore） | 装备/pickup/walk 触发的 LorePopup：顶层 `interaction={kind:"dialog.notice",native_ui:"LorePopup",options:[...],...}`，`interaction_scope:"owned by the pending command; answer it with tome.respond"` ✅（round13） |
| `respond` 语义 | 返回 `parent_action`（实测 `equip`/`pickup`/`move`/`use_talent`）+ 继承父 `code`（如 `item_action_complete`）+ `response_receipt.state:"applied"` ✅ |
| `character` 面板字段 | `gold`（0.55→3.9，踩钱自动拾取）、`encumbrance.items_total`、`cooldowns`、`die_at` 均在 ✅ |
| 物品 `container_id` | inventory 条目带 `container_id:1`（背包）✅ |
| `list` 集合 | `progression_categories` 给 category/known/readiness；未知 category → `unknown_category` |
| `compact` status | `{"status":true,"compact":true}` 只回状态，不带 snapshot/history/collection ✅ |
| `mapfull`（round16 重点） | 见第 5 节 |
| 封印门 | 撞门 `move` 返回 `blocked/action_ok:false`（能量 0），但门**实际被打开**（后续 `level_map` 显示 `"open door"`）；重发 `move` 即通过 ✅（与 round15 描述一致） |
| `walk` `stop_on_enemy` | 全程 `enemy_visible` / `enemy_adjacent` 正常中断，`moved_steps` 准确；未出现"已有可见敌人就 0 步卡死" |

---

## 4. MCP 问题

### P1（严重）死亡/终局 `List` 菜单未暴露为顶层 `interaction`，导致无法选择菜单项

死亡后 `observe`（含 `detail:"full"`）始终：

```json
"phase":"terminal","actionable":false,"control_lease":"released","control":"manual",
"release_reason":"saving","release_hint":"a native save is in progress","needs_reconnect":true
```

`interaction` 为 **null**，仅 `dialogs[]` 有：

```json
[{"kind":"list_menu","title":"You have died!","topmost":true,
  "options":[{"label":"Message Log"},{"label":"Character dump"},
             {"label":"Restart the same character"},{"label":"Restart with a new character"},
             {"label":"Exit to main menu"}],
  "widgets":[{"kind":"text","text":"Death in Tales of Maj'Eyal is usually permanent..."}]}]
```

`{"connect":"control"}` 后 `control_lease` 变 `held`、`release_reason` 变 `null`，但**顶层 `interaction` 仍为 null**、`phase` 仍 `terminal`、`actionable:false`。

`dismiss` 三种尝试全部失败，且未给出 option_id：

```json
// {"dismiss":{"type":"option"}}   → 参数校验：option_id Field required

// {"dismiss":{"type":"option","option_id":"Exit to main menu"}}
// {"dismiss":{"type":"option","option_id":"0"}}
{"ok":false,"error":{"code":"dialog_not_closed",
 "message":"The native popup could not be closed by the bridge.",
 "details":{"hint":"observe.interaction exposes selectable options when the popup is a list menu; otherwise answer it with a native key. Last attempt: dialog_not_closed"}}}
```

**影响**：无法通过 bridge 执行 "Restart the same character"/"Exit to main menu"，bridge 永久停在 terminal；下一轮只能物理重启游戏。round15 的「终局命令拥有的弹窗会被重挂到 session 并暴露为 `interaction`（`dialog.choice` 带 options/option_id）」在本机未生效。`dialogs[].options` 也不含 `option_id`（只有 `label`），`dismiss` 无法索引。

原始证据：`/tmp/evidence16/death_observe.json`、`/tmp/evidence16/death_dismiss.json`、`/tmp/evidence16/death_observe_sections.json`。

### P2（次要）terminal 的失败 `walk` 缺 `hint`

致命那次 `walk` 返回：
```json
{"status":"failed","code":"terminal","action_ok":false,"hint":null,"moved_steps":3,"player":{"life":-13.8}}
```
round13 要求 failed 一定带 `hint`，此处为 `null`。

### P3（次要）pending 的 `awaiting_input` 中 `action_ok` 为 `null`

`walk` 因 Lore 中断时：
```json
{"status":"awaiting_input","code":"awaiting_native_input","action_ok":null,"moved_steps":9,"player":{"life":68.9}}
```
可接受，但与"真正生效才 true"的表述不一致，建议文档明确 pending 时用 `null`。

### P4（提示）`release_reason:"saving"` 会长期停留

死亡后 `release_reason:"saving"`（"a native save is in progress"）在 4s 后仍在；`needs_reconnect:true` 需要 `connect` 才能拿回租约。属新值，建议文档补充 `saving`。

---

## 5. `tome.map` / `mapfull`（round16 重点核对）

- **`{"mapfull":true}`** 正常返回 `rows`（40 行 × 65 列，本层 65×40）、`legend`、`explored_count`、`frontier_count`、`coverage`、`origin`、`player`。
- **字母表核对**：采样 475 个 viewport 格，用 `mapjson.cells` 逐一比对 `?` 与已知地形，**0 处不一致**（已知/未知判定与玩家地图一致）。
- **道具 `%`**：多次在正确坐标出现（如 (20,23) iron helm、(41,4) tattered paper scrap、(20,0) longbow、(39,30) Surefire、(63,0)/(30,31) 金币）；**踩上去自动拾取后 `%` 从地图消失**（金币自动入袋，无需 `pickup`）。✅
- **`region` 细节**：`{"level_map":true,"region":{...}}`（≤64 格）与 `mapfull` 一致；>64 格返回 `{"ok":false,"error":{"code":"region_too_large"}}`。`region` 用 `cells` 返回（含 `char/blocked/remembered/visible/name/is_exit`），**不是** `rows`（注意与 round16 描述里"format=rows"区分）。
- **`row`/`region` 边界**：`region` 越出地图返回 `region_out_of_bounds`（我把宽度写成 4 落在 x=65 时触发）。
- **deep water 显示为 `.`（passable）**：`block_status:"passable",blocked:false`，且实测可走进 `(35,30)`。因此 `.` 包括水/草/门等，属正常（本层水可通行）。
- **视野外怪物不渲染**：`mapfull` 结果中**完全没有** actor 字形，只有地形/道具/出口（符合设计）。
- **已识别陷阱 `!`**：本轮**从未出现**。途中曾无端掉血（108→68.9），但 `!` 未出现（可能陷阱未识别，或非陷阱伤害）。无法确认渲染是否正常，留待后续。
- **换层/返回保留**：本轮未换层（死在 L1），未验证。
- **出口 `>`**：正确标出 `(0,31)`（回世界地图）与 `(64,34)`（我死前正走向它）。
- **`explored_count`/`frontier_count` 语义**：可用；注意 `frontier_count` 统计的是"未知且紧邻**任意**已知格（含墙）"，因此清空可达区后仍会剩余一批隔墙/水对岸的 frontier（我遇到 `reachable frontier=0` 但 `frontier_count=17`）。建议文档说明该计数含不可达项，或另给"可达前沿"。

---

## 6. 测试方法备忘（供下轮复用）

- 用 `mapfull.rows` 建栅格 + BFS 到最近的"已知且紧邻 `?`"的格子，把路径转成方向序列交给 `walk`；循环直到 `reachable frontier=0`。
  - **注意**：建 BFS 时 `PASS` 要包含 `+`（已知门），否则会误判 `NO FRONTIER`（本轮踩过这个坑，改脚本后立即找到密室）。
- 光有 `+` 仍会 `blocked`：撞门虽报 `blocked`，门其实已开，**重发一次 `move`/`walk` 即可**。
- 距离一律用 `observe.actors[].distance` / `inspect` 的 `target_distance`（原生度量），别用 Chebyshev。
- 施法尽量 `use_talent` 直接带 `target_id`；adjacent 时**别用 Searing Light**（ball radius1、`selffire:true`，会自伤），改用 Moonlight Ray（beam、`selffire:false`）。
- `pickup` 的 `item_id` 每次都要从 `observe.ground.items[]` 现取（对象 id 与坐标绑定，如 `...:ground-39,30:object-6115`）。
- 脚本落在 `/tmp/auto_play16.py`、`/tmp/collect16.py`、`/tmp/explore_loop16.py`（本机临时，不属于仓库）。

---

## 7. 建议的后续动作

1. **修 P1**：让死亡/终局 `List`（`dialogs[].kind=="list_menu"`，`topmost:true`）像普通 `dialog.choice` 一样重挂到 session 并在顶层 `interaction` 暴露带 `option_id` 的 options；或在 `dialogs[].options[]` 里给出 `option_id`，使 `{"dismiss":{"type":"option","option_id":...}}` 可选。当前无法重启/退菜单，会阻塞下一轮自动流程。
2. 给 `terminal` 的失败 `walk` 补 `hint`（P2）。
3. 文档补充 `release_reason:"saving"`、pending `action_ok:null`、`mapfull.frontier_count` 含不可达项（P3/P4/第5节）。
4. 下轮验证：换层/返回后已探索区域保留、已识别陷阱 `!` 的渲染、终局菜单修复后的实际选择流程。
