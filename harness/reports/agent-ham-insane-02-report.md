# ToME4 MCP 实机试玩报告（第二轮）— Halfling / Celestial-Anorithil / Insane / Roguelike

- 角色：`MCP_agent-ham-insane-02`（Female Halfling, Celestial/Anorithil, difficulty=Insane, permadeath=Roguelike, cheat=false, rank 3）
- 会话：约 2026-09-15 23:53 → 09-16 00:14 UTC（约 21 分钟真实游玩，`world_tick` 0 → 14841）
- 玩法：只通过给定控制台 `tome-insane2.sh` / `map-insane2.sh` 操作；未重启游戏、未改配置、未 kill/quit 任何进程，控制台仍在运行。
- 重要说明：本轮除给定 `action/walk/inspect/list` 外，**额外使用了控制台 `{"key":"z"}`（原生自动探索）**用于覆盖大地图（详见 §3.h）。核心战斗与所有写操作都用给定 action 完成。

---

## 1. 最终状态

| 项目 | 值 |
| --- | --- |
| 生死 | **存活**（未死亡；按要求主动停止，保留进程） |
| 等级 | **2 级**，经验 `exp=2.82 / 67.1` |
| 生命 | **107.8 / 107.8**（满血，无 debuff） |
| 位置 | `(0, 16)`（trollmire 出生区上行楼梯 `<` 上），区域 `trollmire` / Trollmire 第 1 层 |
| 资源 | positive 53/53，negative 33/33，air 100/100（Hymn of Perseverance 生效中） |
| 装备 | `potent elm magestaff`(主手)、`brass lantern`、`linen robe` |
| 背包 | `iron greatmaul of massacre`、`elm magestaff`、`Scrying Orb`、`ametrine` |
| 未用点 | stats 0 / class 0 / generic 0 / category 0 |
| 控制状态 | `phase=ready`, `control=remote`, `revision=17777`, 无可见敌人 |
| 提交动作数 | **537**（`decisions.jsonl` 行数） |
| 底层 MCP 调用 | 1734 条响应：observe 1044 / act 537 / connect 127 / inspect 25 / list 3 |
| `uncertain` | **全程 0 次**（无 revision 冲突、无重复执行、无卡死） |

状态码分布：`action_complete 511`、`progression_applied 11`、`native_rejected 5`、`item_action_complete 3`、`target_lost 2`、`target_not_adjacent 1`、`target_out_of_range 1`、`native_progression_rejected 1`、`insufficient_category_points 1`、`native_complete 1`。

---

## 2. 主要经过

### 2.1 开局 / 探索
- 出生在 trollmire 出生小室附近 `(0,16)` 的 `<` 上行楼梯旁，开启 `Hymn of Shadows`（reserve negative 20，negative 上限 50→30）。
- 手动探索了出生区、旧路（`=`）、中部开阔区、东南大场，随后为覆盖大地图改用 `{"key":"z"}` 自动探索，地图最远触及 `(64,8)`、`(48,34)` 等。
- 全程未找到 `>` 下行楼梯；`change_level` 调用被原生拒绝（见 §3.d）。

### 2.2 关键战斗（全部真实结算）
| 敌人 | 数量 | 处理 |
| --- | --- | --- |
| forest troll (rank2, ~107-119hp) | 3 | `Searing Light`(约 46-49) + `Moonlight Ray`(约 46-90，含 90 暴击) + 光域补刀；一次用 1 格宽走廊 |
| wolf (~44-61hp) | 4 | `Searing Light` / `Moonlight Ray` 1-2 发 |
| black ooze | 1 | `Moonlight Ray` 一发穿线连分裂体一起清（exp +3.6 = 3 kill） |
| fox / giant brown·white mouse / midge swarm / bee swarm / copperhead·large white snake / white jelly / white worm mass | 各 1-2 | 1 发技能解决 |

- 唯一一次受伤较重：森林巨魔贴身 + 蜂群中毒，掉到约 42/94，用 `Infusion: Regeneration` 回满。
- **Insane 下 Celestial 命中/暴击波动很大**：同等级 `Moonlight Ray` 对森林巨魔打出过 46 与 90（暴击），战斗节奏主要靠技能 CD 而不是血线。

