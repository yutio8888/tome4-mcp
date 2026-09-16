# ToME4 MCP 实机测试报告（第十五轮 / round15）

- 会话：`agent-ham-insane-15`
- 角色：半身人（Halfling）/ 星月术士（Celestial-Anorithil）/ Insane / Roguelike
- 最终状态：**存活**，等级 2（exp 59.02/67.1），位于 **Trollmire 2（zone_depth 2）(7,15)**，life 107.76/107.8，`phase:"ready"`、`actionable:true`、`control_lease:"held"`
- 经过：清空 Trollmire 1（含全部封印门后的拱室，击杀 **Lv11 巨红蚁** 等）、下到 Trollmire 2、清掉若干 dire wolf / 老鼠；本轮因收尾指令在 Trollmire 2 (7,15) 停止。

最终 `observe`（裁剪）：

```json
{"phase":"ready","actionable":true,"control_lease":"held","scene":{"level":2,"zone_depth":2,"zone_id":"trollmire","zone_name":"Trollmire"},"world_tick":133721,"revision":196602}
{"x":7,"y":15,"life":107.76029324349696,"max_life":107.8,"level":2,"exp":59.01999999999997,"exp_next":67.10000000000001}
```

---

## 1. 最近进度明显变慢的原因

主要原因在**我的驱动脚本**，但它与 MCP 的两个设计缺口强耦合；按影响排序：

### 1.1【主因】地图只有“玩家半径 12 的窗口”，没有全图 / 探索前沿

- `mapjson`（`{"map":true}`）与 `observe.map` 的 bounds 都只是**以玩家为中心、半径 12 的窗口**（文档亦写明“Map bounds describe only this response's window”）；客户端必须逐窗累积自己拼图。
- Trollmire 1 的可达区域被清完后，剩余未探索格全部在**封闭口袋**或**封印门后面**（门是 known+blocked，因此不是“前沿”）。此时 `nearest_frontier` 返回 `None`，我的脚本退化为“走到可达区内最远的未访问格”，于是在同一片区域内**来回横跳**，反复数百次、无任何进展。
- 原始证据（`/tmp/play15.log`，多轮均为成对横跳）：

```
shift->(63,1) n=31 completed/action_complete pos={'x':46,'y':9,...}
shift->(28,32) n=24 completed/action_complete pos={'x':40,'y':20,...}
shift->(63,1) n=31 ...
shift->(28,32) n=24 ...
... （循环约 40 次）
shift->(64,9) n=25 ... / shift->(31,39) n=24 ...   （另一段循环）
shift->(35,0) n=26 ... / shift->(64,35) n=24 ...   （另一段循环）
```

- 调试输出同时显示“可达集已无前沿”：

```
reachable 416  frontier tiles 0
unknown in global 4
nearest_frontier None
exits [{'x':50,'y':10,'name':'sealed door'},{'x':58,'y':11,...},{'x':64,'y':19,'name':'way to the next level'}]
```

判断：**不是 bridge 出错**，而是缺少“探索完成度/未知前沿”信号 + 窗口过小，客户端无法区分“真的探索完了”与“还有隔墙的未探索区”。

### 1.2 长 `walk` 与自己累积的地图窗口错位 → 地图断裂、寻路失败

- 我最初用 `walk` 一次走最多 40 步，但只有每轮循环开始时查一次地图，导致累积地图在路径中段出现空洞；`bfs_path` 把这些空洞当不可通行，连通性被切断，出现 `no path (window)`。
- 改成每次 `walk` 最多 12 步后明显改善（窗口互相重叠）。原始证据：

```
no path (window) (63, 1)
```

### 1.3 技能射程预检与实际距离度量不一致 → 反复被原生拒绝

- `inspect T_SEARING_LIGHT` 静态 `range:7`，但目标在 **chebyshev 6（euclidean ≈7.8）** 时 `use_talent` 直接 `failed/target_out_of_range`；我的循环据此反复重发同一技能，空转约 50 次：

```
SL->dire wolf d=6 failed/target_out_of_range geom=null []
... （重复约 50 次）
```

- `observe.actors` 只给 `x/y`，没有 `distance` / `in_range`；`inspect` 也不返回“按原生度量是否在射程内”。客户端只能猜度量，猜错就进入重试/空转。

### 1.4 `pickup` 找不到“脚下”那一堆 → 反复失败

- `observe.ground.items` 的 scope 是“当前可见物件；远处堆只给顶部物件和数量”，条目的**坐标只编码在对象 id 字符串里**（`...:level-2:ground-54,21:object-5633`），没有独立 `x/y` 或 `underfoot` 标记。
- 因此客户端直接 `pickup` 会拿到 `item_not_underfoot`；而金子在踩上去时就被自动拾取，随后再拾取得 `item_not_visible_or_owned`。我的脚本未清理失效条目，于是同一 id 反复失败上百次：

