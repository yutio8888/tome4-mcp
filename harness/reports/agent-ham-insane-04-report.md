# ToME4 MCP 实机测试报告 — 第四轮（agent-ham-insane-04）

角色：**半身人（Halfling）/ Celestial-Anorithil / Insane / Roguelike**
会话：`MCP_agent-ham-insane-04`，接口 `tome-insane4.sh` / `map-insane4.sh`

---

## 1. 最终状态

| 项 | 值 |
| --- | --- |
| 生死 | **存活**（未死，正常收尾） |
| 等级 | 1 级，exp 11.4 / 29.7 |
| 位置 | `(x=22, y=13)`，`level_instance_id=level-2`（trollmire），`world_tick=600`，`revision=1180` |
| 生命 | 94 / 94（本轮全程未掉到危险线以下） |
| 资源 | positive 30/30、negative 27.5/30（Hymn+Chant 各占用 20 上限，故 max 由 50 降到 30） |
| 已接受动作 | `history.last_accepted_seq = 72`（`next_command_id = cmd-73`），共 72 个命令 |
| 控制/相位 | `control=remote`，`phase=ready`（每步 observe 均为 ready） |
| 当前效果 | `EFF_FONT_OF_LIFE`（duration 1，neutral）——站在 (23,13) 的 `&` 地形旁触发 |

### 加点
- 技能点（class）2 点：`T_MOONLIGHT_RAY` 1→2（主输出），另一次 `T_SHADOW_BLAST` 被原生拒绝（见 §3.2）。
- 通用点（generic）1 点：`T_CHANT_ACOLYTE`（解锁 Chant of Fortitude / Fortress / Resistance）。
- 属性点 3 点：全部 `mag`（16→19）。
- 常驻 sustain：`T_HYMN_OF_PERSEVERANCE`、`T_CHANT_OF_RESISTANCE`。

### 击杀 / 战果（9 只，全部原生结算）
white worm mass（Searing Light 31）、fox（Moonlight Ray 58）、giant grey rat（Moonlight Ray **crit 92**）、
bee swarm（34）、giant white ant（62）、giant white mouse（34）、midge swarm（34）、
giant brown ant（62）、poison ivy（33）。

### 用到的机制
- **target_geometry 选位**：`Searing Light {shape:"ball", radius:1, range:7}` → 打相邻敌人时不误伤自己、且覆盖半径 1；
  `Moonlight Ray {shape:"beam", range:10, piercing:true}` → 直线穿透，用来点远处单个目标。
- **Twilight**：15 positive → 约 +19.5 negative（受上限 30 截断），是补 negative 的主力。
- **Searing Light 反哺 positive**：施放后 positive 18.5 → 30（该技能是 positive 来源，`inspect` 未给出这一语义，见 §3.4）。
- **rest** 会用 `native_stopped` + `native_message` 说明停止原因，很好用。

### 经过（路线上）
出生点西南小房间 → 南侧空地清 worm/fox → 穿过中路走廊 → 东北大房间清 bee/ant/mouse/midge/ivy →
沿 y=13 走廊向东推进到 (22,13)，紧邻 (23,13) 的 `&` 地形（触发 Font of Life）时按收尾指令停止。

---

## 2. 「拿不到 cells / 地形语义」的完整排查（本次卡住的真正原因）

### 2.1 可用路径：`map-insane4.sh` 只给 rows，不给 cells
```sh
$ ./map-insane4.sh
origin x=10 y=1
?????????????????????????
...
.##.......;.@&.....#?????
```
走的就是 `send.sh '{"map":true}'`。

在**正确的 session** 下，原始返回体如下（原样，完整键集）：
```json
{"ok": true, "result": {"x": 10, "y": 1, "rows": ["?????????????????????????", "...", ".##.......;.@&.....#?????"], "legend": {"?": "unknown", "@": "player", "A": "perceived actor"}}}
```
```sh
$ jq -c '.result|keys' /tmp/m2.json
["legend","rows","x","y"]
$ grep -c cells /tmp/m2.json
0
```
**结论：这条控制台传输路径下 `result` 里根本没有 `cells` 数组，只有 `x/y/rows/legend`。**
legend 只有 3 个条目（`?`/`@`/`A`），所以 `=`、`;`、`&`、`#`、`.`、`<` 这些字符**没有任何语义映射**：
无法从返回值判断某格是墙/地板/花/旧石路/楼梯，也无法拿到 `name`、`blocked`、`notice`、`change_level`。
（`docs/tome-mcp-api-fields.md` 第 109 行把 `cells`、`block_scope`、`window` 等列为 map 字段，
但 `?`/`A`/`@` 以外的字符在 console 输出中被裁掉了 → **文档与实际返回不一致**。）

