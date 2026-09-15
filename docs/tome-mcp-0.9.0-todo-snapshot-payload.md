# 待办：快照载荷裁剪（snapshot payload trimming）

状态：**待办**。等第一轮 Insane 实机测试结束后与反馈一并处理。
记录日期：2026-09-15。基线：0.9.0 / 内部协议 v4。

## 触发来源

用户观察：**每次快照都会把全部资源值传过去，但角色很多资源并未解锁，不需要全传。**

代码确认属实：`ObservationDetails.player` 对固定列表
`{'mana','stamina','vim','positive','negative','psi','hate','equilibrium','paradox','air'}`
逐个判断 `M.finite(p[name])` 就下发，**没有检查该资源对应的资源池天赋**。
在半身人/星月术士上，实际只有 `positive`/`negative` 有用，其余 8 项是默认值。

## 实测证据

会话 `agent-ham-insane-01`，`play-mcp.jsonl` 中最后一次原始 `observe` 快照：

```
快照总计 77480 字节
  59510  map                 (77%)
   6176  talents
   4394  player
       1920  player.equipment
        598  player.resources   ← 10 项，本职业约 80% 无用
        521  player.inventory
        199  player.stats
    2586  events
    1729  ground
    1709  actors
     820  collection_refs
     136  history
```

## 逐项待办

### P1-1 资源未按职业过滤（用户报告项）
- **现象**：`resources` 固定下发 10 项；本职业仅 `positive`/`negative` 有意义，仍是完整对象（value/min/max/regen）。
- **根因**：`data/resources.lua` 用 `ActorResource:defineResource(name, short_name, talent, ...)` 为每个资源关联一个资源池天赋（`T_MANA_POOL`/`T_STAMINA_POOL`/`T_VIM_POOL`/`T_POSITIVE_POOL`/`T_NEGATIVE_POOL`/`T_HATE_POOL`/`T_PSI_POOL`/`T_EQUILIBRIUM_POOL`/`T_PARADOX_POOL`/`T_SOUL_POOL`；`air` 的 talent 为 `nil`）。原生 `get<Resource>()` 在不知道该池天赋时返回 0，但快照直接读 `p[name]`，绕过了这层语义。
- **建议**：只下发"玩家已解锁"的资源——判定为 `p.talents[def.talent] ~= nil`（纯存储读取），并保留 `def.talent == nil` 的资源（如 `air`）；同时保留可用 `sections`/`filter` 显式索取全部。
- **涉及**：`overload/mod/mcp_bridge/ObservationDetails.lua`（`M.player`）；可在 `data/resources.lua` 读取 `resources_def[short_name].talent`（只读标量）。
- **验收**：本职业只出现已解锁资源；`air` 仍在；未知/未解锁资源不再出现；不改变已解锁资源的数值语义；补单元测试（星月术士只应见 positive/negative/air；战士见 stamina 等）。

### P1-2 默认快照内嵌完整背包/装备/技能，已被 `tome.list` 取代
- **现象**：每次 `observe`/`act`/`status` 都带 `talents`（6176B，含每个技能的 `description` + `activation` 块）、`inventory`+`equipment`（2441B）。
- **建议**：默认快照只保留**摘要 + 计数/截断标记 + `collection_refs`**；完整枚举走 M3 的 `tome.list`（`talents`/`inventory`/`equipment` 已有集合）。技能条目默认只给 `id/name/cooldown/supported`，细节走 `inspect`。
- **涉及**：`ObservationDetails.player`、`Observer.capture`、`ObservationCollections`。
- **验收**：默认快照不再含完整数组；`tome.list` 仍能完整枚举；截断语义（`capture_complete`）不变。

### P2-1 `map` 默认开启且在 act/status 上也带
- **现象**：`map` 占 59510B（77%）；控制台还按 radius 12 请求。虽已有 `include_map`，但默认 true 且每次 act 结果也带。
- **建议**：`act`/`status` 的快照默认 `include_map=false`；仅在显式 `observe` 或 `include_map=true` 时给窗口；或提供地图独立调用/增量。
- **涉及**：`Runtime.snapshot`/`commandView`、`ObserveArgs`（已有 `include_map`）。
- **验收**：无地图的 act/status 响应显著变小；显式请求仍可拿地图。

### P2-2 `events` 默认回最近 12 条
- **现象**：每条快照默认带 `events`（2586B），即使调用方没有传 `events_after`。
- **建议**：只有显式传 `events_after`（或新开关）时才返回；否则返回 `{cursor,head_cursor}` 空页。
- **涉及**：`Journal.capture`/`Runtime.snapshot`。

### P2-3 `ground` 每次快照都计算
- **现象**：`ground` 1729B，每次 observe 都算一遍可见地面物品。
- **建议**：默认不带，走 `tome.list(collection='ground_items')`。

### P3-1 `collection_refs`/`history` 每条快照都带
- **现象**：`collection_refs` 820B、`history` 136B。
- **建议**：`history` 只在 `connect`/`status` 或需要时给；`collection_refs` 可只在 `connect` 能力里给一次，或放进 `tome://rules`/资源。

### P3-2 常量说明串反复下发
- **现象**：`exp_scope`/`inventory_scope`/`combat_scope`/`merge_scope` 等固定文本每次快照都带（每条约 60–70B）。
- **建议**：移到 `tome://rules` 或 `connect` 的 `capabilities`，字段语义用文档承载。

### 低优先：`stats` 固定 6 项
- 属性是通用概念，保留可接受；仅在 `sections` 机制落地后按需裁剪。

## 建议的实现方式

引入/落实 `observe.sections`（v4 请求 schema 已有 `sections` 字段但未实现）：
`sections=["player","actors","talents","effects","inventory","ground","map","events","history"]`，
默认取一个"紧凑集合"，未选中的大集合以 `truncated=true` + `collection_refs` 指向 `tome.list`。
所有裁剪都必须保留"知识边界"与"完整性标记"语义，不能把截断冒充完整。

## 验收与回归

- 用 `play-mcp.jsonl` 同口径测裁剪前后快照字节并记录；
- 单元测试：资源过滤、sections 选择、`tome.list` 完整性、`include_map` 默认；
- 原生回归沿用 `tests/native/run.py` 与 `tests/native/long_session.py`；
- 更新 `docs/tome-mcp-api-fields.md` 与 `server/RULES`。

## 备注

本项属于"降低单位操作的 token/带宽成本"，与 M3 的 `tome.list`、`include_map`、`events_after`
是同一套机制的不同侧面；应与一轮实机反馈一起排期，避免只修资源而遗漏其余同类过传。