```
pickup gold pieces failed item_not_underfoot | {"id":"...:level-2:ground-54,21:object-5633","location":"ground","name":"gold pieces",...}
pickup gold pieces failed item_not_visible_or_owned
... （重复上百次）
```

### 1.5 其它空转/误判
- 打开封印门：`move` 返回 `awaiting_input` 的 `respond` 结果一律是 `failed/blocked`（门其实开了），我的“开门”辅助因此判定失败并重试。
- 一次 `timeout` 被中断的 `play15.py` 疑似继续后台跑了一段，导致我短期读到的坐标/血量与自己的命令不一致（`ps` 已确认无残留进程，非 bridge 问题，仅作说明）。

---

## 2. MCP 问题（按严重度）

### 高

**H1. 缺少“全图 / 探索前沿 / 更大地图窗口”能力**
- 现象：地图窗口固定半径 12，且无未知前沿列表、无探索完成度；封闭口袋/门后区域不可判知。
- 证据：`reachable 416 / frontier tiles 0 / unknown in global 4`；`mapjson` window 视玩家位置在 13×25 ~ 25×25 间变化；文档“Map bounds describe only this response's window”。
- 影响：长局探索退化为无进展横跳（见 1.1）。
- 建议：提供已探索 bbox + 未知前沿坐标列表，或允许 `radius` > 12 / 一次拉取全图。

**H2. `ground.items` 条目无 `x/y`（也无 underfoot 标记）**
- 证据：`{"id":"tome-...:level-2:ground-54,21:object-5633","location":"ground","name":"gold pieces","pile_size":1,...}`
- 后果：`pickup` 对远处堆必然 `item_not_underfoot`；堆消失后 `item_not_visible_or_owned`。客户端只能解析 id 或穷举。
- 建议：给每个 ground item 增加 `x/y`（及 `underfoot:true|false` / `pickup_ready`）。

**H3. 技能射程预检与实际不一致，且客户端拿不到距离信息**
- 证据：`inspect T_SEARING_LIGHT` → `range:7`；`use_talent` 在 chebyshev 6 返回 `failed/target_out_of_range`。
- 建议：`inspect` 返回按原生度量的“可选中距离”，`observe.actors` 附 `distance`，或 `use_talent` 失败时在 `details` 里给实际距离/最大距离。

### 中

**M1. `inventory_count` / `equipment_count` 不存在（与 round12 说明不符）**
- 默认 `observe` 与 `detail:"full"` 的顶层 keys 都没有这两个字段：
```
['phase','actionable','control_lease','control','revision','world_tick','level_instance_id','scene','player','resources','effects','actors','ground','talents','dialogs','sustains','events','history','ground_effects','ground_effects_truncated','lua_heap_kb']
inventory_count present? False   equipment_count present? False
```
- 只能用 `list` 或 `detail:"full"` 的 `inventory`/`equipment` 数组长度。

**M2. 命令自有交互未出现在顶层 `observe.interaction`（与 round13 说明不符）**
- 实测打开封印门时的 `observe`：顶层无 `interaction`，只有 `dialogs` 与 `pending_command.interaction`；而 `act` 响应里是有 `interaction` 的。
```
dialogs = [{"title":"sealed door","topmost":true,"widgets":[{"kind":"text","text":"This door seems to have been sealed off. You think you can open it."},{"kind":"button","text":"Open"},{"kind":"button","text":"Leave"}]}]
pending_command = {"command_id":"cmd-12465","interaction":{"kind":"dialog.confirm","options":[{"label":"Open","option_id":"interaction-1:option-1"},{"label":"Leave",...}]}}
（顶层 interaction: 不存在/为 null）
```
- 影响：只看顶层 `observe.interaction` 的客户端会以为“无交互”。

**M3. `observe.sections` 省略域仍是 `null` 残桩（与 round10 说明不符）**
- 证据：`sections:["talents"]` 时 `actors:null, ground:null`，`sections:["talents","player"]` 时同样带 null 域。
- 影响轻微（客户端需区分“未请求”与“无内容”）。

**M4. `connect` 响应形态与其它命令不一致**
- `{"connect":"control"}` 返回 `{phase, actionable, control_lease, ...}`，没有 `status/code/action_ok`，客户端难以统一判定成功。

### 低 / 说明

