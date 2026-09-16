# 第六轮 Insane 实机反馈：处理记录

来源：`tmp/mcp-play-support/agent-ham-insane-06-report.md`（半身人/星月术士/Insane，Lv1 整局冻结）。
处理日期：2026-09-16。基线：0.9.0 / 内部协议 v4。

## 逐条处理

| 报告 | 状态 | 处理 |
| --- | --- | --- |
| 2.1【P0】未知顶层命令键被静默当成 observe（`ok:true` 无动作） | **已修（控制台）** | `agent-play.py` 现在只把 `{}`/`{"observe":true}` 当观察；其它未知顶层键返回 `{"ok":false,"error":{"code":"unknown_command_key","keys":[...],"hint":...}}`，不再静默观察。prompt 也明确必须用 `{"action":{...}}`。 |
| 2.2【P0·致命】`T_COMMAND_STAFF` 原生 command-staff chat 用 `coroutine.resume(co,true)` 复活天赋 body，与 `Tracker.createBody` 冲突 → native Lua Error + 游戏冻结 | **已修（护栏）** | `Actions.admit` 拒绝 `T_COMMAND_STAFF`，返回 `talent_interaction_unsupported`（`capabilities`/`describe` 同步标记）。这样 agent 无法触发该原生错误与随后的整局冻结。真正的协程兼容修复（seam 容忍外部 resume）列为后续课题。 |
| 2.2(d) 隔离态 `needs_reconnect:true` 是假线索 | **已修（MCP）** | 当 `s.native_error` 存在时 `needs_reconnect` 不再为 true，并新增 `recovery:"fresh_load_required"`，明确本会话只读、需重新读档。 |
| 2.3【P1】`respond` 的 answer 必须带 `type`，prompt 说反 | **已修（文档）** | RULES 明确 answer 必须含 `type`（如 `{"type":"option","option_id":...}`）。 |
| 2.4【P2】`selffire` 对 beam/ball 都是 `"unknown"` | **保留** | 原生 `selffire` 多为动态/函数值，只读查询不执行；`"unknown"` 是如实表达。RULES 已要求 unknown 时不要以自身附近为球心。 |
| 2.5/2.6【P2】隔离态 `pending_command` 无行动信息；控制台无 `tome.status` 通道 | **记录** | 隔离态本身不可恢复；控制台缺少 status 直连。列入 TODO。 |

## 本轮提交

- MCP：`Actions.lua`（`UNSUPPORTED_TALENT_INTERACTIONS` + `admit` 拒绝）、`Runtime.lua`（`recovery`、native_error 下不报 needs_reconnect）、`server/src/tome_mcp/server.py`（RULES：answer 带 type、T_COMMAND_STAFF 不支持）。
- 控制台（测试用）：`agent-play.py`（未知顶层键报错）。
- 测试：`tests/test_actions.lua`（+1，拒绝 T_COMMAND_STAFF）。
- 校验：Lua 全绿、Python 30、协议 OK。

## 仍待办

command-staff chat 协程兼容的原生修复（或更通用的"外部 resume 检测"）、隔离态恢复通道（`abandon`/`reset invocation`）、`native_progression_rejected` 缺失项、错误附当前 interaction、`events` remove text、`inspect actor self`、武器 accuracy、控制台 `status` 通道、`observe.sections`、API-05/STA-03。
