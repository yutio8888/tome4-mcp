# 第五轮 Insane 实机反馈：处理记录

来源：`tmp/mcp-play-support/agent-ham-insane-05-report.md`（半身人/星月术士/Insane，存活 Lv5，清 Trollmire 1–2 层，击杀 rank4 Prox the Mighty，完成护送）。
处理日期：2026-09-16。基线：0.9.0 / 内部协议 v4。

## 逐条处理

| 报告 | 状态 | 处理 |
| --- | --- | --- |
| 3.1【P0】`change_level` 后租约丢失，但 `observe` 仍 `phase=ready` | **已修（MCP）** | 快照 metadata 新增 `actionable`（`phase==ready` 且持有 control）、`control_lease='held'/'released'`、`needs_reconnect`（control 模式但无租约）。恢复仍走显式 `connect`。控制台 summary 透传这三个字段。 |
| 3.2【P0/控制台】`walk` 把错误吞成 `status:null` | **已修（控制台）** | walk 条目在收到 `_error` 时原样带上 `error`，并停止；不再静默。 |
| 3.3【P0】`observe.actors` 混入友军，`walk` 不按阵营过滤 | **部分（MCP+控制台）** | `actors[]` 新增 `reaction`（存储标量）与 `hostile`（`reaction<0` 时为 true，否则 null）。控制台的 walk 只把 `hostile` 为 true、或（unknown 且 faction 与玩家不同）的 actor 视为敌人。更精确的 `reactionToward` 计算涉及动态调用，未在只读查询中执行。 |
| 3.5【P1】`target_geometry` 缺 `selffire` → 自伤 36 | **已修（MCP）** | `target_geometry.selffire` 现在**总是**存在：原生给布尔时用布尔，否则为 `"unknown"`。RULES 说明 `unknown` 时不要以自己附近为球心。 |
| 3.7【P1】`awaiting_input` 返回动作前旧 snapshot | **已修（MCP）** | `commandView` 对 `awaiting_input` 且无快照时返回**实时快照**并标 `snapshot_scope="live"`。 |
| 3.8【P1】部分原生弹窗无 interaction，只能按键 | **已修（MCP）** | `Interactions.adoptNotice` + `Runtime.boundary('dialog')`：对进行中的 remote 命令，把无主但可关闭的原生弹窗接管为 `dialog.notice`（带 Close 选项），可 `respond`；否则仍 manual 交接。 |
| 3.4【P1】新学技能满 CD / `cooldown` 语义 | **已修（MCP）** | talent summary 增加 `base_cooldown`（静态基础值），与 `cooldown`（当前剩余）区分；RULES/文档说明"刚学会即满 CD"是原生行为。 |
| 3.11【P2】`list.items` 空时是 `{}` 而非 `[]` | **已修（MCP）** | `ObservationViews` 分页的 `items` 改为 `Json.array()`，空集合编码为 `[]`。 |
| 3.12【P2】walk 每步回整个 player（~2.5KB/步） | **已修（控制台）** | walk 条目 player 精简为 `{x,y,life}`；中断条带 `enemies` 摘要。 |
| 3.6/3.9/3.10/3.12 其余 | **记录** | 动态字段（radius 等）本质 unknown；`native_progression_rejected` 未列缺失项；错误未附当前 interaction id；`events` remove 无 text；`inspect actor` 无 `self` 别名；武器缺 accuracy 等。列入 TODO。 |

## 本轮提交

- MCP：`Runtime.lua`（meta actionable/lease/needs_reconnect、awaiting_input 实时快照、boundary 接管 notice）、`Interactions.lua`（openDialog owner 参数、adoptNotice）、`Observer.lua`（reaction/hostile）、`Actions.lua`（selffire always、base_cooldown）、`ObservationViews.lua`（items 数组）、`protocol/v4/results.schema.json`（snapshot_scope）。
- 控制台（测试用）：`agent-play.py`（summary 透传 actionable/needs_reconnect/control_lease；walk 错误透传、阵营过滤、精简 player）。
- 测试：Lua 全绿、Python 30、协议 OK（CommandView 35 字段）。

## 仍待办

`native_progression_rejected` 缺失项、错误附当前 interaction、`events` remove text、`inspect actor self`、武器 accuracy、notice 接管的原生复现验证、`observe.sections`、API-05/STA-03。
