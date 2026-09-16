你是 ToME4 MCP 的实机测试 agent（第二十三轮之二：自动战斗插件 P1a 复验）。任务：用已准备好的 ToME4 MCP 控制台真实游玩一局 **半身人（Halfling）/ 星月术士（Celestial-Anorithil）/ Insane / Roguelike**，重点**复验上一轮发现的两个 P0 是否已修复**，并把结论反馈给协调 agent。

## 现状（不要重复搭建，不要重启）
- 隔离游戏**已在后台运行**：`MCP_agent-ham-insane-32`，1 级，trollmire，cheat=false，Insane，`allow_auto_combat_execution=true`。
- 你只通过下列包装脚本发送 JSON；不要启动/重启游戏或 MCP server，不要 kill 进程、不要改文件。
- 上一轮（agent-ham-insane-27）在这台插件里发现两个 P0，本轮已修：
  1. 无规则命中时不再静默 hold 死锁，而是**停止**并记录 `no_available_action`（无可见敌人则 `no_visible_enemies`），控制权交还玩家；
  2. `auto_combat` 持租约时远程普通 `act` 会返回 `control_conflict`（`recovery=connect_explicitly`），必须先用 `{"connect":"control"}` 原子接管才能行动。

## 接口
```sh
/workspace/t-engine4/tmp/mcp-play-support/tome-insane32.sh '<json>'
/workspace/t-engine4/tmp/mcp-play-support/map-insane32.sh
/workspace/t-engine4/tmp/mcp-play-support/mapjson-insane32.sh
```
- 观察 `{}`；动作 `{"action":{...}}`；弹窗 `{"respond":...}` / `{"dismiss":...}`。
- 自动战斗：`{"auto":{"op":"preset"}}`（加载并 approve+activate）、`{"auto":{"op":"start"}}`、`{"auto":{"op":"pause"}}`、`{"auto":{"op":"resume"}}`、`{"auto":{"op":"stop"}}`、`{"auto":{"op":"status"}}`（含 `run.state/reason` 与 `log.events`）。
- 重启控制：`{"connect":"control"}`。

## 本轮必做验证（每项都要原始 JSON 证据）
1. **无动作不再死锁**：加载 preset 并 start。让插件打完一只可见敌人（或把技能打进冷却）后，观察 `auto status` 是否在无可用规则时变为 `paused`/`stopped`、`log.events` 有 `stopped no_available_action` 或 `stopped no_visible_enemies`（而不是长时间 `running/attempts=0` 且 `world_tick` 冻结）。记录连续 10 次 `auto status`/`observe` 的 `world_tick` 与 `run.state`。
2. **远程 act 的 owner 互斥**：在插件 `running`（或 `activate` 后未 stop）时，直接发一个普通动作 `{"action":{"type":"wait"}}`：**预期 `control_conflict`**，且 `auto status` 的 `control_owner` 仍是 `auto_combat`。然后 `{"connect":"control"}`：**预期** `auto status` 变 `control_owner=manual`，随后同一个 `wait` 动作成功。
3. **正常战斗回归**：至少打 2 场，确认 `log.events` 里有真实 `acted`（melee/ray/finish/heal/sustain），且没有 `unknown_safety`、没有 sustain 刷屏（sustain 每个 opportunity 最多 1 次）。
4. **UI 热键（可选）**：`{"key":"g","modifier":"Control_L"}` 后 `{"observe":{"sections":["dialogs"]}}` 应出现 `Auto-combat policy`；`{"key":"g","modifiers":["Control_L","Shift_L"]}` 触发启停。记录是否出现。

## 报告
结束时写中文报告到 `/workspace/t-engine4/tmp/mcp-play-support/agent-ham-insane-32-report.md`，包含：
- 最终状态；本局决策统计；两个 P0 的复验结论（通过/不通过 + 原始 JSON）；其它 MCP/插件问题（按严重度，附证据）。
- 然后执行：`paseo send c8b1801 "insane32 结束：<一句话结论>"`。

先观察确认环境，再开始。遇到 `phase=needs_input` 用 `dismiss`/`respond` 关掉，不要一直 observe。
