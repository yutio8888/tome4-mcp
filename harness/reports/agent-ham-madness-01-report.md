# ToME4 MCP 实战测试报告 — `agent-ham-madness-01`

- 角色：`MCP_agent-ham-madness-0`（Halfling / Celestial-Anorithil，Madness，Roguelike，cheat=false）
- 测试者：游戏测试 agent（仅通过 `tome.sh` / `map.sh` / `send.sh` 接口操作，未改动游戏与 addon 文件）
- 会话：`agent-ham-madness-01`，控制台 `agent-play.py` 常驻
- 报告时间：2026-09-15 ~14:20 UTC

---

## 1. 最终状态

| 项目 | 值 |
| --- | --- |
| 生死 | **存活**（`phase=ready`，`control=remote`，`die_at=0`） |
| 等级 / 经验 | **Lv2**，`exp 41.48 / 67.10`（`exp_next` 为升级阈值） |
| 生命 | **211.8 / 211.8**（满，已 `rest` 到满并确认无敌人） |
| 位置 | **(6, 19)**，区域 **Trollmire (2)**，`level_instance_id = level-3` |
| 起始 | (0, 30)，Trollmire (1)，`level_instance_id = level-2` |
| 资源 | positive 53/53，negative 33/33 |
| 装备 | `elm vilestaff`(MAINHAND) / `brass lantern`(LITE) / `linen robe`(BODY) |
| 背包 | `Scrying Orb`、`citrine`；另有击杀自动收集材料（`length of troll intestine`、`green worm`）与若干金币 |
| 属性 | Mag 21，Con 11，Cun 13(+3)，Dex 10(+3)，Str 10(−3)，Wil 10 |
| 未用点 | stats 0；**class 3 / generic 2（无法通过 bridge 花掉，见 §4.6）** |
| 战绩 | 击杀 31 只；升级 1 次（→ Lv2） |
| 动作量 | **3911 条带 `command_id` 的动作命令**（控制台日志 5119 行），另加大量 `{}` observe（`map.sh` 每次也是一条） |
| 世界时间 | `world_tick` 0 → 32269 |
| 墙上时间 | 13:12 → 14:20 UTC（约 **68 分钟**） |
| 结束方式 | **未死亡**，由测试者按“收尾指令”主动停止；角色已停在 (6,19) 满血无敌人状态，游戏进程与控制台保持运行 |

最终 observe（原始）：

```json
{"ok":true,"result":{"phase":"ready","control":"remote","revision":43741,"world_tick":32269,
 "level_instance_id":"level-3",
 "player":{"name":"MCP_agent-ham-madness-0","x":6,"y":19,"life":211.8,"max_life":211.8,"level":2,"xp":null,"xp_next":null},
 "resources":{"positive":{"max":53,"value":53},"negative":{"max":33,"value":33}, ...},
 "actors":[],"effects":[],"dialogs":[]}}
```

最终 `inspect actor`（`id = tome-1789477928-1825-3-table0x41439280:level-3:actor-2394`）：

```json
{"level":2,"exp":41.48,"exp_next":67.10000000000001,
 "unused_stats":0,"unused_talents":3,"unused_generics":2,
 "life":211.8,"max_life":211.8}
```

---

## 2. 主要经过

### 2.1 Trollmire (1)（`level-2`，起始 (0,30)）

1. **开局**：确认 `phase=ready / control=remote`，`set_sustain T_HYMN_OF_SHADOWS enabled=true` 成功（`action_complete`，negative 上限 50→30）。
2. **早期小怪**：giant white mouse、wolf、midge swarm、fox、giant brown mouse。用 `T_MOONLIGHT_RAY`（约 41–57 伤害）+ `T_SEARING_LIGHT`（32–47 + 圣光范围伤害）点杀。
3. **第一只 forest troll（rank 2，Lv3，305 HP）** 在 (12,37) 附近遭遇，站桩对拼打死（Moonlight Ray / Searing Light / 法杖平砍 5 伤害交替），未掉血太多。
4. **关键战斗：1v4 精英森林巨魔**。(25,33) 附近一次刷出 3 只 forest troll + wolf + fox + 2 只老鼠；退到 y=25 与 y=39 的 1 格宽走廊后逐个打死。
   - 其中 (7,25)–(24,37) 一带刷出 **4 只 Lv7 rank2 forest troll（455 / 419 / 533 / 350 HP）**，`combat_spellresist` 高达 **0.56**，`combat_physresist 1.37`，平砍只打出 4–5 点。
   - 靠 1 格宽走廊 + `T_INFUSION:_REGENERATION_1`（约 +20 HP/回合、持续 5 回合）撑住，单只 troll 打约 15 回合，最终 4 只全歼，生命一度从 104 → 194 回满。
   - 这段也暴露了“圣光范围伤害”机制：`MCP_agent-ham-madness-0's light area effect hits Forest troll for 16–24 light damage.`，是 AoE 主要输出来源。
