# 第一轮 Insane 实机反馈：处理记录

来源：`tmp/mcp-play-support/agent-ham-insane-01-report.md`（半身人/星月术士/Insane，存活 Lv2）。
处理日期：2026-09-15。基线：0.9.0 / 内部协议 v4。

## 逐条处理

| 报告 | 状态 | 处理 |
| --- | --- | --- |
| §3.a 技能加点失败（Celestial 不在白名单） | **已修（MCP）** | `Progression.lua` 增加**通用原生路径**：可见但不在已审核名单的技能/类别标记 `coverage="native_generic"`，`learn_talent`/`learn_category` 交给原生 `LevelupDialog` 判定需求/上限/点数；`inspect progression` 的 `supported` 对可见技能为 true。`_modified` 仍按原样拒绝。回归：`tests/test_progression.lua` 新增 3 项（234 checks）。 |
| §3.b(1) 无用资源池过传 | **已修（MCP）** | `ObservationDetails.player` 只上报**已解锁**资源（按资源定义关联的 pool talent 判断，`air` 之类无 pool 的保留），并消除 `regen` 浮点噪声。回归：`tests/test_resource_filter.lua`（3 checks）。 |
| §3.b(2) 每次动作回传完整 snapshot（含 map） | **部分** | 控制台 `act`/`status` 现在发送 `include_map:false`，动作响应不再带 59KB 地图；完整裁剪（`observe.sections`/增量）仍见 `docs/tome-mcp-0.9.0-todo-snapshot-payload.md`。 |
| §3.b(3) `player.xp`/`xp_next` 恒为 null | **已修（控制台）** | `snapshot_summary()` 改读 `exp`/`exp_next`（协议字段名）。 |
| §3.c 未适配 notice 弹窗 → `interaction=null`、被迫 manual | **待办（MCP）** | 记录为 TODO（见下）。控制台/agent 的规避：`{"key":"Escape"}` 关闭弹窗后重连恢复 `control=remote`。根因：`simplePopup`/`simpleLongPopup` 接缝只在 `Tracker.current()` 存在时调用 `Interactions.openNotice`；由世界/升级钩子在命令协程之外抛出的 notice 不归属当前命令，`boundary('dialog')` 因而撤权。 |
| §3.d MCP 校验失败返回空响应 | **部分** | 保留 MCP 严格输入校验（避免请求下发与既有测试契约冲突）；控制台 `call()` 现在在 `structured_content` 为空时把 `is_error` 与文本作为 `_error{code:"mcp_request_rejected",message}` 返回，agent 不再是 `_error:null`。彻底的结构化 `isError` 映射见 API-05。 |
| §3.e pickup 拿不到地面物品 ID | **已修（控制台）** | `snapshot_summary()` 现在带 `ground`；新增 `{"list":{...}}` 命令直达 `tome.list`（如 `ground_items`/`inventory`/`talents`）。 |
| §3.f `walk` 原地中断且信息少 | **已修（控制台）** | 中断条目现在带 `player`/`actors`/`stop_on_enemy`；新增 `stop_on_enemy: "visible"|"adjacent"|"never"`（默认 visible）。 |
| §3.f 撞墙 `move` 返回 completed | **待办（MCP）** | 属 `code` 语义问题；与既有规划（统一 code 枚举）一起处理。 |
| §3.g 地图图例/冗余 | **待办** | 完整快照 `cells[]` 已有 `name`/`block_status` 等，控制台只转 `rows`。计划在控制台提供带 cell 元数据的 `map` 视图。 |
| §3.h 表现好的方面 | — | 无需改动。 |

## 新增 TODO

### T-1 notice 接管（§3.c）
- **目标**：由当前命令结算期抛出的、可关闭且无选项的 simple popup，应作为 `dialog.notice` + 一个 Close 选项暴露给 agent，保持 `input_owner=remote`，而不是静默撤权为 manual。
- **方向**：在 `Runtime.boundary('dialog')` 中，当存在活跃的 remote 命令且该 dialog 仅含文本/可 EXIT 关闭时，尝试 `Interactions.openNotice`/`adoptPassiveDialog` 到当前命令根；无法安全归属时才走 manual 交接。
- **验收**：触发 "Option unlocked" 类弹窗后，动作返回 `awaiting_input` + `dialog.notice`，`respond` 可关闭并继续；未归属弹窗仍 manual。

### T-2 撞墙 `move` 的 code（§3.f）
- **目标**：位置未变且未消耗回合的 `move` 返回 `failed`/`blocked`，或至少带 `blocked=true`，而不是 `completed`。
- **验收**：`tests/native` 与单测覆盖"撞墙"返回可区分。

### T-3 地图可读性（§3.g）
- **目标**：控制台 `map` 输出可带每个 cell 的 `name`/`block_status`/`is_exit`（或至少扩展 legend），减少 agent 需要查源码认字符。
- **验收**：agent 能直接读到 `=`（旧路）`+`（可挖墙）`&`（拉杆）等地形语义。

### T-4 快照裁剪收尾（§3.b，已拆分到 `tome-mcp-0.9.0-todo-snapshot-payload.md`）
- 落实 `observe.sections`；默认紧凑集合；完整枚举走 `tome.list`。

### T-5 结构化 MCP `isError`（§3.d，API-05）
- 见 `limitations.md`；需要绕过 SDK `convert_result`。

## 本轮提交内容

- MCP：`Progression.lua` 通用成长路径；`ObservationDetails.player` 资源过滤与去噪。
- 测试：`test_progression.lua`（+3）、新增 `test_resource_filter.lua`。
- 控制台（`tmp/mcp-play-support/agent-play.py`，测试用，不在 addon 包内）：经验字段、`ground`、`list`、`walk`、`include_map:false`、MCP 校验错误文本。
