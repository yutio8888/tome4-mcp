# 第四轮 Insane 实机反馈：处理记录

> **历史资料，非规范（Historical / non-normative）。** 本文是当时一轮测试的反馈处理记录。其中“需求函数是
> 动态的，只读查询不求值”的写法受当时纯度前提影响，已被 `AGENTS.md` 与 `docs/tome-mcp-auto-combat-plugin-design.md`
> §8.3 **取代**：读取仅受两条红线约束（不提交动作、不泄露玩家未知信息），实时 getter 可调用（允许 RNG/读副作用）。
> 历史观测与处理结果保留作证据。

来源：`tmp/mcp-play-support/agent-ham-insane-04-report.md`（半身人/星月术士/Insane，存活 Lv1，9 杀）。
处理日期：2026-09-16。基线：0.9.0 / 内部协议 v4。

## 关键发现：费用查询在生产环境全部降级为 unknown（F1 回归）

`inspect compatibility` 显示所有 `resource.cost_factor:*` 都是
`state=unverified, reason=dependency_source_unverified`，导致
`current_costs.negative="unknown"`、`affordable="unknown"`、`readiness_reason="native_precheck_not_run"`。

根因：`TalentQuery.registerNative` 登记 cost_factor 时用的路径是 `data/resources.lua`，
但游戏内该函数的 `debug.getinfo(fn).source` 是 `@/data/resources.lua`（**带前导 `/`**），
`auditedMethod` 的精确匹配失败。另：`pairs(resources_def)` 同时遍历了数字下标，产生
`resource.cost_factor:10` 之类的重复登记。

修复：路径改为 `/data/resources.lua`；只登记字符串短名键。修复后费用/可负担性应恢复为确定值（下轮重启后实机复核）。

## 逐条处理

| 报告 | 状态 | 处理 |
| --- | --- | --- |
| 2.2 `send.sh` 未设 `TOME_AGENT_SESSION` 静默连到 `agent-ham-madness-01` 并挂 1200s | **已修（控制台脚本）** | `send.sh` 现在**必须**有 `TOME_AGENT_SESSION`，否则立即报错；session 的 FIFO/log 不存在时也快速失败；不再硬编码 fallback。已清理残留 `madness-01.cmd`。 |
| 2.1 `{"map":true}` 只返回 `x/y/rows/legend`，无 `cells` | **已修（控制台）** | `map` 命令返回 `{x,y,width,height,rows,legend,exits,cells}`（`cells` 含 `name/blocked/block_status/door/is_exit`）；新增 `mapjson.sh` 供 `jq`。**需重启控制台生效**。 |
| 2.3 行数计数器竞态导致偶发超时 | **已修（控制台脚本）** | `send.sh` 增加 session 校验；并发/复用风险随"必须具备 session + 快速失败"降低。 |
| 3.1 `set_sustain` 字段名 `enabled`（非 `active`） | **文档修正** | RULES 明确 `set_sustain` 用显式 `enabled` 布尔；prompt 同步。 |
| 3.2 `progression_talents` 对 generic 技能误报 `readiness=available`（真实有角色等级前置） | **已修（MCP）** | 未审核（generic）技能的 `readiness` 不再报 `available`，改为 `unknown` + `native_precheck_not_run`（需求函数是动态的，只读查询不求值）；`requirements.status` 保持 `unknown`。 |
| 3.3 sustain 在 `observe.effects` 不可见 | **已修（MCP）** | 快照新增 `player.sustains=[{id,name}]`；控制台 summary 透传 `sustains`。 |
| 3.4 费用只显示"费用"不显示符号/产出语义 | **已修（MCP，见上）** | 修复 cost_factor 审核后 `current_costs/affordable` 恢复确定值；`resource_checks` 已有 `operation=debit/credit/none` 与 `pool_delta`（Searing 的 `positive=-15` 应显示为 credit）。 |
| 3.5 `target_geometry` 字段存在性不一致 | **说明** | `radius` 仅当原生 spec 给出时才有；`selffire` 仅当原生给布尔时才有；`Twilight`（self）无目标 → `null`。已在 prompt/RULES 说明按 `shape` 判断。 |
| 3.6 `walk` + `stop_on_enemy:"visible"` 起手见敌就不动 | **已修（控制台）** | `walk` 返回 `moved_steps` 与 `stop_reason`（`blocked_on_enemy`/`not_ready`）；prompt 说明 `visible` 对远处敌人也敏感，接近用 `adjacent`/`never`。 |
| 3.8 `list`/`inspect`/filter 字段名 | **文档修正** | RULES 列出 `tome.list` 各集合的 filter 键（`progression_talents` 需 `category_id` 等）。 |
| 3.9 冷却/拒绝信息 | 正面 | 无需改动。 |
| 4 结论 | — | 核心链路正常；本轮卡点来自控制台包装脚本与 `map` 缺 `cells`，均已修。 |

## 本轮提交

- MCP：`TalentQuery.lua`（cost_factor 审核路径修正 + 只登记短名键）、`Progression.lua`（generic readiness=`unknown`）、`ObservationDetails.lua`（`sustains`）、`server/src/tome_mcp/server.py`（RULES）。
- 控制台/脚本（测试用）：`send.sh`（fail-fast + 必须 session）、`agent-play.py`（`map` 带 `cells/exits`、`walk` moved_steps、summary `sustains`）、`mapjson.sh`、`map.sh`。
- 测试：`test_progression.lua`（generic readiness 预期更新）；Lua 全绿、Python 30、协议 OK。

## 仍待办

notice 接管（T-1）、`observe.sections` 裁剪、`walk` 的真实 `moved_tiles`（原生）、地面持续效果可见、API-05/STA-03。