5. **升级 → Lv2**（`Welcome to level 2 [MCP_agent-ham-madness-0].`），max_life 194 → 207.8；随后 6 点属性：**5×mag + 1×con**（全部返回 `progression_applied`）。
6. 使用 `learn_talent` 尝试加点 → **全部失败**（见 §4.6）。
7. **找楼梯**：用自写 BFS 探索器扫完整层，在 (64,14) 找到 `>`；`change_level` → `code=level_changed`，进入 Trollmire (2)。

### 2.2 Trollmire (2)（`level-3`，入口 (0,22)）

1. 换层后控制权被置为 `manual`，随后 402 条命令全部无效（见 §4.1），用 `{"connect":"control"}` 恢复 `remote`。
2. 继续系统探索整层（约 30×? 的迷宫，实际探到 x≈62），路上依次清掉：poison ivy、fox、midge swarm、stone troll ×2、copperhead snake、large brown snake、green worm mass、wolf ×2 等。
3. 中途 `rest` 被怪打断，bridge 明确回报 `stop_reason`（见 §4.5）。
4. 自动拾取：移动中触发了 `MCP_agent-ham-madness-0 picks up (b.): citrine.`，以及多次 `You pickup 0.XX gold pieces.`；`pickup` 动作本身**无法使用**（见 §4.7）。
5. 未死亡；按收尾指令回到安全状态（`rest` 满血、`actors=[]`）后停止。

### 2.3 用过的技能与物品

| 技能/物品 | 用途 | 备注 |
| --- | --- | --- |
| `T_HYMN_OF_SHADOWS` | 维持技（唯一成功启用的 sustain） | 启用后 negative 上限 50→30 |
| `T_MOONLIGHT_RAY` | 主力远程（41–57 darkness） | 每次 10 negative，negative 恢复仅 0.5/回合 → 必须靠 Twilight 补 |
| `T_SEARING_LIGHT` | 副输出（32–47 light，+圣光 AoE 16–24 × 邻近敌人） | 消耗 positive 但实测**反而回满 positive**（cost 显示 `positive: -15`） |
| `T_TWILIGHT` | 把 positive 转 negative（+15 neg / −15 pos） | 本局唯一可行的 negative 续航手段 |
| `T_ATTACK`（法杖平砍） | 技能 CD 时填空 | 对高护甲敌人只有 4–5 伤害，命中率低 |
| `T_INFUSION:_REGENERATION_1` | 关键保命（+20/回合 ×5） | 用后出现 `Infusion Saturation`，9 回合内其它纹身不可用 |
| `T_INFUSION:_HEALING_3` / `_WILD_2` | 备用，本局未成功用到 | 被 Saturation 挡住 |
| `rest` | 战后回满 | 返回 `native_complete` |
| 物品 | 无主动使用 | 背包只有 Scrying Orb / citrine，无可用消耗品 |

---

## 3. bridge 表现好的方面（先说优点）

- **动作通道稳定串行**：3911 条命令无“卡死/半执行”状态；`execution_released`、`revision_before/after`、`world_tick_before/after`、`energy_spent` 基本每单都有，便于对账。
- **错误码语义清晰**（本局实际遇到）：`target_lost`、`target_not_adjacent`、`actor_not_visible`、`native_rejected`、`control_lost`、`talent_not_in_growth_tree`、`unsupported_progression_talent`、`level_changed`。
- **`rest` 的结果字段很好用**：`stop_reason` + `turns_executed` + `native_message`，见 §4.5。
- **`spend_stat` 结果字段完整**：`point_pool / points_spent / previous_value / new_value`。
- **增量事件日志（本版新增）很好用**：`events.cursor / line_id / observed_world_tick / op=append|remove`，颜色标记已剥离，战斗判定基本靠它（例如 `MCP_agent-ham-madness-0's light area effect hits Forest troll for 16 light damage.`）。
- **`walk` 遇敌自动停下**、`rest` 受伤/见敌自动停下，对“无人值守”是安全设计。

---

## 4. MCP bridge 表现与发现的问题（按严重度）

