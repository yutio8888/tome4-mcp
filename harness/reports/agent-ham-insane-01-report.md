# ToME4 MCP 实机试玩报告 — Halfling / Celestial-Anorithil / Insane / Roguelike

- 角色：`MCP_agent-ham-insane-01`（Female Halfling, Celestial/Anorithil, difficulty=Insane, permadeath=Roguelike, cheat=false）
- 会话：2026-09-15 23:27 → 23:47 UTC（约 20 分钟真实游玩，`world_tick` 0 → 2785）
- 试玩方式：只使用给定的 `tome-insane.sh` / `map-insane.sh` 控制台，未重启游戏、未改配置、未退出进程。

---

## 1. 最终状态

| 项目 | 值 |
| --- | --- |
| 生死 | **存活**（未死亡，按收尾指令主动停止） |
| 等级 | **2 级**，经验 `exp=37.9 / 67.1`（距 3 级还差 29.2） |
| 生命 | **107.8 / 107.8**（满血，无任何 debuff） |
| 位置 | 坐标 `(38, 24)`，区域 `trollmire`（`scene.zone_id=trollmire`, `scene.zone_name=Trollmire`, 第 1 层） |
| 资源 | positive 53/53，negative 11.5/33，air 100/100 |
| 装备 | `cruel elm vilestaff of illumination`（回合末刚换上）、`brass lantern`、`linen robe` |
| 背包 | `horrifying mossy mindstar`（拾取演示）、`Scrying Orb`、`elm magestaff`（被替换下） |
| 控制状态 | `phase=ready`, `control=remote`, `revision=3944`, 无可见敌人 |
| 提交动作数 | **255 条**（action 253 + respond 2）；其中 move 166 / use_talent 40 / wait 19 / attack 8 / spend_stat 6 / rest 6 / learn_talent 4 / pickup 3 / set_sustain 1 / equip 1 / respond 1 |
| 底层 MCP 调用 | 708 次（含每次动作前后的 observe/status），transcript 约 40 MB |
| `uncertain` | 全程 **0 次**（无不确定状态、无 revision 冲突、无重复执行） |

状态码分布：`action_complete 97`、`native_complete 4`（rest）、`native_stopped 2`、`item_action_complete 3`、`progression_applied 6`、`native_rejected 5`、`unsupported_progression_talent 3`、`category_locked 1`、`dialog 1`。

---

## 2. 主要经过

### 2.1 开局与加点
- 起始于 trollmire 出生小室西侧 `(0,14)` 的 `<` 上行楼梯旁，小室是封闭的，唯一出口是南侧的 `=`（旧路/草地道路，需查游戏 `grids/forest.lua` 才知道 `=` 是路）。
- 开启 `Hymn of Shadows`（sustain，negative 上限 50→30，regen 0.5）。
- 3 点属性点全部投入 Magic（16→19）。**6 次 `spend_stat` 全部成功且 `energy_spent=0`（不消耗回合）**，属性变化会触发原生 Hymn 重新激活。
- 2 级后又投 3 点 Magic（→22）。

### 2.2 关键战斗
| 敌人 | 数量 | 处理 |
| --- | --- | --- |
| Giant grey mouse / Giant brown mouse / Giant grey rat / Midge swarm | 各 1 | Moonlight Ray 一发（45~68，暴击 68） |
| Forest troll（rank2, ~110-126hp） | 3 | Searing Light + 光域持续伤害 + Moonlight Ray，1v1 打；其中一只靠 Searing Light 的 4 回合光域磨死 |
| Stone troll（rank2, ~128-132hp） | 3 | 同上；一次靠「拉 1 格宽走廊 + 光束穿 2 个目标」一发打两只 |
| Large brown snake | 2 | Searing Light 一发 |
| Wolf | 1 | Moonlight Ray 一发（远程 8 格） |
| Bee swarm | 6 | 光域/光束群伤 |
| Brown bear（rank2, 240~297hp） | 2 | **苦战**：被 Stun、单体 26-28 物理，靠 Regeneration/Wild/Healing 三瓶纹身 + 拉距离 + 光域磨死；其中一只追了我 10+ 格 |
| Honey tree（rank2, 194/333hp, immovable） | 2 | **放弃**：会无限 `Summon` 蜂群，见 §3.6 |

