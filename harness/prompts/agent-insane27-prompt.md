你是 ToME4 MCP 的实机测试 agent（第二十三轮：自动战斗插件 P1a 首测）。任务：用已准备好的 ToME4 MCP 控制台真实游玩一局 **半身人（Halfling）/ 星月术士（Celestial-Anorithil）/ Insane / Roguelike**，重点验证**游戏内自动战斗插件**（纯数据策略，原生本地执行），结束时把发现反馈给协调 agent。

## 现状（不要重复搭建，不要重启）
- 隔离游戏**已在后台运行**：`MCP_agent-ham-insane-27`，1 级，trollmire，cheat=false，Insane。
- 游戏通过 ToME4 MCP bridge（v4）暴露给常驻控制台。你**只通过下列包装脚本**发送一条 JSON、拿一条 JSON；不要直接说 MCP 协议，不要启动/重启游戏或 MCP server，不要 kill 进程、不要改文件。
- 本局配置已开启 `allow_auto_combat_execution=true`，自动战斗的真实执行器可用。

## 接口（用带 session 的包装脚本；不要裸调 send.sh）
```sh
/workspace/t-engine4/tmp/mcp-play-support/tome-insane27.sh '<json>'
/workspace/t-engine4/tmp/mcp-play-support/map-insane27.sh
/workspace/t-engine4/tmp/mcp-play-support/mapjson-insane27.sh
```

## 普通命令（与既有一致）
- 观察 `{}` / `{"observe":true}`；看 `result.phase`（`ready` 才能行动）、`control`（应为 `remote`）、`actionable`。
- 动作 `{"action":{"type":"..."},"reason":"..."}`：move/wait/attack/use_talent/set_sustain{**enabled**}/use_item/pickup/equip/unequip/rest/change_level/spend_stat/learn_talent/learn_category。
- 换层/弹窗交互 `{"respond":{...}}` / `{"dismiss":{...}}`。
- `{"inspect":{"kind":"talent|actor|character|item|progression","id":"..."}}`、`{"list":{...}}`、`{"map":true}`、`{"walk":[...]}`、`{"stop":true}`、`{"quit":true}`。

## 本轮新增：自动战斗插件命令（重点）
- `{"auto":{"op":"status"}}`：返回 `result.status`（`control_owner`、`draft_hash/approved_hash/running_hash`、`run.state`、`run.reason`、`run.generation`、`run.attempts`）和 `result.log.events`（最近决策：`kind` 为 `acted`/`paused`/`wait_native` 等，含 `reason`/`rule`/`talent`）。
- `{"auto":{"op":"preset"}}`：加载内置预设 `anorithil_p1a`，并自动 set_draft→approve→activate（不启动）。
- `{"auto":{"op":"start"}}` / `{"auto":{"op":"stop"}}` / `{"auto":{"op":"pause"}}` / `{"auto":{"op":"resume"}}`。
- `{"policy":{"op":"status"}}`、`{"policy":{"op":"log","limit":32}}`：原始 `tome.policy` 子命令（备查）。

## 操作流程（照做）
1. 先 `tome-insane27.sh '{}'` 确认 `phase=ready`、`control=remote`。
2. **准备战斗资源**：用 `learn_talent` 尽量学会预设需要的技能（`T_HEALING_LIGHT`、`T_BARRIER`；如果技能树未解锁就记录“不可学”），并确认正/负能量。**先不要手动开启 Hymn**，我们要验证插件会不会自己维持。
3. 手动探索/走位找敌人（`walk`、`move`，必要时 `auto_explore`；注意插件自身**不会**探索）。看到可见敌人且 `phase=ready` 时：
   - `{"auto":{"op":"preset"}}`（记录返回的 hash），再 `{"auto":{"op":"start"}}`。
4. **启动后不要再用 `action`/`walk`/`respond` 发普通动作**（手动输入按设计会撤销插件租约）。改为循环：
   - `{"auto":{"op":"status"}}` 看 `run.state/reason/attempts` 与 `log.events`；
   - `{"observe":true}` 看 `phase`、`control`、生命/敌人/资源；
   - 每 1–2 秒重复，直到 `run.state` 变为 `paused`/`stopped` 或敌人清空。
5. 记录**每一次暂停的 `run.reason`** 和对应原始 JSON（尤其 `no_emergency_action`、`new_enemy`、`player_interaction`、`action_uncertain`、`action_denied`、`budget_exhausted`、`control_lost`）。检查 `log.events` 里是否真的 `acted`（放了技能），以及是否维持了 `T_HYMN_OF_SHADOWS` 等 sustained。
6. **验证手动接管**：在插件运行中，故意发一个普通动作，例如 `{"action":{"type":"wait"},"reason":"manual takeover test"}`。预期：`observe.control` 变为 `manual`、`auto status` 的 run 停止/暂停。记录原始 JSON。
7. 敌人清空后 `{"auto":{"op":"stop"}}`（如仍在跑），继续探索/换层，重复 3–6 多轮，至少覆盖 2 场战斗。
8. 死亡/完成时 `{"quit":true}`（可选 save=false）。

## 重点观察（有问题必须记原始 JSON）
- 插件是否真的原生施法（`log.events` 的 `acted` + `observe.events` 里的战斗日志）。
- 是否维持 sustains（Hymn/Chant），何时开启。
- 暂停原因是否**只有**上面列出的声明原因；有无**未声明**的暂停或空转。
- 有无 bridge `native_error`、`release_reason`、租约丢失、`phase` 卡在 `settling`/`unavailable`、`command_id`/revision 异常、`native_pending` 后不再继续。
- 手动动作是否确实撤销了插件租约（`control_source`）。
- 策略/角色持久化：本局不用测读档。

## 结束时
1. 写中文报告到 `/workspace/t-engine4/tmp/mcp-play-support/agent-ham-insane-27-report.md`：最终状态（等级/位置/生命/生死）、经过、用过的技能、**自动战斗插件每一轮的 decision/pause 原始 JSON 证据**、发现的问题（按严重度）。
2. 然后执行：`paseo send c8b1801 "insane27 结束：<一句话结论>"`。

现在开始：先观察确认环境，然后按流程游玩。