> 证据路径统一说明：
> - 控制台原始响应：`/workspace/t-engine4/tmp/mcp-play-support/agent-ham-madness-01.log`（5119 行 / 7.18 MB）
> - 会话证据目录：`/workspace/t-engine4/tmp/tome-mcp-validation/sessions/agent-ham-madness-01/`（`play-mcp.jsonl`、`decisions.jsonl`、`game.log`、`observed.json`、`candidate.zip`、`input.json`、`pid`、`runtime/`）
> - 事件游标：`/workspace/t-engine4/tmp/mcp-play-support/agent-ham-madness-01.events-cursor`（终值 1314）

### 4.1 【严重】`change_level` 后控制权静默降级为 `manual`，且失败被藏在 `result._error` 里

**现象/证据**：`change_level` 自身的返回就带 `input_owner: "manual"` 与 `interruption: "scene_changed"`，但**同一条 result 里 `snapshot.control` 也是 `manual`，`status` 仍是 `completed`**，很容易被当成成功。之后所有动作变成：

```
log line 873  {"ok": true, "result": {"code": "level_changed", "command_id": "play-00749",
  "input_owner": "manual", "interruption": "scene_changed", "level_changed": true,
  "status": "completed", ..., "snapshot": {"phase": "ready", "control": "manual", ...}}}

log line 877  {"ok": true, "result": {"_error": {"ok": false, "result": null,
  "error": {"code": "control_lost", "message": "control lost", "uncertain": false,
  "command_id": "play-00750"}},
  "snapshot": {"phase": "ready", "control": "manual", ...}}}
```

**影响**：顶层 `ok: true`、`result.status` 缺省，只有 `result._error.error.code` 才是真错。本次因此**连续 402 条命令全部无效**（日志 877–1411 行，全部 `control_lost`），我把“位置没变”误判为“前方是墙”，自写探索器空转了 400 步（约 10% 的会话预算），并污染了探索用墙表。恢复需要显式 `{"connect":"control"}`（日志 1412 行恢复 `control: "remote"`）。

**复现**：走到 `>` 上 → `{"action":{"type":"change_level"}}` → 再发任意 move → 观察 `result._error.error.code == "control_lost"`。

**改法**：
1. `change_level` 的成功返回里显式给出 `control: "manual"` 和 `next_action_requires: "reconnect"`，或直接返回 `status: "needs_reconnect"`。
2. `control_lost` 必须走**顶层** `status: "failed" / code: "control_lost"`，与其它错误码一致；`_error` 这种“第二套错误信封”应废弃或至少并存顶层码。
3. 提供 `{"action":{"type":"take_control"}}` 或让任意动作自动重新获取租约（可选 `auto_reacquire: true`），避免客户端必须知道 console 私有命令 `connect`。

### 4.2 【严重】`learn_talent` 对非预审职业完全不可用（本局 3 职业点 + 2 通用点全部作废）

**现象/证据**：Lv2 后逐个尝试：

```json
T_MOONLIGHT_RAY  -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_SEARING_LIGHT  -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_TWILIGHT       -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_HEALING_LIGHT  -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_BARRIER        -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_STARFALL       -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_SUN_FLARE      -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_PROVIDENCE     -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_HALFLING_LUCK  -> {"status":"failed","code":"unsupported_progression_talent","ev":[]}
T_HYMN_OF_SHADOWS-> {"status":"failed","code":"talent_not_in_growth_tree","ev":[]}
T_BOGUS          -> {"status":"failed","code":"talent_not_in_growth_tree","ev":[]}
```

`inspect(kind="progression", id="player")`（**注意：不带 `id` 时返回空，见 §4.8**）显示角色全部 Celestial 树 `supported:false`：

```
pools={"category":0,"class":3,"generic":2,"prodigy":0,"stats":0}
celestial/chants      supported=False known=True generic=True  [T_CHANT_* ×4 全 False]
celestial/hymns       supported=False known=True generic=True  [T_HYMN_* ×4 全 False]
celestial/light       supported=False known=True generic=True  [T_HEALING_LIGHT,BATHE_IN_LIGHT,BARRIER,PROVIDENCE 全 False]
celestial/star-fury   supported=False known=True               [T_MOONLIGHT_RAY(1),SHADOW_BLAST,TWILIGHT_SURGE,STARFALL 全 False]
celestial/sunlight    supported=False known=True               [T_SEARING_LIGHT(1),SUN_FLARE,FIREBEAM,SUNBURST 全 False]
celestial/twilight    supported=False known=True               [T_TWILIGHT(1),JUMPGATE,MIND_BLAST,SHADOW_SIMULACRUM 全 False]
celestial/eclipse     supported=False known=True
race/halfling         supported=False known=True generic=True
cunning/survival      supported=True  known=False  (未解锁 → 也点不了)
```