### 2.3 升级与加点（本轮重点：确认非 Berserker 职业加点）
升级到 2 级后一次性获得 `class=2, generic=2, stats=6, category=0`。**Celestial 加点确认真的生效**：

```json
// learn_talent T_MOONLIGHT_RAY (celestial/star-fury) —— 成功
{"status":"completed","code":"progression_applied","command_id":"cmd-513",
 "energy_spent":0,"revision_before":6366,"revision_after":6372}
// learn_talent T_HEALING_LIGHT (celestial/light, generic) —— 成功（新学天赋）
{"status":"completed","code":"progression_applied","command_id":"cmd-514"}
// learn_talent T_BLOOD_RED_MOON (celestial/eclipse) —— 成功（新学天赋）
{"status":"completed","code":"progression_applied","command_id":"cmd-522"}
// learn_talent T_HYMN_ACOLYTE (celestial/hymns) —— 成功
{"status":"completed","code":"progression_applied","command_id":"cmd-523"}
```

- `spend_stat`：6 点全加 Magic（16→22，`energy_spent=0` 不占回合），positive 上限随之 50→53。
- `learn_category`：本局 `category=0`，调用 `celestial/circles` 返回干净的 `insufficient_category_points`，因此**未能验证 learn_category 成功路径**。
- 加点后最终天赋：`Moonlight Ray 3`、`Searing Light 1`、`Twilight 1`、`Blood Red Moon 1`、`Healing Light 1`、`Hymn Acolyte 2`、`Halfling Luck 1`；所有点池归零。
- 结论：**第一轮报告 §3.a「Celestial 完全不能加点」的问题在本版本已修复**；`progression_categories` 现把 `celestial/*` 全部标为 `supported:true / coverage:"native_generic"`。

### 2.4 拾取 / 装备
- `pickup` ground-6,3 的 `potent elm magestaff` → `item_action_complete`；`equip` 替换下 `elm magestaff`（返回含替换日志）。
- `pickup` ground-41,31 的 `iron greatmaul of massacre` → `item_action_complete`；`inspect kind=item` 可读 combat/requirements。
- 地面物品 ID 通过 observe 的 `ground.items[]`（含 underfoot 完整列表）获得，**compact observe 本轮已带 `ground`**，不再需要读磁盘。

### 2.5 用过的技能 / 物品
- 技能：`Searing Light`、`Moonlight Ray`、`Twilight`、`Healing Light`（新学）、`Hymn of Shadows`/`Hymn of Perseverance`、`T_ATTACK`、`Halfling Luck`（未用）。
- 纹身：`Infusion: Regeneration`（中毒回血）、`Infusion: Healing` / `Infusion: Wild`（未触发）。
- 其它动作：`rest`（`native_complete`，negative 回满）、`wait`、`change_level`（拒绝）。

---

## 3. MCP bridge 表现与发现的问题

> 证据路径
> - 控制台命令日志：`/workspace/t-engine4/tmp/mcp-play-support/agent-ham-insane-02.log`
> - 完整 MCP transcript（91 MB）：`/workspace/t-engine4/tmp/tome-mcp-validation/sessions/agent-ham-insane-02/play-mcp.jsonl`
> - 决策记录：`.../agent-ham-insane-02/decisions.jsonl`（537 行）
> - 最后完整 observe 快照：`.../agent-ham-insane-02/observed.json`
> - 游戏日志：`.../agent-ham-insane-02/game.log`

### 3.a 技能目标几何：range 有，shape/radius/pierce/selffire 没有（本轮重点）
`inspect kind=talent` 的可用信息（`query` 块）：

```json
// T_MOONLIGHT_RAY
"query":{"range":10,"requires_target":true,"prefill_modes":["actor","position"],
         "target_type":"unknown","base_costs":{"negative":10},
         "affordable":"unknown","costs_complete":false,
         "resource_checks":{"negative":{"operation":"debit","amount":"unknown","reason":"dependency_source_unverified"}}}
// T_SEARING_LIGHT
"query":{"range":7,"requires_target":true,"prefill_modes":["actor","position"], ... }   // 没有 target_type 字段
// T_TWILIGHT
"query":{"range":10,"requires_target":false, ... }
```

