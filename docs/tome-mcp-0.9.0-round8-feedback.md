# 第八批修复：CharacterSheet（A+B）与一批待办

> **历史资料，非规范（Historical / non-normative）。** 本文是当时一批修复的处理记录。其中 `:7` “只读存储值……不求值
> （保持纯度）”与 `:32` “在不运行动态 `require` 的前提下给提示”体现的是已被 `AGENTS.md` 与
> `docs/tome-mcp-auto-combat-plugin-design.md` §8.3 **取代**的读取纯度前提。当前读取仅受两条红线约束
> （不提交动作、不泄露玩家未知信息）；当前实时的 getter/需求函数可调用（允许 RNG/读副作用），
> 不可得时标 `unknown`。历史观测与哈希保留作证据。

日期：2026-09-16。基线：0.9.0 / 内部协议 v4。

## A. 角色面板（CharacterSheet）读接口

- **新增 `tome.inspect(kind="character", id="player")`（也接受 `"self"` 或玩家 actor id）**：聚合原生面板的**存储字段**——`descriptor`、`level/exp/exp_next`、`life/max_life/life_regen/die_at`、`energy`、`resources`、`stats{base,bonus}`、`effects`、`sustains`、`inventory/equipment`、`unused_*`、`type/subtype/rank/faction`，以及 `base_combat`/`base_weapon`/`base_resists`/`speed`。结果带 `character_scope` 说明：**只读存储值，装备/效果的计算值（有效命中/防御/伤害/护甲/豁免/见隐等）不求值**（保持纯度）。（**历史注：** “保持纯度”现已废弃；只读接口可调用实时 getter 求值，允许 RNG/读副作用，不可得时标 `unknown`。）
- **`inspect(kind="actor", id="self"|"player")`** 现在支持自身别名（修复 `actor_not_visible`）。
- `capabilities.inspect_kinds` 增加 `character`；`server/RULES` 同步。

## B. 控制台面板摘要

- `observe` 的 compact `player` 现在带：`id/faction/type/subtype/rank/stats/descriptor/energy/life_regen/unused_stats/unused_talents/unused_generics/unused_talents_types`（此前只有 name/x/y/life/level/exp）。
- 新增控制台命令 **`{"sheet":true}`** → 直出 `inspect(kind="character", id="self")`。

## 本批其它已修

| 项 | 处理 |
| --- | --- |
| **A1 API-05：MCP `isError` 映射** | 工具改为可返回 `CallToolResult`：`ok=false` → `isError=true` 且保留结构化 error；已接收的 `act`/`respond` 以 `failed`/`cancelled` 终结 → `ok=true` + 完整 CommandView 且 `isError=true`；只读 `status` 读同一失败回执 → `isError=false`。回归：`test_api05_iserror_mapping`（Python 32）。 |
| **B2 交互错误带当前 interaction_id** | `respond`/`dismiss` 的 `interaction_expired`/`interaction_consumed`/`answer_type_mismatch`/`option_expired` 等错误现在附 `interaction_id`（当前有效值）。 |
| **B3 `events` remove 带 text** | `Journal` 的 `remove` 事件现在携带被移除行的文本。 |
| **C `observe.sections`** | 实现顶层域裁剪（`player/map/ground/actors/talents/events/dialogs`）；身份/元数据字段（session/revision/phase/actionable/lease/history/collection_refs/pending_command/interaction）始终保留；非法 section 返回 `invalid_sections`。 |
| **E 控制台 `status` 通道** | 新增 `{"status":true|"<command_id>"}` → 直连 `tome.status`。 |
| **A2 STA-03（轻量）** | `Runtime` 每帧后检查不变量（`W<=H`、`queued` 不得已释放、快照条数 ≤16），失败即记录 `invariant_*` 并隔离写入。 |

## 仍待办（明确记录）

- ~~**A3 CMP-01/03**：函数级摘要与更深间接依赖闭包。~~ **Superseded (v1.6, 见文首 banner)：**
  运行期身份/摘要/闭包门槛已废弃；直接调用实时 getter，报错/缺失/`nil` 时才视为不可得。源摘要仅作重审遥测。
- **A4 隔离态恢复通道**：`native_error` 后本会话只读，缺 `abandon`/`reset invocation`（需设计，避免伪造回滚）。
- **A5 command-staff chat 协程兼容**：目前黑名单 `T_COMMAND_STAFF`；真修需 seam 容忍外部 `coroutine.resume`。
- **B1** `native_progression_rejected` 缺失项（等级/属性/前置/点数）；需在不运行动态 `require` 的前提下给提示。（**历史注：** 该“不运行 `require`”前提已废弃；可调用实时 `require` 函数求值，不可得时标 `unknown`。）
- **B5** 武器/装备命中信息：`wielder.combat_atk/combat_def` 已给穿戴者贡献；武器本体缺 `def`（文档说明）。
- **B6** actor id 不稳定（文档：每次 observe 取新 id）。
- **B7** `target_geometry.damage_scope`（beam selffire 保守 unknown；Searing 是 hit+光域）。
- **B8** 地面持续效果不可见。
- **B9** ego 物品名占位符清洗后留空括号，宜用原生 display name。
- **D1 G-03** 普通有限流程（≥500 命令、≥2 换层）完整跑通；**D2 G-04** 原生内存/延迟实测；**D3** 插件组合验证。
- **控制台** `key` 任务状态信号。

## 校验

- Lua 全绿（progression 235、runtime 79 等）、Python **32**、协议 OK、已重新打包。