`README.md` 也自述“本版审核了普通 Berserker 可用的 11 类技能树”。**结果：非 Berserker 角色在 bridge 里完全无法加点**（属性点可以，技能点不行）。

**影响**：对一个“用 MCP 真正玩一局”的 agent 来说这是硬伤——升级只涨 stats，技能永远 Lv1，Madness 下战力会迅速落后。

**改法**：
1. 用**统一的数据驱动路径**替代逐树白名单：调用原生 `LevelupDialog:learnTalent(host, tid, true)`（源码 `Progression.lua:485` 已在用），把“是否支持”收敛成“原生是否允许 + 该 talent 的 `on_learn`/`on_unlearn` 回调是否安全”，而不是按职业预审。
2. 短期至少：(a) `inspect progression` 每个 `supported:false` 的 talent 给出 `unsupported_reason` 与预计支持版本；(b) `learn_talent` 失败时在 events 里写明“该技能树尚未适配，可用 `needs_input` 交给玩家手动加点”；(c) 增加 `needs_input` 回退：打开原生升级界面并请求玩家操作（现有规范已有该模式）。
3. 文档侧明确写出“当前已适配的职业/树清单”，避免 agent 反复试探（本局我发了 11 次探测命令才确认）。

### 4.3 【中】`native_rejected` 不带原因，真实原因只在增量日志里

**现象/证据**：

```json
{"status":"failed","code":"native_rejected","command_id":"play-00036","native_return":false,
 "revision":735,"energy_spent":0,"world_tick_before":276,"world_tick_after":276,...}
```
同一条命令的 `events.entries`：
```
You do not have enough Negative energy to use Moonlight Ray.
Searing Light is still on cooldown for 1 turns.
```

**影响**：agent 只能靠正则解析英文日志才知道是“冷却中”还是“资源不足”，而二者策略完全不同（等 vs. 转资源）。

**改法**：`native_rejected` 增加机器可读字段，例如
`"rejection": {"reason": "insufficient_resource", "resource": "negative", "required": 10, "available": 5.5}` 或 `{"reason":"cooldown","turns":1,"talent":"T_SEARING_LIGHT"}`。

### 4.4 【中】`inspect(kind="talent")` 的可用性查询会误报 `affordable: true`

**现象/证据**：negative 实际只有 5.5 时：

```json
{"id":"T_MOONLIGHT_RAY","query":{"affordable":true,"base_costs":{"negative":10},
 "current_costs":{"negative":10},"costs_complete":true,"cooldown_remaining":0,
 "readiness":"unknown","readiness_reason":"target_required","query_is_advisory":true}}
```
随后 `use_talent` 被 `native_rejected`。

**影响**：`query_is_advisory` 虽然有，但 agent 最自然的判断就是 `affordable`，误报会导致白跑一条命令 + 需要解析日志回退。

**改法**：`affordable` 必须基于当前资源；`readiness` 增加 `insufficient_resource` / `on_cooldown` 这类确定值（目前是 `unknown` + `target_required`）。同时给 `query` 增加 `estimated_damage` / `effective_range`（见 §5）。

### 4.5 【低】`rest` 的 `code` 与动作语汇不一致，但字段本身很好用

**证据**：

```json
{"code":"damaged", "native_message":"taken damage", "status":"completed",
 "stop_reason":"damaged", "turns_executed":1, "max_turns":40, ...}
{"code":"native_stopped", "native_message":"hostile spotted to the northwest (wolf)",
 "status":"completed","stop_reason":"native_stopped","turns_executed":0, ...}
{"code":"native_complete", ...}   // 正常睡满
```

**影响**：`completed` 统一出现，但 `code` 在 `action_complete / native_complete / damaged / native_stopped` 间漂移；客户端若只 switch `code` 会漏判“被打断”。

**改法**：统一 `code` 为 `action_complete`，把差异放到已有 `stop_reason`（已经很清晰）里；或冻结一份 `code` 枚举表写进 `api-fields.md`。

### 4.6 【中】被阻挡的 `move` 返回 `completed`，且不消耗回合——`walk` 会静默烧步

**证据**（同一格连发 10 次 north，全部“成功”）：

```
{"status":"completed","code":"action_complete","revision_after":2864,"tick":1862,
 "pos":{"x":35,"y":30,"life":194,"max_life":194,"level":1}}   ← 位置与 tick 都没变
（前一次 observe：tick=1862, pos=(35,30)）
```
`walk` 同样如此，例如 `[6,6,6,6]` 在死路处连续返回 4 条 `action_complete`，`x/y` 完全相同。

