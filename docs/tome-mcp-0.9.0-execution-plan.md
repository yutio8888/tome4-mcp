# ToME MCP Bridge 0.9.0 执行计划（工作文档）

本文件把下一轮设计 spec 与本轮实机反馈对齐，作为开发过程记录。业务规范以
`/workspace/tome4-mcp-next-round-design-spec-v1.0.md`（下称 **Spec v1.0**）为准，
本文件只记录映射、状态与执行约束。

## 基线

- 代码基线：`e04c191a8db217112c513df5937ce9b6c8e5c29f`（Spec 固定基线，已核对一致）
- 产品 **0.9.0 / 内部协议 v4**（版本号在 M0–M2 后已升级；`init.lua`、`pyproject.toml`、`__init__.py`、README 一致，`generate_protocol.py --check` 会校验）
- 工作分支：`feat/0.9.0-reliability`
- M0 基线测试：Lua 全绿（Json/Transport/Actions/TalentQuery/Journal/Observer/Progression/Items/Tasks/Invocations/Runtime/Interactive/Chat/Compat），Python 26/26
- 反馈证据：`tmp/mcp-play-support/agent-ham-madness-01-report.md`（半身人-星月术士-疯狂实机，68 分钟 / 3911 条命令）

## 工作包状态

| 包 | 内容 | 状态 |
| --- | --- | --- |
| M0 | 基线与契约（`protocol/v4`、跨语言向量、`--game-root` 入口） | **完成**：`protocol/v4/{limits,common.schema,errors.schema,requests.schema,results.schema}` + `vectors/`；`tools/generate_protocol.py --check` 通过；`generate_native_seams.py`/`package.py` 支持 `--game-root`。与双端校验器的生成接线留到 M2/M4 |
| M1 | 纯查询修复（费用三态、纯度、`TalentQuery.lua`） | **完成**：QRY-04/05/07 三态与 `resource_checks`；QRY-08 统一 `Distance.lua`；QRY-02 只读依赖登记（身份基线）；QRY-09 纯度套件 `test_query_purity.lua`。文件摘要/加载链的完全统一留到 M4（CMP-01/03） |
| M2 | `CommandLedger.lua` 与 v4（规范序号、回收、双端接线） | **完成**：账本 + `tests/test_ledger.lua`；`Runtime` act/status/connect/observe 接账本、`history.next_command_id`、`command_history_expired/gap/conflict`；返回信封与 Python `BridgeClient`/MCP 工具/`RULES` 升到 v4，v3 返回 `protocol_mismatch`；`generate_protocol.py --check` 额外校验双端常量。真实 >4096 条命令的原生验收留到 M5 |
| M3 | `ObservationViews.lua` 冻结集合分页（`tome.list`） | 未开始 |
| M4 | 能力诊断、状态转换断言、响应预算、认证期限 | 未开始 |
| M5 | 原生回归、长序列、升级/回退、候选包验收 | 未开始 |

## 反馈报告 → Spec 映射

| 反馈（报告节） | Spec 对应 | 处理 |
| --- | --- | --- |
| §4.4 `affordable` 误报确定值 | QRY-04/05/07、B-03 | **M1 已修**：未知当前费用不再回退基础费用；新增 `resource_checks` 三态 |
| §4.2 `learn_talent` 仅审核树 | CMP-05、ADR-07 | M4：`action_support` 支持矩阵（本轮不扩职业） |
| §4.12 每条快照带整张地图 | OBS-08、NET-05 | M3/M4：`collection_refs`、`sections`/预算 |
| §4.8 地面物品不可见（实为控制台缺字段） | OBS-02 `ground_items` | M3：`tome.list(collection="ground_items")` |
| §4.1 换层后租约失效/错误信封 | STA-02h、API-03/04 | M2/M4；`result._error` 是临时控制台包装，桥接为顶层 `ok/error.code` |
| §4.3 `native_rejected` 无原因 | API-03（补充建议） | 待定：建议把 `insufficient_resource`/`cooldown` 纳入 CommandView details |
| §4.6 撞墙 `move` 返回 completed | API-03（补充建议） | 待定：`blocked` 语义 + `code` 枚举冻结 |
| §4.9 `inspect` 未知 kind（实为控制台） | API-04 | 桥接已返回 `invalid_inspect`；控制台需透传 |
| §4.10 `player` 缺 `id/exp/未用点` | OBS/API 字段 | 待定：纳入 `observe.player` 字段清单 |
| §4.11 事件 `remove` 无 `text` | Journal 文档 | 待定：文档标注 |
| §4.5 `rest` code 漂移 | API-03 | M4：冻结 `code` 枚举 |
| P0：`walk`/`explore`/`auto_combat`、`travel`、威胁换算 | **非目标**（ADR-07、§5） | 记入 backlog；本轮不做游戏内宏动作 |
| P0：全职业成长 | **非目标**（ADR-07） | backlog |
| 控制台 `agent-play.py` 假象（`_error`、缺 `ground`、`walk`） | 不属 MCP | 修 wrapper，不改桥接契约 |

## 单写者约束（Spec §2 / §8）

- 同一时期：`Runtime.lua`、`protocol/`、`tools/generate_native_seams.py` 各自只能有一个负责最终合并的修改者。
- 纯模块（`TalentQuery.lua`、`CommandLedger.lua`、`ObservationViews.lua`）与测试可并行编写。
- 不修改游戏核心；不手改 `GENERATED` 文件；运行态不入存档。
- 不新增任意 Lua 执行；不移除成长白名单；不引入多写者；轮询不自动重连/重发。

## 下一步

1. M3：`ObservationViews.lua` 冻结集合分页（`tome.list`）：九个集合、TTL/容量、`cursor_expired`、历史标记。
2. M4：`NativeCompatibility` 文件摘要/加载链统一审核（CMP-01/03）、`action_support` 矩阵（CMP-05）、错误 `acceptance_scope`/MCP 映射、认证期限。
3. M5：原生回归、真实 >4096 命令长序列、升级/回退、候选包证据。