结论：
- 好消息：`range`、`requires_target`、`prefill_modes` 可见（我按 range 7/10 决定何时开火，基本有效）。
- **缺口**：不暴露目标**形状/半径/穿透/自伤**。例如 `Moonlight Ray` 在原生数据里是
  `target = {type="beam", range=10}`（穿透直线束），`Searing Light` 是 `ball radius=1 range=7`，
  `Shadow Blast` 是 `ball radius=3`，但接口只给 `target:"runtime"`（顶层）、`target_type:"unknown"`（query），
  `radius` 顶层为 `null`。Agent 无法知道“这是一条能串 2-3 个目标的直线”“这是半径 1 的小球”“会不会自伤”。
  本轮我是靠经验/读游戏数据才知道要沿走廊卡直线、用 Searing 的光域群伤。
- 字段不一致：`T_MOONLIGHT_RAY.query.target_type="unknown"` 而 `T_SEARING_LIGHT.query` 干脆**没有** `target_type`。
- `costs_complete=false`、`affordable:"unknown"`、`reason:"dependency_source_unverified"`：冷却/资源是否够用只能靠试错，或从 `talents[].cooldown` 自己推。

### 3.b 资源消耗元数据有符号/操作语义错误（会把 agent 带偏）
- 实测（同一连招、无移动，正 revision 递增）：

```json
// cmd-531 Twilight 前 observe：positive 53
// cmd-532 Twilight(action_complete)：positive 38.5
// cmd-533 Searing Light(action_complete)：positive 53.0   ← 反而涨回上限

// inspect T_SEARING_LIGHT 却声明：
"base_costs":{"positive":-15}, "resource_checks":{"positive":{"operation":"debit", ...}}
```

- 原生 `data/resources.lua` 里 `positive`/`negative` 没有 `invert_values`，成本按 `incPositive(-cost)` 结算；
  `Searing Light` 数据是 `positive = -15`，等价于 **incPositive(+15)（获得 15 正能量）**，而 `Twilight` 是 `positive = 15`（真正扣 15）。
- bridge 把前者同样标成 `"operation":"debit"`，**语义错误**；`base_costs` 的负号也没有任何说明，容易让 agent 误判成“消耗 15”。
- 建议：区分 cost/gain，或直接透传 `incPositive` 的实际符号；至少不要把它标成 “debit”。

### 3.c `native_rejected` 缺独立原因字段（原因被埋在 events 尾部）
5 次 `native_rejected`（`cmd-38` 冷却、`cmd-501` 冷却、`cmd-6x` 空地点、`cmd-535` 换层等）都**不带** `native_message`：

```json
{"status":"failed","code":"native_rejected","native_return":false,
 "energy_spent":0,"revision_before":783,"revision_after":787,
 "command_id":"cmd-38","snapshot":{"phase":"ready", ...}}
```

原因确实被游戏写进了玩家日志，但混在一大段 `snapshot.events.entries` 的**尾部**（delta 里还夹着一堆上一条动作的旧日志）：

```
EV ... Moonlight Ray is still on cooldown for 1 turns.
EV ... Searing Light is still on cooldown for 4 turns.
EV ... There is no way out of this level here.
```

对比 `native_progression_rejected` **有** `native_message`：
```json
{"code":"native_progression_rejected","native_message":"Prerequisites not met!","command_id":"cmd-512"}
```

统计：`native_rejected 5/5 无 native_message`；`target_lost/target_out_of_range/target_not_adjacent/insufficient_category_points 也无 message`；只有 `native_progression_rejected` 有。
- 影响：agent 必须“猜”失败原因；建议统一加 `native_message` 或 `error.reason`（直接取本回合新增的玩家日志）。
- 附带数据质量：events 里出现多条 `text: null/None` 的空条目（见 `cmd-535` events 尾部）。