**影响**：agent 无法区分“走了一格”和“撞墙”，必须自己比对 `world_tick`/位置；`walk` 在迷宫里会把整串步数浪费在墙上（我实测一次 35 步的 walk 只有 8 步生效）。

**改法**：撞墙返回 `status:"failed"` 或至少 `code:"blocked"`（可保持不消耗回合），并在 `walk` 结果里给出 `moves_planned / moves_executed / blocked_at`。

### 4.7 【中】`walk` 只要视野内有敌人就立刻中止，哪怕敌人很远

**证据**：`{"walk":[8,8,8,8],"reason":"..."}` → 在“起点本来就看得见 (31,29) 的 mouse”时，结果为

```json
[{"interrupted": {"phase":"ready","control":"remote",
   "player":{"x":25,"y":37,...},
   "actors":[{"name":"giant white mouse","x":31,"y":29,"life":38.7}]}}]
```
`path` 里 0 步执行（位置未动）。另一次是在走了 2 步后才中断。

**影响**：探索时被迫退回逐格 `move`，命令数暴增（本局 3911 条命令里绝大多数是探索 move）。

**改法**：`walk` 增加参数 `stop_on_enemy: "adjacent" | "visible" | "never"`（默认 `adjacent`），或 `stop_distance: N`；返回值里给出 `interrupt_reason`。

### 4.8 【中】`pickup` 缺 `item_id` 时是静默 no-op，且**快照根本不暴露地面物品**

**证据**：

```json
$ tome.sh '{"action":{"type":"pickup"},"reason":"probe pickup"}'
{"ok": true, "result": {"_error": null, "snapshot": {...}}}
# jq 取键：result_keys = ["_error","snapshot"]；code=null、status=null
```
`observe` 的顶层键固定为：
`["actors","control","dialogs","effects","events","level_instance_id","map","phase","player","resources","revision","talents","world_tick"]` — **没有 items/ground/floor**。

**影响**：`pickup` / `equip` / `use_item` 理论上要 `item_id`，但**地面物品 id 无处可得**，只能靠“走过去时游戏自己自动拾取”（本局只自动拿到了 `citrine` 和金币）。`server/README.md` 声称“快照报告当前可见地面物品”，实际部署里没有该字段。

**改法**：
1. 快照增加 `ground: [{id,name,count,x,y,identified}]`（可见半径内的 floor items）。
2. `pickup` 支持 `{"type":"pickup","at":"here"}` 或 `{"type":"pickup","x":..,"y":..}`（原生就是“拾取当前格/指定格”）。
3. 缺参时返回 `status:"failed", code:"missing_item_id"`，不要静默成功。

### 4.9 【低】`inspect` 对未知 kind / 缺 `id` 返回空成功

**证据**：

```json
{"inspect":{"kind":"item"}}       -> {"ok": true, "result": {"_error": null}}
{"inspect":{"kind":"ground"}}     -> {"ok": true, "result": {"_error": null}}
{"inspect":{"kind":"tile"}}       -> {"ok": true, "result": {"_error": null}}
{"inspect":{"kind":"level"}}      -> {"ok": true, "result": {"_error": null}}
{"inspect":{"kind":"progression"}}            -> {"ok": true, "result": {"_error": null}}
{"inspect":{"kind":"progression","id":"player"}} -> 正常返回完整技能树（见 §4.2）
```

**影响**：agent 会以为“这一项就是空的”，从而得出错误结论（我一开始就误判 `progression` 不可用）。

**改法**：返回 `status:"failed", code:"unknown_inspect_kind"` / `missing_inspect_id`，并在 `result` 里附带 `allowed_kinds`。

### 4.10 【低】`observe` 的 `player` 缺 `id`、`exp` 永远为 null，XP/属性只能靠 `inspect actor`

**证据**：

```json
$ send.sh '{}' | jq -c '.result.player | keys'
["level","life","max_life","name","x","xp","xp_next","y"]
```
而 `xp`/`xp_next` 在每条快照里都是 `null`；真正的经验在 `inspect(kind="actor")` 里，且 actor id 是**按层变化**的：
`tome-...:level-2:actor-2394` → `tome-...:level-3:actor-2394`。
我最终是用一次 `walk`（它返回更完整的 `player` 对象）才拿到自己的 actor id。

**影响**：每次想知道“差多少升级 / 还有几点可用”都要：先想办法拿到自己的 id → 再 inspect actor；浪费命令且易错。

