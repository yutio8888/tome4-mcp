# 待办：技能加点（成长支持范围）

状态：**待办**。等第一轮 Insane 实机测试结束后与其它反馈一并处理。
记录日期：2026-09-15。基线：0.9.0 / 内部协议 v4。

## 触发来源

用户观察：**测试 agent 似乎无法完成技能加点。**
本轮 `agent-ham-insane-01`（半身人/星月术士/Insane）实机确认属实。

## 实测证据（本轮原始 MCP 记录）

`tmp/tome-mcp-validation/sessions/agent-ham-insane-01/play-mcp.jsonl`：

```
spend_stat mag            -> completed progression_applied
learn_talent T_MOONLIGHT_RAY  -> failed unsupported_progression_talent
learn_talent T_SEARING_LIGHT  -> failed unsupported_progression_talent
learn_talent T_HEIGHTENED_SENSES -> failed category_locked
```

即：**属性点可以加（`spend_stat` 成功）**，但**职业技能点加不上**。
`inspect(kind="progression", id="player")` 里 Celestial 各树为 `supported=false`。

## 根因

`overload/mod/mcp_bridge/Progression.lua` 维护一份**硬编码的已审核技能树白名单**：

```lua
addCategory('technique/2hweapon-assault', ...)
addCategory('technique/strength-of-the-berserker', ...)
...
addCategory('cunning/survival', ...)
addCategory('technique/combat-training', ...)
```

只覆盖 Berserker 时代的 technique/cunning 树。Celestial 星月术士的核心树
（`celestial/star-fury`、`celestial/sunlight`、`celestial/twilight`、
`celestial/hymns` 等）**不在白名单**，因此：

- `learn_talent` 的校验/摘要路径 `if not spec then return nil,'unsupported_progression_talent'`
  （`Progression.lua` 约 150 行）直接拒绝；
- 即便某些通用树在名单内（如 `cunning/survival`），若角色未解锁该类别，
  仍会被 `category_locked` 拦下（约 261 行 `req.category_known`）。

## 影响

- 星月术士（以及所有非 Berserker 职业）**无法用职业点/通用点提升技能**，角色成长被截断；
  在 Insane 下战力迅速落后。
- `action_support.learn_talent` 已标为 `limited`（M4/CMP-05），但缺少机器可读的
  `unsupported_reason` / 支持树清单，agent 只能反复试探。
- 与上一轮实机反馈报告 §4.2 一致。

## 建议改法（按优先级）

### P1 通用原生升级路径（推荐，spec 审查也建议）
不再按树白名单拒绝，而是走原生 `LevelupDialog` 的 `learnTalent` 校验：
- `Progression.execute` 已在用 `dialog.learnTalent(host, a.talent_id, true)`（约 485 行）；
- 让 `learn_talent` 对该角色**已知类别**中的可见技能直接交给原生对话框判定
  （原生 `checkDeps`/点数/等级/需求由游戏裁决），桥接只做"知识边界 + 只读摘要"；
- 需要审核对话框方法与 `checkDeps` 链（`dialog_methods` 已在跟踪），并提供失败时的
  `needs_input` 回退。

### P2 扩大已审核树（过渡）
把 Celestial 等职业树按现有 `addCategory` 结构登记（含 requirement 公式与 `minimum`）。
工作量大且 spec ADR-07 明确本轮不做，只作为短期兜底。

### P3 机器可读的支持矩阵
- `inspect(kind="progression")` 每个 `supported=false` 的技能/树给出 `unsupported_reason`
  与 `detail_collection`；
- `capabilities.action_support.learn_talent` 指向当前可加点树清单；
- 失败时明确"该树尚未适配，可用 needs_input 交玩家手动加点"，而不是静默硬失败。

## 验收

- 星月术士能用职业点在原生路径下学会 `T_MOONLIGHT_RAY`（点数/等级/需求由原生判定）；
- 属性点语义不变（`spend_stat` 继续通过）；
- 未解锁类别仍返回可解释的 `category_locked`；
- 单元测试覆盖"已知类别 + 可见技能走原生校验"；原生验收加一个 Celestial 技能用例；
- 不泄露玩家原本不可见的技能树（沿用现有 `visibleTalent` 知识边界）。

## 备注

本条与"快照载荷裁剪"待办（`docs/tome-mcp-0.9.0-todo-snapshot-payload.md`）不同：
后者是**成本**问题，本条是**能力**问题（角色能否成长）。两者都应在第一轮实机反馈后
统一排期；本条优先级更高（直接影响 Insane 是否可玩）。