升级：`Welcome to level 2` → 满血 + 3 属性/3 职业/2 通用点。

### 2.3 探索与拾取
- 沿 `=` 旧路探索了出生区 → 南侧大房间 → 东侧走廊 → 东南大场 → 东侧道路，直到 `(38,24)`。
- **发现密室**：`(23,20)` 是一块 `+`「huge loose rock」，撞上去弹出原生 `dialog.confirm`（Open / Leave）。用
  `{"respond":{"type":"option","option_id":"interaction-1:option-1"}}` 成功选 Open，打开了**蜂蜜树宝库**（2 棵蜂蜜树 + 2 只棕熊 + 3 群蜜蜂，总 HP 900+）。
- **拉杆**：`(24,33)` 是 `&`「huge lever」，撞上去未观察到任何可见变化/日志（存疑，见 §3.7）。
- **拾取/装备（桥接验证）**：
  - `pickup` ground-22,34 的 `horrifying mossy mindstar` → `item_action_complete`
  - `pickup` 石巨魔掉落的 `cruel elm vilestaff of illumination` → `item_action_complete`
  - `equip` 该法杖（替换 elm magestaff）→ `item_action_complete`
- 未换层：整局未找到 `>` 下行楼梯，`change_level` 未使用。

### 2.4 用过的技能 / 物品
- 技能：`Hymn of Shadows`(sustain)、`Searing Light`（主输出+4 回合光域）、`Moonlight Ray`（主输出，穿线光束）、`Twilight`（positive→negative 续航）、`T_ATTACK`（法杖近战，6-7 物理，命中差）、`Infusion: Healing` / `Wild` / `Regeneration`。
- 未使用：`Command Staff`（只切换法杖元素，无战斗价值）、`Luck of the Little Folk`。
- 经典连招：`Searing Light` 把敌人打进 4 回合光域 → 站在 1 格宽走廊口 kiting → 光域每回合 17 免费伤害 + `Moonlight Ray`（45-47，暴击 68）。

---

## 3. MCP bridge 表现与发现的问题

> 证据路径
> - 我的逐条原始命令/响应日志：`/workspace/t-engine4/tmp/mcp-play-support/agent-ham-insane-01-raw.jsonl`
> - 控制台完整 MCP transcript（含空响应）：`/workspace/t-engine4/tmp/tome-mcp-validation/sessions/agent-ham-insane-01/play-mcp.jsonl`
> - 决策记录：`.../agent-ham-insane-01/decisions.jsonl`
> - 最后一次完整 observe 快照：`.../agent-ham-insane-01/observed.json`
> - 游戏日志：`.../agent-ham-insane-01/game.log`

### 3.a 技能加点失败：Celestial 职业树完全不在白名单（影响最大的问题）

**现象**：本局 3 个职业点 + 2 个通用点**一个都花不出去**，2 级 Anorithil 全程只有 1 级技能。

```json
// raw.jsonl cmd-9  (learn_talent T_MOONLIGHT_RAY)
{"accepted":true,"code":"unsupported_progression_talent","command_id":"cmd-9",
 "energy_spent":0,"execution_released":true,"status":"failed","uncertain":false,
 "revision_before":359,"revision_after":362,"seq":9}

// raw.jsonl cmd-10 (learn_talent T_SEARING_LIGHT)
{"code":"unsupported_progression_talent","command_id":"cmd-10","status":"failed", ...}

// raw.jsonl cmd-11 (learn_talent T_HEIGHTENED_SENSES，想花通用点)
{"code":"category_locked","command_id":"cmd-11","status":"failed","energy_spent":0, ...}

// 2 级时复测，仍然失败
// raw.jsonl cmd-145 (learn_talent T_MOONLIGHT_RAY)
{"code":"unsupported_progression_talent","command_id":"cmd-145","status":"failed", ...}
```

