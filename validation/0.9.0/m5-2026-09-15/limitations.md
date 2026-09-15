# 0.9.0 候选 m5-2026-09-15：已知限制

本候选绑定 0.9.0 / 内部协议 v4。它证明的是有限范围的可靠性加固，不声称整场
战役、全职业或全 Mod 组合。

## 已通过

- **G-01 原生回归**：隔离 native fixture（`mcp-probe` arena）100/100 检查通过，
  覆盖移动、等待、普通攻击、技能（瞬发/目标/冷却拒绝）、多步骤交互、换层、
  物品、已审核成长、世界地图、保存与副本重载、X11 真实按键撤权。证据见
  `native-vanilla.json`。
- **G-02 超过旧命令上限**：同一会话内 5000 条独立命令被接收并结算，
  `H=5000`、`W=4744`、`retained_count<=256`；断开后显式重连保持同一会话；
  `cmd-1` 返回 `command_history_expired`（`accepted=true`、`recovery=do_not_replay`）；
  已用身份改动作返回 `command_conflict` 且原生动作计数不变。证据见
  `long-session.json`。
- **G-05 存档与版本边界（部分）**：副本重载后建立新会话，旧会话请求被拒绝，
  测试前后核心文件与 fixture 存档摘要不变（含于 G-01）。
- Lua 单元、Python/SDK 单元、协议契约检查、原生 seam 生成检查全部通过。

## 部分完成

- **G-03 普通有限流程**：用普通存档 `campaign-play-01` 的副本运行 522 条命令
  （无 probe），覆盖换层、物品/装备可见性、原生休息、治疗/野性纹身、敌人
  inspect；但驱动要求的 5 个核心技能未在界内全部覆盖
  （`T_STUNNING_BLOW_ASSAULT` 等缺失），且只发生 1 次换层。证据见
  `campaign-ordinary.json`。
- **G-04 内存与响应预算**：纯账本 1,000,000 条命令（~1.0s，retained≤256、
  bytes≤4MiB）与 10,000 次视图创建/回收（~0.7s，views≤4）已实测并有界，证据见
  `performance.json`。**未测量** Lua 堆、Python RSS、p50/p95/p99 响应时间与
  长会话内存趋势。
- **函数级摘要与间接依赖闭包（CMP-01/03）**：只做到“来源路径 + 完整文件摘要 +
  定义行 + 函数身份”；并额外把 `combatFatigue` 作为 `cost_factor` 的传递依赖
  登记，替换它会让相关费用 unknown。更深的闭包（如
  `costFactor → knowTalent → 任意第三方 getter`）仍不在防护范围内。

## 未运行 / 未完成（不得当作通过）

- **插件组合**：本候选只在“纯原版 + bridge + mcp-probe”上运行。Battle
  Companion / Danger Alert 组合未在本候选验证；不得据此声称组合兼容。
- **MCP `isError` 映射（API-05）**：Lua 与 Python 的 `ok/error` 已区分，但当前
  MCPServer 的 `convert_result` 会按返回注解 `ToolReply` 生成结果，无法同时
  保留结构化结果并置 `isError`；完整实现需要绕过转换层，属后续工作。
- **状态转换断言框架（STA-03）**：未实现带名称的转换断言。

## 环境

- 游戏：ToME 1.7.6，隔离用户目录与存档副本；核心文件未修改。
- 原生 fixture 使用 `mcp-probe` 测试插件，不进入正式包。
- 证据中的 token 已脱敏；不包含用户原存档或不可分发资产。