### 3.d 未适配 notice 弹窗：本轮未复现（保留第一轮证据）
- 本轮 1734 条响应里 `phase` 恒为 `ready`（1708 次带 phase 的响应），`interaction` 出现 0 次，`dialogs` 出现 0 次，未触发任何 notice/achievement/解锁弹窗，因此**无法复现第一轮 §3.c 的 `interaction=null` + `control=manual` 卡死**。
- 第一轮证据仍在：`/workspace/t-engine4/tmp/mcp-play-support/agent-ham-insane-01-report.md` §3.c（Honey tree 的 “Option unlocked: New Class: Summoner” simplePopup）。
- 仍建议：把可关闭的 simplePopup 统一生成为 `dialog.notice` + Close `option_id`，并在 `unknown_interaction:"manual_handoff"` 时给出可自动恢复的按键动作（目前需要人工 `{"key":"Escape"}`）。

### 3.e 快照/字段过传（较第一轮有改善，但仍有大头）
实测分块（`play-mcp.jsonl` 聚合）：

| 调用 | 次数 | 中位响应 | 其中最大字段 |
| --- | --- | --- | --- |
| `tome.observe` | 1044 | **75.7 KB** | `map` 78.8% / `talents` 8.6% / `player` 7.1% |
| `tome.act` | 537 | **16.4 KB** | `snapshot` 98.5%（`talents` 40.5% / `player` 33.4% / `events` 16.3% / `collection_refs` 5.3%）|
| `tome.connect` | 127 | 50.3 KB | — |

- 改善（相对第一轮）：
  - `resources` 只回传本角色相关的 3 个池（air/negative/positive），不再回传 10 个无效池；
  - `player.exp/exp_next` 字段名正确，compact observe 能看到经验进度（第一轮 §3.b(3) 的 `xp:null` 已修）；
  - act 响应里 `map:{x:null,y:null,rows:null}`，**动作不再带地图**（第一轮 §3.b(2) 的主要浪费已修）；
  - 没有出现空响应 `response:null`（第一轮 §3.d 的面试题本轮未触发，因为没发缺字段请求）。
- 仍存在的浪费：
  - **每次 observe 都传全量 `map.rows`（约 60 KB，占 79%）**，而控制台只是拿它做路线判断；`action()` 每次动作前还固定 observe 一次，所以 537 次 act ≈ 额外 537×75 KB observe。
  - **act 的 `snapshot.talents` 每次全量重发（约 6.2 KB / 30%，含静态 `supported`）**；`player` 对象（含完整装备/inventory 明细）每次 5 KB。
  - `collection_refs` 每次重复 5 条固定 collection 请求。
  - 建议：observe 支持 `include_map`/`map_radius` 与 `only_changed`；act 支持 `include_snapshot=false` 或只回 delta；talents 提供 etag/delta。

### 3.f `walk` / `move` 的静默失败
- **撞墙的 `move` 返回 `completed` 但 `energy_spent=0` 且坐标不变**：

```json
{"status":"completed","code":"action_complete","energy_spent":0,"native_return":true,
 "revision_before":2595,"revision_after":2598,"command_id":"cmd-217",
 "snapshot":{"player":{"x":20,"y":18}}}     // 动作前也是 (20,18)
```

- **`walk` 在墙前会把 8 步全部报成 `completed`，坐标原地不动**（`agent-ham-insane-02.log` 594-603 行）：
  `walk [8×8]` → 8 条 `{"st":"completed","pos":[21,25]}`，一步没动。
- `walk` 的 `stop_on_enemy="visible"` 只要**任何**可见敌人（哪怕 8 格外）就直接第 0 步中断，返回 `{"interrupted": snapshot}`，无法用于接近敌人；中断条不含独立的 `player/actors`（需再 observe）。
- 建议：撞墙返回 `blocked` 或 `status=no_move`；`walk` 提供 `moved_tiles`/`blocked_at`；中断条带上 actors。

