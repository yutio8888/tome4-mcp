# 第三轮 Insane 实机反馈：处理记录

来源：`tmp/mcp-play-support/agent-ham-insane-03-report.md`（半身人/星月术士/Insane，存活未死 Lv1）。
处理日期：2026-09-16。基线：0.9.0 / 内部协议 v4。

## 逐条处理

| 报告 | 状态 | 处理 |
| --- | --- | --- |
| 1【致命】respond 被 schema 拒绝后 interaction 永久丢失，observe 不再暴露 | **已修** | ① MCP server 的 answer 模型改为 `extra="ignore"`（仍 `strict=True` 校验已知字段）：answer 里多带 `interaction_id`/`response_id` 等未知字段会被忽略而不是拒绝；② 控制台 `observe()` 从 `pending_command.interaction` **恢复** interaction/command_id；③ `respond()` 仅在成功后才清空 interaction，失败时保留以便改答；④ `snapshot_summary` 带 `pending_command`，agent 在 observe 里能看到待答交互。 |
| 2【致命】手动 `key` 接管对话触发游戏 Lua Error，bridge 单向隔离 | **部分/设计** | 根因是问题 1 的连锁自救；修复 1 后台即可正常 respond，不必手动 `key`。native error 后按 INV-12 隔离写入直到重新读档，是**有意保留**的安全语义（不伪造回滚）；控制台 `key` 仅用于原生 UI 自救且不保证安全，已在流程文档中标注。 |
| 3【中】pickup 缺 item_id 校验失败 | **文档修正** | RULES 明确 pickup 需要地面物品 id（来自 `observe.ground.items` 或 `tome.list(ground_items)`），缺 id 会被输入 schema 拒绝；正确用法本局已验证可用。 |
| 4【低】地面持续效果（Searing Light `light_zone`）不可见 | **待办** | 记录：observe 不暴露地面区域效果。建议在快照/地图 cells 中暴露地面效果（或至少事件标注）。 |
| 5【低】`target_geometry.selffire` 为 false 时省略 | **已修** | `Actions.lua` 改为：原生 `selffire` 是布尔时显式输出（true/false 都带），非布尔才省略。 |

## 本轮提交

- MCP：`server/src/tome_mcp/server.py`（answer 容错、RULES pickup 说明）、`overload/mod/mcp_bridge/Actions.lua`（selffire 显式）。
- 测试：`server/tests/test_server.py`（未知字段被忽略且不下发；已知字段仍严格校验）。
- 控制台（测试用）：`agent-play.py`（observe 恢复 interaction、respond 失败保留、summary 带 pending_command）。

## 仍待办（下一轮候选）

- 地面持续效果可见（§4）
- 手动接管/native error 的显式恢复通道（§2，需设计）
- T-1 notice 接管、`observe.sections` 裁剪、`walk` moved_tiles、控制台 `key` 任务状态、API-05/STA-03