- **L1** `attack` 对已死目标返回 `failed/target_lost`（合理，但字段清单未提及）。
- **L2** `use_talent` 冷却中返回 `failed/native_rejected` + `native_message:"Moonlight Ray is still on cooldown for 2 turns."` + 日志追加一行；重复调用会污染日志。
- **L3** `dismiss` 无可关闭弹窗返回 `ok:false/code:"dialog_not_closed"` + `details.hint`（与 round14 一致；`ok:false` 语义正确）。
- **L4** `events.entries` 的 `remove` 项会携带旧文本，未看 `op` 时极易误判为“回放旧日志”。语义文档正确，但建议 compact 输出也带 `op`。
- **L5** `spend_stat` 一次只能 1 点且不接受 `amount`（schema 严格、报错清晰）。
- **L6** 封印门 `move`+`respond` 的 respond 结果恒为 `failed/blocked`，虽然门确实开了；`action_ok:false` 会误导客户端（建议门开后 move 重试或给 `code:"door_opened"`）。

---

## 3. 已验证正常（本轮复现）

- **sections / 错误**：`sections` 过滤生效；`{"sections":["bogus"]}` → `{"ok":false,"error":{"code":"invalid_sections",...}}`；`inspect` 不存在技能 → `unknown_talent`；参数 schema 失败 → `invalid_argument`（含 pydantic 细节）。
- **`action_ok` 一致性**：`completed`→true；`blocked`/`failed`/`native_rejected`→false，且带 `code`+`hint`（`native_rejected` 另有 `native_message`）。
- **运行时几何（与 round14 一致）**：`T_MOONLIGHT_RAY` 施法后 `target_geometry={shape:"beam",piercing:true,selffire:false,damage_scope:"line"}`；`T_SEARING_LIGHT` 施法后 `{shape:"ball",radius:1,selffire:true,damage_scope:"area",residual_area_radius:1}`；静态 `inspect` 对两者 `damage_scope:"unknown"`（函数型 target 不再臆断 single）。
- **`walk`**：`blocked`（`moved_steps`、`action_ok:false`、hint “did not change position”）、`enemy_visible`、`enemy_adjacent` 停止原因均正确；已有可见敌人不会立刻 0 步卡死，新出现/相邻敌人才打断。
- **换层**：`change_level` → `completed/level_changed/action_ok:true`，`release_reason:"scene_changed"`，`{"connect":"control"}` 后恢复 `actionable`。
- **`rest`** → `completed/native_complete`，回复满资源；`T_INFUSION:_HEALING_3`/`_WILD_2`/`_REGENERATION_1` 可正常施放。
- **`equip`**：成功 → `item_action_complete`；不满足属性 → `native_rejected` + `native_message:"... can not wear (main armor): ... (not enough stat)."`（信息完整）。
- **加点**：`learn_talent` / `spend_stat` → `progression_applied`；学 `T_HYMN_ACOLYTE` 后 hymn 等级 1→3、`mag` 19→22 生效。
- **`sheet`**：含 `gold`（4.25）、`encumbrance`（`items_total:30` + scope）、`cooldowns`，与 round10 描述相符。
- **交互**：封印门 `dialog.confirm` 可用 `{"respond":{"type":"option","option_id":...}}` 打开；respond 结果带 `parent_action:"move"` 并继承父 `code`。
- **`events`**：`cursor/oldest_cursor/gap/has_more/new` 与 `append`/`remove` 语义自洽（`remove` = 日志回滚/清除/淘汰）。
- **`status`**：`{"status":true,"compact":true}` 只回状态；`{"map":true}`、`{"list":{...}}`、`{"inspect":{"kind":"progression"}}` 等正常。
- **地图图例/场景**：`mapjson.legend` 含地形字符；`observe.scene` 含 `zone_id/zone_name/zone_depth/level`。
- **`dismiss`**：无弹窗时 `dialog_not_closed` + hint，不虚报成功。

---

## 4. 其它缺口 / 建议汇总

1. 探索类：全图/前沿/更大 radius（H1）。
2. 拾取类：ground item 加 `x/y` + underfoot 标记（H2）。
3. 施法类：`inspect`/`observe` 给原生式距离与 in-range 判定（H3）。
4. 文档同步：`inventory_count`/`equipment_count`、命令交互的顶层 `interaction`、`sections` 的 null 残桩（M1–M3）。
5. 响应形态统一：`connect` 补 `status/code/action_ok`（M4）。
6. 开门语义：封印门 respond 后给可判定的成功信号（L6）。

---

## 5. 原始证据文件

- 驱动日志：`/tmp/play15.log`（含所有 shift 横跳、pickup 失败、SL out_of_range 循环）
- 驱动脚本：`/tmp/play15.py`、`/tmp/goto15.py`、`/tmp/doors15.py`
- 本轮未修改仓库/游戏文件，未退出游戏、未 kill 进程、未停止控制台。