`play-mcp.jsonl` 行 32 / 34 / 406 为对应记录。

**根因（读源码确认，非回归）**：`overload/mod/mcp_bridge/Progression.lua` 里 `categories/talents` 是**硬编码白名单**，只登记了 `technique/*` 与 `cunning/*`（并用 `requirementAudit()` 校验原生 `require` 函数所在源码行号）。命中不到就返回 `unsupported_progression_talent`；通用点走 `cunning/survival` 等也因 `T_HEIGHTENED_SENSES` 是 tier1 但校验路径不同而落到 `category_locked`。

bridge 自己在 capabilities 里已自我声明这是**已知限制**：

```json
"learn_talent":{"implementation":"limited","scope":"audited_growth_trees",
                "reason":"not_all_classes_supported",
                "detail_collection":"progression_categories"}
"learn_category":{"implementation":"limited","scope":"audited_growth_trees",
                  "reason":"not_all_classes_supported",
                  "detail_collection":"progression_categories"}
```

**影响评估**：对战士/盗贼系职业可用，但**对 Celestial、法师、召唤等职业等于"升级不能加技能"**，Insane 下等于永久 1 级技能打全程，实战影响极大。建议至少把 `celestial/*` 与常用职业树纳入白名单，或在 `spend_stat` 之外提供"只在等级提升时由玩家确认"的兜底路径。

### 3.b 快照冗余字段造成的 token / 带宽浪费

**(1) 无用资源池**：observe 的 `resources` 固定返回 10 个池，对本角色 7 个永远无效（`equilibrium/hate/mana/paradox/psi/stamina/vim`，全程为 0/无 max 意义）：

```json
{"air":{"max":100,"value":100},"equilibrium":{"min":0,"regen":0,"value":0},
 "hate":{"max":100,"regen":0,"value":0},"mana":{"max":106,"value":0},
 "negative":{"max":33,"value":11},"paradox":{"min":0,"regen":0,"value":300},
 "positive":{"max":53,"value":53},"psi":{"max":100,"value":9.4},
 "stamina":{"max":103,"value":14.1},"vim":{"max":104,"value":0}}
```
> 7 个无用池 = 436 B / 617 B（约 71% 的 resources 块）；compact observe 总计 2480 B。

**(2) 每次动作都回传完整 snapshot**：一次典型 `tome.act` 响应 **51,752 B**，其中 `snapshot` = **51,157 B（99%）**：

```
ACT total 51752 -> {'snapshot': 51157, 'events'?..., 'history':136, 'code':22, ...}
OBS total 81890 -> {'map': 65412, 'talents': 6176, 'player': 5931, 'events': 2743, 'ground':211,
                    'collection_refs':820, 'history':136, ...}
```
本局累计 708 次 MCP 调用、transcript 40 MB。绝大多数动作只改了几点 HP/资源，不需要整张地图和全量 talents 数组。

**(3) `player.xp` / `player.xp_next` 恒为 null**（compact observe 路径字段映射错误）：

```json
// compact observe 里看到的 player
{"name":"MCP_agent-ham-insane-01","x":38,"y":24,"life":107.8,"max_life":107.8,
 "level":2,"xp":null,"xp_next":null}
// 同一次 observe 的完整快照里实际字段名是 exp / exp_next
"exp":37.9,"exp_next":67.1
```
控制台 `snapshot_summary()` 取的是 `player['xp']`，而 bridge 给的是 `exp`，于是 **agent 从 observe 永远看不到经验进度**（本局全程只能靠另读 `observed.json` 才知道还差多少升级）。

**(4) `talents` 数组每次动作全量重发**（含 `supported` 等静态字段，6.2 KB/次）。

> 建议：compact 模式只发非满/非零资源；动作响应只在 revision 变化或显式 `include_snapshot` 时附 snapshot，或提供 delta/etag。

### 3.c 未适配的原生 notice 窗口 → 静默交出控制权，且 `interaction=null` 无法 `respond`

**现象**：蜂蜜树召唤蜂群触发 `Option unlocked: New Class: Summoner (Wilder)` 弹出提示窗后，下一次动作直接变成：