**改法**：
1. `observe.player` 补 `id`、`exp`、`exp_next`、`unused_stats/talents/generics`（或提供 `player_id`，并支持 `inspect(kind="actor", id="self")`）。
2. 支持 `{"inspect":{"kind":"actor","id":"player"}}` 之类的别名（`progression` 已经有 `id="player"` 的先例，风格应统一）。

### 4.11 【低】事件 `remove` 条目没有 `text`，`missed_before` 语义需要读文档

**证据**：

```json
{"cursor":1094,"line_id":350,"op":"remove","reason":"no_longer_in_visible_log"}
```
（无 `text` 字段；全日志共 36262 条这样的 remove 条目。）

**影响**：小的消费端坑——按 `text` 取值会得到 `null`/空串（我第一版 `fight.py` 就把它们打印成空行，一度以为日志坏了）。

**改法**：文档明确 `remove` 仅含 `op/reason/line_id`；或补 `text`（指向被移除的行）。

### 4.12 【低】快照体积：每条命令都带整张地图行

**证据**：单条 move 的原始响应里 `snapshot.map.rows` 最多 25×25 行文本（见日志 3792–3794 行）；控制台日志 5119 行 = 7.18 MB（≈1.4 KB/条）。console 的 `tome.sh` 之所以要单独写一个 `map.sh`，就是因为 `map.sh` 本质上只是“再发一次 `{}` 并只打印 `result.map.rows`”——地图和状态被绑死在同一个 observe 里。

**改法**：`observe` 增加 `include_map: false|"window"|"full"`、`footprint`、`sections:["player","actors","talents",...]`；或提供独立的 `tome.map` 通道（`radius` / `x,y` / `delta`），使“移动 N 步 + 看一次地图”从 N+1 次全量快照降到 1 次增量。

---

## 5. 对 ToME4 MCP 的优化建议（按优先级）

> 背景：为了避免每回合手写一大段 JSON，我在 `/tmp` 自己写了这些辅助脚本（它们**只调用现有 `tome.sh`/`map.sh`**，没有碰游戏/addon）：
> - `/tmp/t.sh` — 把一条命令的返回压缩成 `status/code/pos/actors/effects/cd/events` 单行；
> - `/tmp/w.sh` — 压缩 `walk` 的数组结果并折叠重复位置；
> - `/tmp/mapc.py` — 解析 `map.rows`，把 `@` 附近的 8 个方向与坐标显式列出来；
> - `/tmp/fight.py` — “打一轮”的决策器（CD/资源/距离 → MR/SL/Twilight/平砍/wait）；
> - `/tmp/explore.py`、`explore2.py`、`explore3.py` — BFS 边界探索器（走已知可通行格 → 探测未知格 → 记住墙），`explore3.py` 用“未访问格优先”最终扫完了两层。
>
> 这些脚本的存在本身就是需求清单：**下面每一条都是“我为什么不得不自己写它”。**

### P0 — 不做就没法“真正玩一局”

1. **宏动作 / 有界自动行动（对应 §4.7、§4.6）**
   - 现象：逐格 `move` 是本局 3911 条命令的绝对主力；`walk` 一看见敌人（哪怕 6 格外）就 0 步中止，撞墙又静默 `completed`。
   - 影响：探索/赶路成本极高，agent 无法把 token 花在决策上。
   - 改法：新增 `{"type":"walk", "path":[[dx,dy],...]|"directions":[...], "stop_on_enemy":"adjacent|visible|never", "max_steps":N, "stop_on":["enemy","low_life","new_item","level_change"]}`，返回 `{planned, executed, stopped_by, blocked_at, path_taken}`；再提供 `{"type":"explore","mode":"frontier","max_steps":N,"stop_on_enemy_distance":2}`（等价于我的 explore3.py，但由原生 Lua 在游戏内跑，一次 IPC 完成一整个推进）。

2. **战斗宏 + 威胁/伤害信息（对应 §4.3、§4.4，以及 §3 里 good 的 events）**
   - 现象：我写 `fight.py` 每回合手动判断 `talent.cooldown`、`resources.negative`、`distance`；而 `inspect talent` 的 `affordable` 还会误报，`native_rejected` 不给原因；对 Lv7 troll 的 `combat_spellresist 0.56 / combat_physresist 1.37` 完全靠我自己读 `inspect actor` 才发现“平砍只有 5 伤害”。
   - 影响：每回合都要 1 observe + 1 action，且策略容易踩坑。
   - 改法：
     - `{"type":"auto_combat","max_turns":N,"policy":"damage|defensive|kite","stop_at_life_pct":40,"use":[talent_ids],"stop_on":["no_enemy","low_life","out_of_resource"]}`，原生侧按同一套规则循环，返回 `turns_executed / damage_dealt / damage_taken / killed`。
     - `inspect(kind="actor")` 增加**已换算**的威胁字段：`effective_damage_vs_me`（按我的抗性/护甲换算）、`hits_to_kill_me`、`my_dps_vs_it`、`expected_turns_to_kill`。同时把 `combat_*resist` 的语义（0.56 是 56% 还是 0.56%？）在 `api-fields.md` 里写清楚——目前只能靠打出来的数字反推。
     - 目标选择辅助：`{"inspect":{"kind":"actor","id":"nearest","sort":"threat"}}`。

