# 第二轮 Insane 实机反馈：处理记录

来源：`tmp/mcp-play-support/agent-ham-insane-02-report.md`（半身人/星月术士/Insane，存活 Lv2）。
处理日期：2026-09-16。基线：0.9.0 / 内部协议 v4。

## 逐条处理

| 报告 | 状态 | 处理 |
| --- | --- | --- |
| §3.a 目标几何（beam/ball 形状、半径、穿透、自伤） | **已修（MCP）** | 执行期记录 `target_geometry={shape,radius,range,selffire,piercing}`（取自原生 `getTarget` 的 spec，`Actions.execute`）；`target.grid` 交互补 `shape`/`selffire`；只读 `inspect talent.query` 增加静态 `radius`/`direct_hit`/`reflectable`/`target_shape`（函数型仍 `unknown`，不求值）。回归：`test_talent_query`（形状/beam 预填）、`test_runtime`。 |
| §3.b 资源消耗符号/操作语义 | **已修（MCP）** | `resource_checks` 增加 `operation=debit|credit|none`（按原生存储值符号）与 `pool_delta=-amount`；负值不再被标成 debit。回归：`test_talent_query` credit 用例。 |
| §3.c `native_rejected` 无原因 | **已修（MCP）** | `Runtime.execute` 在 native 调用前后读取玩家日志游标，把新增行作为 `native_message` 附到 `native_rejected`（最多 3 行）。 |
| §3.d notice 弹窗 | **待办** | 见 `docs/tome-mcp-0.9.0-round1-feedback.md` T-1（本轮未复现）。 |
| §3.e 快照/字段过传 | **部分** | 控制台 `observe` 默认 `include_map:false`，新增 `{"map":true}` 命令专取地图；`map.sh` 随之。bridge 侧 `observe.sections`/`talents` 增量/`collection_refs` 收拢仍见 `...-todo-snapshot-payload.md`。 |
| §3.f 撞墙 move / walk 静默失败 | **部分** | `move` 未移动且未耗能量 → `code="blocked"`（不再 `completed`）。控制台 `walk` 中断条目带 `player/actors` 并支持 `stop_on_enemy`。`walk` 的 `moved_tiles/blocked_at` 仍待办。 |
| §3.g `{"key":"z"}` 自动探索 ping-pong | **待办（控制台）** | 记录：`key` 通道无"任务结束/卡住"信号；建议给 `key` 返回 action 风格状态。 |
| §3.h 加点触发 sustain 重激活噪声 / respec `respec_in_combat` | **记录** | 原生行为；如需要再在 progression 动作里标注。 |
| §3.i capabilities 声明过期 | **已修（MCP）** | `action_support.learn_talent/learn_category` 改为 `implementation="supported"`、`requirements="native_checked"`；`Progression.describe.execution_scope` 文本更新为通用原生路径。回归：`test_runtime`。 |

## 本轮提交

- MCP：`Actions.lua`（target_geometry、blocked move、per-command 清理）、`Interactions.lua`（shape/selffire）、`TalentQuery.lua`（静态几何、credit/pool_delta）、`Runtime.lua`（target_geometry 字段、native_rejected 原因、capabilities）、`Progression.lua`（execution_scope）、`protocol/v4/results.schema.json`。
- 测试：`test_talent_query.lua`、`test_runtime.lua`。
- 控制台（测试用）：`agent-play.py`、`map.sh`。
- 文档：`AGENTS.md` 增加"开发对话/测试对话反馈循环"。

## 仍待办（下一轮候选）

- T-1 notice 接管（§3.c/§3.d）
- `observe.sections` + talents/collection_refs 裁剪（§3.e）
- `walk` 的 `moved_tiles`/`blocked_at`（§3.f）
- 控制台 `key` 返回任务状态（§3.g）
- API-05 结构化 `isError`、STA-03 断言框架