### 3.g 控制台额外问题：`{"key":"z"}` 自动探索会在两点间反复横跳
- 由于地图巨大且手动探索很慢，我用了控制台的 `key` 通道发原生自动探索（`{"key":"z"}`）。它能一次性覆盖很远（一次调用世界时间前进约 600-1500 tick），但也暴露出问题：
  连续 10 次 `z`，玩家坐标在 **`(64,8)` 与 `(0,16)` 之间精确来回跳**，`world_tick`/`revision` 每次稳定 +648/+~640：

```
rev  7617 tick  4801  pos (48,34)
rev  8165 tick  5341  pos (48,23)
rev  8353 tick  5521  pos (34,21)
rev 10027 tick  7171  pos (6,3)
rev 11945 tick  9081  pos (64,8)
rev 12593 tick  9721  pos (0,16)
rev 13241 tick 10361  pos (64,8)
rev 13889 tick 11001  pos (0,16)
...（此后一直在 (64,8)/(0,16) 之间往返）
```

- 看起来像自动探索在“已无可探索区域 + 两个可疑目标点”之间 ping-pong（`(0,16)` 是 `<` 上行楼梯；`(64,8)` 很可能是另一侧楼梯/尽头）。控制台 `key` 路径只是 `press(key) → sleep(0.3) → connect() → observe()`，**没有“自动探索是否结束/是否卡住”的信号**，agent 无法区分“还在跑”与“原地打转”。
- 建议：控制台把 `key` 返回包装成 action 风格（含 `phase/status/native_task`），或在 bridge 层暴露原生任务状态，避免长阻塞 + 无进展。

### 3.h 加点相关的原生副作用
- 每花 1 点 `spend_stat`，原生会**重激活 sustain**，日志刷出成对的 `deactivates/activates Hymn of Shadows`（本轮 6 点属性共刷出 11 对，见 `agent-ham-insane-02.log` 515/516 行的 `snapshot.events`）。这会污染 event delta，也让 `event_cursor` 快速前进。属原生行为，但建议 bridge 在 progression 动作里标注/抑制这类噪声。
- `inspect kind=progression` 的 `respec.unlearnable[].reason` 在本局对全部已学天赋都报 `"respec_in_combat"`，即便当时 `actors=[]`（可能是原生“刚受击后仍算战斗”的短窗口）。供参考。

### 3.i capabilities 声明与实现不一致（会误导 agent）
`tome.connect` 的 capabilities 仍写：

```json
"learn_talent":  {"implementation":"limited","reason":"not_all_classes_supported","scope":"audited_growth_trees"}
"learn_category":{"implementation":"limited","reason":"not_all_classes_supported","scope":"audited_growth_trees"}
```

但本版本 `progression_categories` 已把 `celestial/*` 全标 `supported:true` 且 `learn_talent` 成功。而 `inspect progression` 的 `execution_scope` 仍写 “reviewed standard Berserker categories …”。**声明已过期**，会让 agent 以为 Celestial 不能加点。建议改为按实际覆盖动态生成。

### 3.j 表现正常 / 值得肯定
- **控制租约与 revision 全程一致**：537 条动作、1734 条响应，`uncertain=true` 0 次，无重复执行、无卡死；每次 act 都能拿到 `next_command_id`。
- 结构化错误码好用：`target_not_adjacent`、`target_out_of_range`、`target_lost`、`insufficient_category_points` 语义清晰。
- `progression_applied` 返回 `previous_value/new_value/points_spent/point_pool`，`spend_stat` 不占回合，很适合 agent。
- `Searing Light` 的 4 回合光域（`light area effect`）在 events 里明确列出每目标伤害，便于复盘。
- `rest` 区分 `native_complete` / `native_stopped`（“all resources and life at maximum”）。
- `pickup`/`equip`/`inspect item`/`inspect progression`/`list` 均正常。

---

## 4. 收尾
- 停手时 `phase=ready`、`control=remote`、满血、无 debuff、无可见敌人；角色停在 trollmire 出生区 `(0,16)` 的 `<` 上行楼梯上。
- 游戏进程与控制台均保持运行（未 kill、未 quit、未改配置）；未使用 `{"stop":true}`/`{"quit":true}`。
- 已按要求通过 Paseo 通知协调 agent。