```json
{"accepted":true,"code":"dialog","command_id":"cmd-135","energy_spent":1000,
 "execution_released":false,"input_owner":"manual","interruption":"dialog",
 "status":"needs_input","uncertain":false,
 "snapshot":{"phase":"needs_input","control":"manual", ...}}
```
其中 **`interaction` 为 `null`**（同一响应）：

```
phase=needs_input  control=manual  interaction=None  execution_released=False
dialogs=[{"title":"Option unlocked: New Class: #LIGHT_GREEN#Summoner (Wilder)",
          "topmost":true,"widgets":[{"kind":"text","text":"In the wilds, some people..."}]}]
```

**问题**：
1. 文档（`docs/tome-mcp-native-notices-items-0.6.0.md`）说 notice 用 `{"type":"option","option_id":...}` 回答，但这类**无按钮文本 notice** 根本不产生 interaction，`respond` 完全不可用：
   `{"respond":{"type":"cancel"}}` → `{"error":"No pending interaction"}`。
2. 动作被放弃（Wild 纹身没放出去），但 `execution_released=false`，控制权被 held 且 `control` 已变 `manual`；**恢复远程控制必须按原生按键**：`{"key":"Escape"}` 之后才回到 `phase=ready / control=remote`。
3. 复现步骤：任意触发 "Option unlocked" 弹窗（本轮：Honey tree 使用 Summon）→ 发任意 action → 观察 phase/control/interaction。

**建议**：把"可关闭的任意 simplePopup"统一生成为 `dialog.notice` + 一个 Close `option_id`（即使原生没有按钮），并在文档中明确 `control=manual` 时的恢复流程。

### 3.d MCP server 对参数校验失败返回**空响应**（不是结构化错误）

`play-mcp.jsonl` 中有 2 条 `"response": null`，客户端只能看到 `{"_error": null}`：

| 行 | 调用 | 参数 | 结果 |
| --- | --- | --- | --- |
| 9 | `tome.inspect` | `{"kind":"progression"}`（缺 `id`） | `response: null` |
| 203 | `tome.act` | `{"action":{"type":"pickup"}}`（缺 `item_id`） | `response: null` |

**根因**：`server/src/tome_mcp/server.py` 的 `StrictModel` 强制字段（`PickupAction.item_id: str = Field(min_length=1, max_length=128)`），FastMCP 参数校验异常不会进 `structured_content`。

**期望**：像 bridge 层一样返回结构化错误码，例如 `{"ok":false,"error":{"code":"invalid_request", ...}}`。对比之下 bridge 层拒绝非常干净：
```json
// 冷却中
{"status":"failed","code":"native_rejected","native_return":false,
 "snapshot":{"events":{"entries":[{"text":"Moonlight Ray is still on cooldown for 1 turns."}]}}}
// 资源不足
{"status":"failed","code":"native_rejected",
 "events":[{"text":"You do not have enough Negative energy to use Moonlight Ray."}]}
```

### 3.e `pickup` 只能靠 item_id，而 compact observe / 控制台看不到地面物品

- bridge 的完整 observe 有 `ground.items[]`（含 `id` / `x` / `y` / `underfoot` / `pile_size`），capabilities 也声明 `ground_items_read=true`。
- 但 **compact observe 里没有 `ground`**，而且本测试控制台（`agent-play.py`）**没有暴露 `tome.list` 的 `ground_items` collection**（console 仅支持 `action/respond/inspect/walk/key/connect/stop/quit`）。
- 结果：agent 拿不到地面物品 ID，`pickup` 实际不可用；我只好直接读取磁盘上的 `.../observed.json`（其中含 `ground`）才完成两次拾取：
```json
"ground":{"radius":12,"truncated":false,"pickup_scope":"current_tile_only",
 "items":[{"name":"cruel elm vilestaff of illumination",
           "id":"tome-...:level-2:ground-38,24:object-5817",
           "x":38,"y":24,"underfoot":false,"pile_size":1}]}
```
- 成功后返回 `{"code":"item_action_complete"}`，日志 `You pickup ... / picks up ...`，功能本身正常。