我是靠翻游戏源码反推字符含义的：
- `game/modules/tome/data/general/grids/forest.lua:132,141` → `display='='` 是 `GRASS_ROAD_STONE/DIRT`（旧石路/土路，可走）；
- `.../forest.lua:101` → `display=';'` 是 `FLOWER`（花，可走）；
- `display='&'`（`quests/escort-duty.lua:170`、`general/grids/basic.lua:428` 等）→ 无法从 bridge 判断，只能靠 `EFF_FONT_OF_LIFE` 猜是 Font of Life。

### 2.2 让我真正"卡住"的原因：直接调用 `send.sh` 会**静默连到别的会话并挂死**
我第一次尝试直接拿 cells 时执行的是：
```sh
$ ./send.sh '{"map":true}'          # ← 没有设置 TOME_AGENT_SESSION
{"ok":false,"error":"timeout waiting for console result"}
```
`timeout 130 ./send.sh '{"map":true}'` → `exit=124`，**130 秒内 0 字节输出**。
再跑一次同样 `exit=124`。

原因在 `send.sh`：
```sh
S=${TOME_AGENT_SESSION:-agent-ham-madness-01}   # ← 未设环境变量时默认连到 madness-01
...
printf '%s\n' "$cmd" > "$dir/$S.cmd"
for _ in $(seq 1 2400); do ... done             # 2400 * 0.5s = 1200s 才超时
```
证据：我的那次写入落到了**别的会话**的 FIFO 上（madness-01 的 cmd 管道正好是 13 字节）：
```sh
$ wc -c agent-ham-madness-01.cmd ; cat agent-ham-madness-01.cmd
13
{"map":true}
```
带上 session 后同一条命令立刻成功：
```sh
$ TOME_AGENT_SESSION=agent-ham-insane-04 timeout 60 ./send.sh '{"map":true}'
exit=0 size=844      # 正常返回上面的 rows/legend
```

**问题本质：**
1. `send.sh` 对未设置的 session 使用**硬编码 fallback `agent-ham-madness-01`**，没有任何警告/报错，也不校验该会话是否存在；
2. 失败表现为**最长 20 分钟静默挂起**（每 0.5s 轮询一次日志行数），而不是快速失败；
3. `map-insane4.sh` / `tome-insane4.sh` 里 `export TOME_AGENT_SESSION=...` 是唯一的"路标"，prompt 里没写"sandbox 里裸调 send.sh 会打到别局"，很容易踩。

### 2.3 附带发现：同一条 map 命令在"当前会话"上偶发超时
在修复 env 之前，我用 `map-insane4.sh` 两次成功，用裸 `send.sh` 两次 `exit=124`；
另外 `map.sh` 使用的日志行数计数器在并发/复用（例如我上一次被中断的调用）下也会错位。
`send.sh` 用 `before=$(wc -l < log)` + 期望"行数 +1"作为完成信号，若前一个调用的应答已写入同一日志，
就会出现"应答早到 → 本次永远等不到新行"的竞态。

---

## 3. 其它 MCP 问题（含原始证据）

### 3.1 `set_sustain` 字段名与 prompt 不符 → `mcp_request_rejected`
prompt/常识用 `active`，实际字段是 `enabled`：
```json
{"ok": true, "result": {"_error": {"code": "mcp_request_rejected", "is_error": true,
 "message": "Error executing tool tome.act: 2 validation errors for actArguments\naction.set_sustain.enabled\n  Field required ...\naction.set_sustain.active\n  Extra inputs are not permitted ..."}}}
```
改 `enabled:true` 后正常：`{"status":"completed","code":"action_complete"}`。

### 3.2 `progression_talents` 的 `readiness` 会误报 available，真实前置（角色等级）没有暴露
```json
{"id":"T_SHADOW_BLAST","raw_level":0,"readiness":"available","readiness_reason":null,
 "requirements":{"category_known":true,"lower_talents_known":1,"lower_talents_required":1,
 "next_raw_level":1,"stats":{},"status":"unknown"}}
```
但原生直接拒绝：
```json
{"status":"failed","code":"native_progression_rejected","native_message":"Prerequisites not met!"}
```
原因（查游戏源码 `data/talents/celestial/celestial.lua:54 divi_req2`）是 **`level = 4`**（4 级才能学 Shadow Blast），
而 `requirements` 里**完全没有 level 字段**、`status` 是 `unknown`，`readiness` 却是 `available`。
→ 建议：`requirements` 带上 `level`，`readiness` 在 `status=="unknown"` 时不要报 available。