3. **控制租约与恢复（对应 §4.1）**
   - 现象：`change_level` 后 402 条命令静默失败，`ok:true` 但错误藏在 `result._error.error.code`。
   - 影响：这是本局最贵的一次失误（~10% 命令预算 + 探索器状态被污染）。
   - 改法：见 §4.1 的 1/2/3 条。另外建议所有写动作统一返回顶层 `status/code`，把 `_error` 信封移除；并提供 `{"observe":true}` 之外的轻量 `{"status":true}`/`{"hello":true}` 查询控制租约，避免必须发一次全量快照。

### P1 — 显著降低“玩一局”的成本

4. **地图/导航（对应 §4.12 + 我的 `mapc.py`）**
   - 现象：地图只能靠 `map.rows`（25×25 文本）解析；要让 agent 用起来必须自己写坐标换算 + 邻居表（我写了 `mapc.py` 才发现之前一直在数错列）。
   - 改法：
     - `observe` 的 map 增加机器可读形式：`{"origin":[x,y],"passable":[[x,y,glyph],...],"unknown":[[x,y],...],"features":[{"kind":"stairs_down","x":..,"y":..},{"kind":"door",...},{"kind":"item",...}]}`；
     - 加 `{"action":{"type":"travel","to":{"feature":"stairs_down"}|{"x":..,"y":..}}}`（原生 `Actor:moveDir` + 已知地图寻路），一次 IPC 走完；
     - 楼梯/出口定位：`{"inspect":{"kind":"level"}}` 返回 `stairs:[{dir:"down",x,y,known:true}]`、`zone:"trollmire"`、`level_number:1`、`explored_pct`。

5. **角色成长/背包/物品（对应 §4.2、§4.8、§4.10）**
   - 现象：3 职业点 + 2 通用点全废；`pickup` 用不了；XP/未用点要靠 `inspect actor` + 自己找 actor id。
   - 改法：
     - `observe.player` 补 `id/exp/exp_next/unused_stats/unused_talents/unused_generics`（一行就能省掉我每次 2–3 条命令）；
     - `ground` 物品列表 + `pickup{at:"here"|x,y}` + `equip/use_item` 的 `item_id` 从 `ground`/`inventory` 直接可引用；
     - `learn_talent` 走通用原生路径（§4.2），并在 `progression` 里给出 `supported/reason`。

6. **快照体积与增量（对应 §4.12）**
   - 现象：7.18 MB / 5119 行日志，其中大量是重复的 `map.rows` + 重复的事件页；我不得不写 `tome.sh`/`w.sh` 做二次裁剪。
   - 改法：`observe` 支持 `sections`、`include_map`、`since_revision`（差分快照）、`events.since_cursor`（现有 cursor 已具备，只差默认只回增量）；把 `map` 从每次快照里挪出去，做成 `tome.map` 独立调用或 `map_delta`。

7. **动作结果语义统一（对应 §4.5、§4.6）**
   - 现象：`code` 在 `action_complete/native_complete/damaged/native_stopped/progression_applied/level_changed` 之间漂移；撞墙返回 `completed` + tick 不变。
   - 改法：冻结 `code` 枚举（写进 `docs/tome-mcp-api-fields.md` 并在 CI 校验），把“为什么停”统一放 `stop_reason`；撞墙 → `failed/blocked`。

### P2 — 体验与可观测性

8. **`needs_input` 手工接手更顺滑（本局未触发，但设计上需要）**
   - 建议：`interaction` 里直接给出 `human_hint`（一句话告诉玩家该按什么键/选哪项）、`timeout_at`、以及 `abandon`（放弃该原生任务并把角色交回 `remote`）的入口；避免 agent 卡在 `awaiting_input` 时只能 `{"respond":{"type":"cancel"}}`。

9. **错误信息带修复建议**
   - 例如 `target_not_adjacent` 附 `distance: 2, required: 1`；`actor_not_visible` 附 `last_seen_tick`；`talent_not_in_growth_tree` 附 `did_you_mean:["T_HYMN_ACOLYTE",...]`（本局我为了确认 Hymn 树里的真实 id，发了 11 条探测命令）。

