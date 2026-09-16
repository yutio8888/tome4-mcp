# 第七轮 Insane 实机反馈：处理记录

来源：`tmp/mcp-play-support/agent-ham-insane-07-report.md`（半身人/星月术士/Insane，L6，清完 Trollmire 1–3、击杀 Prox the Mighty、完成护送，最终在 Ruins of Kor'Pul 1 被 Ce'Nutira 击杀）。
处理日期：2026-09-16。基线：0.9.0 / 内部协议 v4。

## 逐条处理

| 报告 | 状态 | 处理 |
| --- | --- | --- |
| 1 戒指 `FINGER` 无法装备（`unsupported_equipment_slot`） | **已修（MCP）** | `Items.lua` 的 `equipment_slots` 白名单写成 `RING`，实际 `obj.slot` 是 `FINGER`；加入 `FINGER=true`。 |
| 2 `unlearn_talent` 免费洗点（`points_returned=1`） | **已修（MCP，opt-in）** | 洗点绕过原生 respec 道具/费用，改为**显式 opt-in**：仅当 `config.settings.tome_mcp_bridge.allow_respec==true` 才允许，否则返回 `respec_not_enabled`。`capabilities.action_support.unlearn_talent` 增 `enabled_by='settings.allow_respec'`，RULES 说明。回归：无该设置时拒绝；开启时原生语义（recent window/out-of-combat）仍生效。 |
| 3 非 MCP 命令触发的原生弹窗（封印门/Lore/Running/死亡）无 `option_id`，`respond`=No pending interaction | **已修（MCP + 新工具）** | 新增**会话级 interaction**：`Runtime.nativeUIOwner` 在无活跃命令但持有控制租约时回退到 `session_root`，使 `NativeDialogSeams`（yesno/list/simple/Quest/Lore）在命令之外也能注册交互；`boundary('dialog')` 对会话拥有的弹窗不再撤权，并对无主可关闭弹窗尝试 `adoptNotice(detail, session_root)`。`observe` 顶层新增 `interaction`。新增 `tome.dismiss`（MCP 工具 + 内部 `dismiss` op）回答这类无 `command_id` 的弹窗（option/cancel）。 |
| 4.1 物品名残留 `#RESIST#`/`#MASTERY#`、弹窗标题残留 `#0080FF#` | **已修（MCP）** | `ObservationDetails.text` 统一清洗 ToME 标记（`#...#`、`#{...}#`、`##`），物品名/弹窗标题/interaction 文本一致。备注：未展开的 ego 占位符会被清成空括号；后续可改用原生 display name。 |
| 4.2 actor id 不稳定导致 `target_lost` | **文档** | 需每次 observe 取新 id；`target_lost` 不消耗回合（已有）。 |
| 4.3 `target_geometry` 精度（beam selffire、Searing 实际是 hit+光域） | **记录** | beam 的 `selffire` 保守为 `"unknown"`；Searing Light 的直接伤害是 `hit`、`radius 1` 是残留光域。列入 TODO（可给 `damage_scope`）。 |
| 4.4/4.5 respond 与租约时序等 | **记录** | 列入 TODO。 |

## 新增能力说明

- `tome.dismiss(session_id, control_token, answer, interaction_id?, expected_revision?, include_map?)`：回答**非命令上下文**的原生弹窗。`observe` 的顶层 `interaction` 给出可用 `answer_types`；命令内的交互仍用 `tome.respond`。
- `unlearn_talent` 默认关闭，需在 `mcp-bridge.cfg` 的 `tome_mcp_bridge` 表里加 `allow_respec = true`。

## 本轮提交

- MCP：`Items.lua`（FINGER）、`ObservationDetails.lua`（标记清洗）、`Runtime.lua`（session_root、nativeUIOwner 回退、boundary、observe.interaction、dismiss op、capabilities）、`Progression.lua`（allow_respec 门禁）、`server/src/tome_mcp/server.py`（tome.dismiss 工具、RULES）。
- 测试：`test_progression.lua`（+1，respec opt-in）、`server/tests/test_server.py`（+1，dismiss；工具数 9）、`tests/native/mcp_smoke.py`。
- 校验：Lua 全绿、Python 31、协议 OK。

## 仍待办

`native_progression_rejected` 缺失项、错误附当前 interaction、`events` remove text、`inspect actor self`、武器 accuracy、actor id 稳定/文档、`target_geometry.damage_scope`、控制台 `status` 直连、`observe.sections`、API-05/STA-03。