### 3.3 sustain 在 `observe.effects` 中不可见
设置 Hymn + Chant 成功后：
```json
{"effects": [], "resources": {"negative":{"max":30,...}, "positive":{"max":30,...}}}
```
`effects` 始终为空，只能从 `max` 从 50→30 反推，或用 `inspect` 看：
```json
{"name":"Hymn of Perseverance","sustained_active":true,"query":{"readiness":"unknown","readiness_reason":"native_precheck_not_run"}}
```
→ 建议 observe 提供 `sustains[]`（许多 build 决策依赖"我现在挂着哪些 sustain"）。

### 3.4 `query` 缺资源语义：Searing Light 是 positive **来源**，但只显示费用
`inspect T_MOONLIGHT_RAY` 给出 `base_costs:{negative:10}`、`resource_checks.negative.operation:"unknown"`，
但 positive/negative **符号语义（是消耗还是产出）没有表达**；实测 `Searing Light` 施放后 positive 18.5→30（产出），
`Moonlight Ray` 施放后 negative 30→20.5（消耗）。`query.affordable` 也恒为 `unknown`/`readiness_reason:"native_precheck_not_run"`，
实际可用性仍要靠原生拒绝来判断。

### 3.5 `target_geometry` 字段存在性不一致（可接受，但需注意）
- `Searing Light`：`{"shape":"ball","radius":1,"range":7}`（无 `selffire`，因为原生给的是动态值而非 bool）
- `Moonlight Ray`：`{"shape":"beam","range":10,"piercing":true}`（**无 `radius`**）
- `Twilight`（self，无目标）：`target_geometry: null`
→ 与文档"selffire 仅在原生给出布尔时出现"一致；但 `radius` 缺失时调用方需自行判断 shape。

### 3.6 `walk` + `stop_on_enemy:"visible"` 的行为：一开始就看到敌人就完全不动
```json
{"interrupted":{"phase":"ready","revision":640, "player":{"x":6,"y":23}, "actors":[{"name":"giant grey rat","x":9,"y":28}]},
 "stop_on_enemy":"visible"}
```
调用前后 `revision` 都是 640、坐标未变——因为起手就有可见敌人，walk 直接 `interrupted` 返回。
这个语义合理（"看到就停"），但对"远处 6 格的小怪"过于敏感，导致长距离兜图会一步都走不动；
需要先清屏或退化为 `adjacent`。建议在返回里加 `stop_reason`/`moved_steps` 便于区分"没走"和"走完停了"。

### 3.7 `rest` 的停止原因（做得好的例子）
```json
{"status":"completed","code":"native_stopped","native_message":"hostile spotted to the north (poison ivy)"}
```
注意：这一次 rest 0 回合，技能 CD 也不会推进（CD 只在真正过回合时递减），符合预期。

### 3.8 输入校验的字段名与 prompt 有出入（均已用原始报错自查成功）
- `inspect` 需要 `{"inspect":{"kind":"talent","id":"T_..."}}`；传 `talent_id` 报 `id Field required`。
- `list` 需要 `{"list":{"type":"first","collection":"..."}}`；传 `{"kind":"learnable_talents"}` 报
  `Unable to extract tag using discriminator 'type' ... expected tags: 'first','next'`。
- `progression_talents` 必须带 `filter:{"category_id":...}`，否则：
  `{"code":"invalid_filter","message":"invalid filter","accepted":null,...}` —— `accepted` 是 null，
  **没有提示哪些 filter 键可用**（应从 `ObservationCollections.lua:22` 反查 `{category_id}`）。

### 3.9 冷却/拒绝信息（正面）
```json
{"status":"failed","code":"native_rejected","native_message":"Moonlight Ray is still on cooldown for 2 turns."}
{"status":"failed","code":"native_rejected","native_message":"Searing Light is still on cooldown for 2 turns."}
```
`native_message` 与 `observe.talents[].cooldown` 完全一致（cd 4 → 0），字段准确，很好用。

---

## 4. 结论

- **可玩性**：Anorithil 在 Insane 1 级靠 `Moonlight Ray`（beam/piercing）+ `Searing Light`（ball r1）
  交替输出 + `Twilight` 回能，清小怪很稳（9 杀 0 危），但升级很慢（11.4/29.7），
  且 1 级只有 2 class / 1 generic，`Shadow Blast` 等要到 4 级——前期 build 空间极小。
- **bridge 可用性**：核心链路（observe / act / use_talent / target_geometry / native_rejected /
  progression / rest / walk / events 日志）都工作正常，`native_message` 与快照字段一致性很好。
- **本轮真正卡住的原因不是 MCP 游戏侧，而是 console 包装脚本**：
  `send.sh` 未设 `TOME_AGENT_SESSION` 时静默连到 `agent-ham-madness-01` 并最长挂 1200s；
  加上 `{"map":true}` **本身就不返回 `cells`/地形语义**（只有 rows + 3 条 legend），这两点合起来让人误以为"拿不到地图"。
