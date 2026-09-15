# ToME MCP Bridge v3 契约：技能查询与目标预填

适用：本仓库 ToME 1.7.6、Bridge / Python server **0.8.0**。这是**唯一**的协议版本 3；已在测试阶段移除 v1/v2。完整配置见 [addon README](../README.md)；需求依据见 [功能扩展需求](tome-mcp-extension-requirements.md) 的 R5。

## 连接

调用 `tome.connect(mode="control")` 获取控制权；旁观使用 `mode="observe"`。TCP 信封的 `v` 固定为 `3`。目标、确认、列表、物品选择、连续回答、维持技能、原生任务和 `tome.respond` 全部可用；不再有 v1/v2 分支或降级。

## 只读技能查询

`tome.inspect(kind="talent", id=talent_id)` 在 v2 摘要之外返回 `query`；可选传入 `target_id` 或 `x`/`y` 以附加距离：

```json
{
  "session_id": "s1", "kind": "talent", "id": "T_RUSH",
  "target_id": "s1:level-1:actor-2"
}
```

```json
{
  "id": "T_RUSH", "level": 1, "cooldown": 0, "supported": true,
  "query": {
    "range": 6, "requires_target": true, "target_type": "actor",
    "cooldown_remaining": 0,
    "current_costs": {"stamina": 13.2}, "costs_complete": true,
    "base_costs": {"stamina": 12},
    "affordable": true,
    "readiness": "unknown", "readiness_reason": "native_precheck_not_run",
    "distance": 3, "in_range": true,
    "prefill_supported": true, "prefill_modes": ["actor", "position"],
    "query_is_advisory": true
  }
}
```

规则：

- 只读取存储字段与已审核标量。动态的 `range`、`requires_target`、`target` 函数**不执行**，一律标 `unknown`；不调用 `preUseTalent`、`info`、`target`、投射或命中计算，不消耗 RNG。
- `current_costs` 是**当前实时消耗**：按原生 `postUseTalent` 扣费公式 `alterTalentCost(基础)` 后乘资源 `cost_factor`（例如法力/耐力按当前疲劳 `(100 + n*combatFatigue)/100`，耐力还会受 Adrenaline Surge 等效果影响）。`base_costs` 是存储的基础值，供对照。仅当基础消耗是静态数值、且原生 `alterTalentCost`/`cost_factor` 未被改写时计算；动态基础或改写时 `current_costs[key]='unknown'` 且 `costs_complete=false`。
- 实时消耗会调用原生 `cost_factor`，存在相关被动时它会读取只读的疲劳 getter（如 `getFatigue`/`getFatigueBoost`）；这是只读计算，不产生副作用、不消耗 RNG，也不是技能动作或预检。
- `affordable` 基于 `current_costs`（不可得时回退 `base_costs`）与当前资源比较；不可知为 `unknown`。
- `readiness` 是保守提示：只有存储标量能明确证明被阻止时才为 `blocked`（如冷却中、已知资源不足、未学习），否则 `unknown`。它**不是**原生最终预检。
- `distance` 使用快照坐标的直线切比雪夫距离；`in_range` 仅在 `range` 为数值时给出。
- `target_id` 必须当前可见；不可见角色返回 `actor_not_visible`，不通过猜测 ID 绕过信息边界。
- 快照中的 `talents` 列表仍保持紧凑，不携带 `query`；查询仅在显式 `inspect` 时返回。

## 一次性目标预填

v3 的 `use_talent` 可带 `target_id` 或 `x`/`y`：

```json
{"type":"use_talent","talent_id":"T_RUSH","target_id":"s1:level-1:actor-2"}
{"type":"use_talent","talent_id":"T_RUSH","x":10,"y":8}
```

规则：

- `target_id` 与 `x`/`y` 互斥，且 `x`、`y` 必须同时提供；违反返回结构错误，不提交游戏动作。
- 预填只在**第一次原生 `getTarget` 消费一次**，随后立即恢复原生 `getTarget`；同一技能后续的目标、确认或列表问题仍按 v2 产生 `awaiting_input`，用 `tome.respond` 回答。
- **射程与边界沿用原生规则**：提交前按技能的静态射程拒绝越程（`target_out_of_range`，0 能量）；射程为动态函数时，在第一次 `getTarget` 处按原生目标参数校验，越界/越程或会触发原生自我警告时**回退到原生目标流程**（返回 `awaiting_input`），不盲发坐标。
- `tome.respond` 的 `target.grid` 位置答案同样按原生射程校验，越程返回 `position_out_of_range`。
- 不设置全局 `target.forced`，不指定目标路径或重定向结果；投射路径阻挡与技能自身的最终合法性仍由原生 `project`/目标流程决定。
- `target_id` 必须当前可见；未解析到当前可见角色时返回 `target_lost`，不消耗能量。
- 预填是优化不是保证：原生可能修正、拒绝或改为询问其它目标，结果以实际原生结算为准；失败不自动重试。
- 预填参与 `command_id` 去重指纹，重复提交同一请求返回原记录。

## 能力声明

`connect(protocol_version=3)` 的 `capabilities` 在 v2 基础上增加：

```json
{"protocol": 3, "talent_execution": "native_interactive",
 "talent_query": true, "talent_prefill": ["actor", "position"]}
```

`talent_prefill` 列出本版本支持的预填模式；不在此列的输入方式（如直接方向预填）尚未提供。

## 兼容与验收

- 原生方法插入点未修改核心游戏文件；打包前由 `tools/generate_native_seams.py` 校验一致性。
- 观察纯度回归继续要求查询路径不调用 RNG、`preUseTalent`、动态 `info`、鉴定或命名函数。
- 单元覆盖：v3 校验组合、动态字段标 `unknown`、可负担性与 readiness、一次性消费与后续原生目标、`target_lost` 边界。
- Python 覆盖：`protocol_version=3` 接受、非法版本拒绝、预填互斥与成对校验、`inspect` 附加目标参数、v3 `respond`。
- 真实游戏的原生施法与预填场景由隔离验收补充；未实际通过的组合不写成已支持。