### 3.f `walk` 的行为与输出

- 只要**当前有任何可见 actor**，`walk` 第 0 步就中断，返回 `[{"interrupted":{...}}]`，无法用于接近敌人（有敌人时必须逐格 `move`）。本局 21 次 walk 调用里多次出现这种"原地中断"。
- 中断条目只有 `{"interrupted": snapshot}`，**没有 player/actors 字段**，agent 必须再发一次 observe 才知道发生了什么。
- 另外，"撞墙"的 `move` 依然返回 `status=completed`（位置不变），agent 需要对比坐标才能发现没走动（本局在 `(7,39)` 连撞 4 次墙）。

### 3.g 地图图例不完整 / 冗余

- `map.legend` 只声明 `?`（unknown）、`@`（player）、`A`（perceived actor）。实际出现的地形字符需要查游戏源码才能认出，本局遇到的：
  - `=` → `data/general/grids/forest.lua: GRASS_ROAD_*`（旧路，可走）
  - `+` → `huge loose rock`（可挖开的密室墙，触发 `dialog.confirm`）
  - `&` → `data/general/grids/basic.lua: GENERIC_LEVER`（huge lever）
  - `;` → 植被
- 完整快照的 `cells[]` 已经带了 `name` / `block_status` / `door?` / `is_exit?` 等字段，但控制台只转发 `rows`，白白浪费了可判读性。
- 小瑕疵：`resources` 的 `regen` 会以 `0.30000000000000004` 这类浮点噪声出现（无 round）。

### 3.h 表现正常 / 值得肯定的部分

- **控制租约与 revision 全程一致**：255 条动作，`uncertain=false` 全程 0 次，没有 revision 冲突、没有重复执行、没有卡死。
- **原生拒绝信息准确**：5 次 `native_rejected` 都带了原生日志原文（冷却、能量不足），可直接用于纠错。
- **`dialog.confirm`（非 notice 类）走通**：`huge loose rock` 的 Open/Leave 两个按钮 → `option_id` 回答 → 原生回调正确执行（打开密室），`options[].disabled`、`prompt`、`text` 字段齐全。
- **升级/加点流程**：`spend_stat` 立即生效且 `energy_spent=0`（不占回合），`progression_applied` 返回 `previous_value/new_value/points_spent/point_pool`，非常好用。
- **拾取/装备**：`pickup` / `equip` 都返回 `item_action_complete` 并带原生日志（含替换说明）。
- **`rest`**：`native_complete`（"Rested for 18 turns (stop reason: all resources and life at maximum)"）与 `native_stopped`（"stop reason: hostile spotted to the east (giant grey rat)"）区分清晰。

### 3.i 玩法层面的观察（供协调 agent 参考）

- **Insane 下 Celestial Anorithil 只有 1 级技能**（§3.a），输出全靠 `Searing Light`(35) + `Moonlight Ray`(45-68) 两个 1 级技能，DPS 约 15-20/回合，面对 240-300 HP 的棕熊非常吃力。
- **蜂蜜树宝库是不可打的**：2 棵 immovable 蜂蜜树无限 `Summon` 蜂群，玩家无法在消耗战里赢。正确做法是**不要挖开那块 loose rock**，或者挖开后立刻离开（本局靠 1 格宽走廊断 LOS 成功脱身，代价是 1 瓶 Healing + 1 瓶 Regeneration + 从 94 血打到 9.8 血）。
- **1 格宽走廊 + Searing Light 光域**是本职业最有效的战术：光域每回合 17 点免费伤害、`selffire=false` 不会伤到自己，且能同时覆盖多个 funnel 中的敌人。

---

## 4. 收尾状态

- 停手前最后动作：`walk [4,4,4]` 回收石巨魔掉落 → `pickup` → `equip`（均成功）。
- 停手时 `phase=ready`、`control=remote`、满血、无 debuff、无可见敌人，游戏进程与控制台均保持运行（未 kill、未 quit、未改配置）。
- 已按要求通过 Paseo 通知协调 agent。