10. **一次 IPC 内的“观察→决策→执行”回路（latency）**
    - 现象：本局 68 分钟 / 3911 条命令，绝大部分时间花在“发一条、等一条”的往返上。
    - 建议：支持 `{"batch":[{...},{...}], "abort_on":["enemy","life_below","status!=completed"]}`，或在 Lua 侧挂一个小型策略回调（现有 `native_task` 已有类似的“原生任务”概念，可复用）。

11. **只读快照的成本**
    - `map.sh` 目前 = 再发一次 `{}` 全量 observe。建议提供 `{"observe":true,"sections":["map"]}` 之类的裁剪，或干脆把地图增量挂在每条动作结果里（`map_delta`），这样“走路时顺便看路”就不需要额外命令。

---

## 6. 结论

- **bridge 的“动作通道”是可用且稳健的**：3911 条命令串行执行、无卡死，错误码覆盖面不错，`rest` / `spend_stat` / 事件增量是亮点。
- **但“用 MCP 真正玩一局”目前仍有三个硬门槛**：
  1. `change_level` 后的**控制租约静默丢失**（错误藏在 `_error` 里），一次就吞掉 402 条命令；
  2. **非 Berserker 职业完全无法加技能点**（本局 3+2 点作废），角色成长被截断；
  3. **缺失批量动作/寻路/自动战斗**，导致探索和战斗必须逐格/逐回合手写，命令数与 token 成本爆炸（本局 3911 条命令 ≈ 68 分钟，其中 3791 条是 `move`）。
- 次要但影响体验的还有：地面物品不可见导致 `pickup` 不可用、`observe` 缺 `player.id/exp/未用点`、`inspect` 未知 kind 静默成功、撞墙返回 `completed`、每条快照都带整张地图。
- 若按 §5 的 P0（宏动作+威胁信息+租约语义）与 P1（地图/成长/快照裁剪）落地，agent 的操作量有望从“每格一条命令”降到“每个战术阶段一条命令”，这局的同等内容预计可从 3900+ 条命令压缩到数百条。

---

## 7. 证据清单

| 路径 | 内容 |
| --- | --- |
| `/workspace/t-engine4/tmp/mcp-play-support/agent-ham-madness-01.log` | 控制台全部原始响应（5119 行 / 7.18 MB）。关键行号：873（`level_changed` + `input_owner:manual`）、877–1411（402 条 `control_lost`）、1412（`connect control` 恢复 remote）、3792（`picks up citrine` + 事件结构）、`native_stopped`/`damaged`/`target_not_adjacent`/`target_lost`/`actor_not_visible` 各样本 |
| `/workspace/t-engine4/tmp/mcp-play-support/agent-ham-madness-01.cmd` | 最后一条下发的命令 |
| `/workspace/t-engine4/tmp/mcp-play-support/agent-ham-madness-01.events-cursor` | 事件游标终值 1314 |
| `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/agent-ham-madness-01/play-mcp.jsonl` | 会话级 MCP 原始流（461 MB） |
| `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/agent-ham-madness-01/decisions.jsonl` | 决策记录（3791 `move` / 132 `use_talent` / 71 `attack` / 16 `learn_talent` / 8 `rest` / 6 `spend_stat` / 5 `wait` / 2 `pickup` / 1 `set_sustain` / 1 `change_level`） |
| `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/agent-ham-madness-01/game.log` | 引擎日志；含 `zone trollmire`、`Trollmire (1)` / `Trollmire (2)` |
| `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/agent-ham-madness-01/observed.json` | 最后一次 observe 快照 |
| `/tmp/t.sh` `/tmp/w.sh` `/tmp/mapc.py` `/tmp/fight.py` `/tmp/explore.py` `/tmp/explore2.py` `/tmp/explore3.py` `/tmp/explore3-state.json` `/tmp/prog.json` `/tmp/m.txt` | 本次为“用 MCP 玩一局”而写的辅助脚本与中间产物（只读调用现有接口） |

### 本局统计（由增量事件去重后统计）

- 唯一 append 日志 839 条；击杀 31 只：Forest troll ×11、Wolf ×4、Giant white mouse ×2、Midge swarm ×2、Fox ×2、Stone troll ×2、Copperhead snake ×2、Green worm mass ×2、Giant brown mouse ×1、Giant grey mouse ×1、Poison ivy ×1、Large brown snake ×1。
- 升级 1 次（Lv1 → Lv2），属性点 6 点（5×mag + 1×con），技能点 0 点可用。
