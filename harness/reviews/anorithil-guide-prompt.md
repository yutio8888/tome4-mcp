你是 ToME4 资深玩家兼技术写手。请为我们的 MCP 测试 agent 撰写一份**《半身人 / 星月术士（Halfling / Celestial-Anorithil）Insane 难度操作指南》**，中文，供 LLM agent 在实机游玩时参考。

## 任务与约束
- **只读研究 + 写一个文件**：不要修改 `game/addons/tome-mcp-bridge` 或游戏代码，只读游戏数据。最终产物写到：
  `/workspace/t-engine4/tmp/mcp-play-support/anorithil-guide.md`
- 游戏源码在 `/workspace/t-engine4/game`。请**以游戏数据为准**（不要凭印象编），重点读：
  - `game/modules/tome/data/talents/celestial/`（sunlight.lua / moonlight.lua / chants.lua / hymns.lua / circles.lua / glyphs.lua / eclipse.lua / star-fury.lua / sun.lua / twilight.lua 等）
  - `game/modules/tome/class/interface/Combat.lua`、`game/data/resources.lua`（正/负能量的定义与回复）
  - 相关职业定义（`game/modules/tome/data/birth/classes/celestial.lua` 之类）
- 输出要**可执行、面向决策**，不是科普。用表格/要点，尽量给出**精确的 talent ID、消耗、射程、半径、冷却、模式（activated/sustained/passive）**。

## 必须覆盖的内容
1. **资源机制**：`positive` / `negative` 能量各自怎么产生、怎么消耗、回复速率、上限；哪些技能吃正/负能量；施法顺序上如何避免能量互斥或空放（例如某些技能需要 positive，某些消耗 negative）。
2. **核心技能清单**：至少覆盖 `T_SEARING_LIGHT`、`T_SUN_FLARE`、`T_FIREBEAM`、`T_SUNBURST`、`T_MOONLIGHT_RAY`、`T_SHADOW_BLAST`、Hymn/Chant 系列、`T_CIRCLES`/`T_GLYPHS` 类、`T_ECLIPSE`、`T_STAR_FURY` 等（按实际数据补齐）。每个给：ID、等级门槛、消耗、射程/半径/形状、冷却、是否 direct_hit、是否会在脚下留地面效果。
3. **加点优先级**：1–10 级推荐学习/升级顺序（考虑 Insane 生存压力），并说明为什么。
4. **战斗循环与站位**：开战前怎么开 Hymn/Chant/sustain；先手用什么；AoE 怎么避免**打到自己**（Searing Light 是 ball、会自伤；Moonlight Ray 是 beam）；被围住/被远程怎么处理；逃跑手段。
5. **生存与 Insane 要点**：治疗/回复资源、护盾类技能、何时撤退、如何避免 1 层被围杀（我们的 agent 前几轮常在 Trollmire 1 层被围死）。
6. **早期 Trollmire 计划**：1 层清怪→找下一层入口的具体策略；何时该下 2 层；遇到精英/远程怪的取舍。
7. **通过 MCP 操作的具体提示**（这是给 agent 的，务必包含）：
   - 施法统一用 `{"action":{"type":"use_talent","talent_id":"<ID>","target_id":"<actor id>"}}`（预填目标可避免原生目标交互；也支持 `x/y`）。
   - 用 `inspect(kind="talent", id="<ID>", target_id 或 x/y)` 读 `range/radius/target_shape/current_costs/affordable/cooldown_remaining/readiness/target_distance/in_range` 与静态 `target_geometry`（`selffire` 对函数型 target 可能是 `"unknown"`，以施法后的 `target_geometry` 为准）。
   - 用 `inspect(kind="actor", id=<id>)` 的 `computed` 块读有效属性/速度/暴击/伤害加成/穿透/命中/APR 等做决策。
   - 用 `set_sustain`（带 `enabled`）开/关持续技能。
   - 用 `observe` 看 `resources`（positive/negative 的 value/max/regen）、`effects`、`actors[].distance`。
   - 用 `{"action":{"type":"auto_explore"}}` 让游戏原生自动探索（**视野内有敌人会被拒绝 `enemies_in_sight`**；途中可能触发 bridge 未接管的交互并返回 `needs_input/unsupported_interaction`，需留意）。
   - 用 `tome.map`（`{"mapfull":true}`）看 `explored_count`/`frontier_count` 判断是否探索完、何时换层。
   - 换层用 `{"action":{"type":"change_level"}}`；`unlearn_talent` 默认关闭（`respec_not_enabled`）。
   - 失败命令带 `status/code/hint`；`blocked` 表示原地未动，别重复空放。
8. **常见错误清单**：例如对着视野内敌人按 auto_explore、用错资源、AoE 自伤、把 beam 当单体、忽视冷却/点数、被围不撤。

## 交付
- 写完后回复一段 5–10 行摘要（文件路径 + 关键结论）。
- 指南控制在**约 150–250 行**，信息密度高、无废话；不确定的数据请标注“按数据未确认”，不要编造。
