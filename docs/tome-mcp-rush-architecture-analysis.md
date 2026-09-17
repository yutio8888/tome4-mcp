# Rush 接入与 MCP 技能架构差距分析

> **历史资料，非规范（Historical / non-normative）。** 本文是当时的架构差距分析。其中“只读纯性（零 RNG/
> 回调/状态/共享目标表变更，未知就是 unknown）”、“不能从只读路径调用 `getTalentTarget`/`getTalentRange`”
> 与“函数身份/定义位置审计”的前提已被 `AGENTS.md` 与 `docs/tome-mcp-auto-combat-plugin-design.md` §8.3
> **取代**：当前只读边界仅为**不提交动作、不泄露玩家未知信息**，实时 getter/builder（含 `t.target`/
> `getTalentTarget`/`getTalentRange`）可调用（允许 RNG/读副作用）；源摘要/身份只作重审遥测，不是运行门禁。
> 保留原文仅作历史证据。

日期：2026-09-15。范围：当前工作区源码的独立架构审阅与方案。本轮只新增本文；不修改生产代码、版本、安装包或历史验收证据，不进行游戏操作。已检查仓库及 `/workspace`、根目录的适用 `AGENTS.md`，未发现额外规则。

## 1. 结论

**标准 Rush 的直接阻塞是 `Actions.catalogue` 没有 `T_RUSH`，现有 MCP 请求格式已经能表达它。** 普通、已学习、未经替换的 Rush 使用一次 actor 目标，可以沿现有 `use_talent` → 原生 `useTalent` 执行。静态审核条件均匹配：原生默认 activated、requires_target=true，action/target/on_pre_use 来自同一标准文件，无 post_action；不需要为 Rush 新造移动算法、坐标 DSL 或多步对话框架。

**“能通过现有白名单审核”尚不等于“只改一行就具备完整发布保证”。** 建议同阶段处理普通技能已有的部分异常隔离缺口，明确 force_target 的玩家目标规则与原生重定向语义，并做 Rush 原生回归。动态范围/成本发现属于紧随其后的可用性改进；坐标、方向、持续技能和多阶段 continuation 属于后续扩展，不应全部成为 Rush 的前置工程。

本报告中的故障描述是源码推导，测试矩阵是待执行计划；没有把尚未实测的异常场景写成已复现结果。

## 2. 当前调用链与直接阻塞

| 层 | 当前行为与证据 | 对 Rush 的影响 |
| --- | --- | --- |
| Python schema | [server.py:18](../server/src/tome_mcp/server.py#L18) 禁止额外字段；[server.py:45](../server/src/tome_mcp/server.py#L45) 的 TalentAction 接受任意 talent_id 字符串和可选 target_id，没有技能 ID 枚举 | 无需新增 Python Rush action 类；未带目标仍由 Lua 作最终校验 |
| MCP 请求 | [server.py:216](../server/src/tome_mcp/server.py#L216) 序列化规范化 action；[bridge.py:180](../server/src/tome_mcp/bridge.py#L180) 只提交一次，然后轮询同 command_id | 现有幂等恢复可复用 |
| 接受与排队 | [Runtime.lua:390](../overload/mod/mcp_bridge/Runtime.lua#L390) 先 validate，再按完整 JSON 指纹去重，随后检查 lease、revision、ready，注册 onTickEnd | 当前在这里得到 unsupported_talent，尚未进入游戏技能 |
| 技能白名单 | [Actions.lua:6](../overload/mod/mcp_bridge/Actions.lua#L6) 无 T_RUSH；[Actions.lua:122](../overload/mod/mcp_bridge/Actions.lua#L122) 拒绝表外技能 | 直接阻塞点 |
| 可用能力 | [Actions.lua:77](../overload/mod/mcp_bridge/Actions.lua#L77) 只列出已学习且审核通过的白名单技能；[Actions.lua:87](../overload/mod/mcp_bridge/Actions.lua#L87) 将未适配技能标记 supported=false | 学会 Rush 不等于可以调用 Rush；成长与释放的能力来源已经分开 |
| 执行时目标 | [Runtime.lua:276](../overload/mod/mcp_bridge/Runtime.lua#L276) 再检查 revision/ready；[Runtime.lua:289](../overload/mod/mcp_bridge/Runtime.lua#L289) 解析 actor ID | 使用执行当时的当前角色对象，不信任客户端坐标或旧引用 |
| 感知解析 | [Observer.lua:20](../overload/mod/mcp_bridge/Observer.lua#L20) ID 包含 session/level；[Observer.lua:23](../overload/mod/mcp_bridge/Observer.lua#L23) 使用地图占位、seens、原生感知缓存；[Observer.lua:60](../overload/mod/mcp_bridge/Observer.lua#L60) 再检查当前 level 实体 | 当前不可感知、死亡、离层、旧 ID 拒绝；可感知不代表在 Rush 范围内或道路畅通 |
| 原生技能调用 | [Actions.lua:170](../overload/mod/mcp_bridge/Actions.lua#L170) 拒绝失效/自身 actor 目标；[Actions.lua:193](../overload/mod/mcp_bridge/Actions.lua#L193) 调用 `p:useTalent(id,nil,nil,nil,target,nil,true)` | 只供应目标并关闭通用“使用技能确认”，未传 force_level、ignore_cd、ignore_energy 或 no_talent_fail |
| 玩家回合边界 | [Player.lua:4](../superload/mod/class/Player.lua#L4) 原生 act 返回后通知 ready；[Game.lua:9](../superload/mod/class/Game.lua#L9) 包围完整 tick；[Runtime.lua:253](../overload/mod/mcp_bridge/Runtime.lua#L253) 等下一完整 tick 与玩家稳定边界 | 正常 Rush 可继续使用现有结算机制，不需要自行推进敌人或扣回合 |

标准定义见 [combat-techniques.lua:23](../../../../game/modules/tome/data/talents/techniques/combat-techniques.lua#L23)，默认 activated 与 T_RUSH ID 生成见 [ActorTalents.lua:65](../../../../game/engines/default/engine/interface/ActorTalents.lua#L65)。其 range/stamina/hate/cooldown 是函数，不影响当前 activated actor 审核通过，但当前通用审核也没有验证这些函数。

### 最小接口无需变化

以下是**后续接入后的请求示例**，当前版本仍会返回 unsupported_talent：

```json
{
  "session_id": "<当前会话>",
  "control_token": "<当前控制租约>",
  "command_id": "rush-001",
  "expected_revision": 123,
  "action": {
    "type": "use_talent",
    "talent_id": "T_RUSH",
    "target_id": "<observe 返回的当前可感知 actor ID>"
  },
  "wait_ms": 2000,
  "include_map": false
}
```

使用 `tome.inspect(kind="talent", id="T_RUSH")` 确认 supported 与冷却；调用后检查命令 status、energy_spent 和新快照。外层 ToolReply.ok=true 只表示请求成功处理，不代表 Rush 命中或命令 status=completed。超时后继续查询原 command_id，不能生成新 ID 重放。

## 3. force_target 是输入替换，不是完整目标语义

### 3.1 Rush 不需要进入交互式选目标协程

[ActorTalents.lua:152](../../../../game/engines/default/engine/interface/ActorTalents.lua#L152) 的 prepareUse 在 activated 技能 action 期间临时替换 `who.getTarget`，返回 force_target 的当前 x/y/对象；action 返回或抛错后 finishUse 恢复。标准 Rush 的 `getTargetLimited` 最终调用这个 getTarget，因此在普通 actor 目标场景无需打开 targeting UI。

但替换具有三个不能泛化的性质：

1. **绕过 Player:getTarget 的规则。** [原生 Player.lua:870](../../../../game/modules/tome/class/Player.lua#L870) 对 encased_in_ice/encased 强制自目标，并处理即时近战按键；整个方法被替换后这些逻辑不会运行。原生 Frozen 同时设置 encased_in_ice 和 never_move（[physical.lua:761](../../../../game/modules/tome/data/timed_effects/physical.lua#L761)），正常 Rush 的 on_pre_use 会先因 never_move 拒绝；因此不能据此宣称标准 Frozen 已出现 Rush 越权。仍应给目标替换建立明确限制，并覆盖其他 encased 或原生/附加层的目标改写。
2. **同一替换回答所有 getTarget 调用。** 多次选目标会反复收到同一个对象。Phase Door 在高等级先选择被传送角色、再选择目的地（[conveyance.lua:82](../../../../game/modules/tome/data/talents/spells/conveyance.lua#L82)、[conveyance.lua:108](../../../../game/modules/tome/data/talents/spells/conveyance.lua#L108)）；不能通过添加一个 actor 白名单条目让这两个输入自动等价。
3. **只适用于 activated。** prepareUse 的 force_target 分支在 `ab.mode=="activated"` 内。持续技能即使调用相同 useTalent，也没有相同的强制目标保证；必须单独审核。

P0 建议保留 Rush 的现有 actor 输入，在经过审核的标准玩家路径下执行；遇到不能保持原生目标规则的状态或方法替换，明确拒绝/交给人工。不要从客户端开放 force_target、`__no_self`、raw targeting table、typ 回调或任意 coroutine。

一种后续可研究的目标输入方式是使用原生 GameTargeting 的结构化输入入口，让 Player:getTarget 继续运行；[GameTargeting.lua:299](../../../../game/engines/default/engine/interface/GameTargeting.lua#L299) 虽有 `target.forced` 分支，但它是全局游戏状态且同样会重复供给所有请求，必须有命令归属、嵌套限制和 finally 清理，不能简单赋值后视为通用解决方案。

### 3.2 requested actor 不一定是原生 resolved actor

[ActorProject.lua:384](../../../../game/engines/default/engine/interface/ActorProject.lua#L384) 的 `getTargetLimited` **忽略 getTarget 的第三返回值**：先取 x/y，再 `canProject`，最后从裁剪后的格子重取 Map.ACTOR。`canProject` 使用目标类型的 block_path、拐角及距离规则（[ActorProject.lua:286](../../../../game/engines/default/engine/interface/ActorProject.lua#L286)）。Rush 还执行第二段 lineFOV/checkAllEntities，决定目标旁的候选落点（[combat-techniques.lua:52](../../../../game/modules/tome/data/talents/techniques/combat-techniques.lua#L52)）。

该版本 Rush 的 target 字段写作 `stop__block`，不能据此认为不阻挡：bolt 类型本身设置 `stop_block=true`，默认 actorblock=true（[Target.lua:629](../../../../game/engines/default/engine/Target.lua#L629)、[Target.lua:683](../../../../game/engines/default/engine/Target.lua#L683)）。路径计算就在标准 Rush action 内，当前版本没有可供直接调用的 `rushTarget` 帮助方法。

因此 target_id 应解释为“向该当前可感知角色的位置施放原生 Rush”，不能承诺“此 ID 一定是最终攻击对象”。对于挡路角色、范围边界、拐角以及移动回调改变位置，应保留原生结果。客户端不能用 Observer 的 terrain-only 地图预演真实 Rush 路径；那会漏掉角色、对象、地图属性和回调。

后续结果可增加 requested_target、实际玩家前后位置和 `movement_occurred`；实际目标、是否尝试攻击/命中只有在原生执行边界取得可靠证据时才填，否则 unknown。实际目标的身份仍需当前感知门控，不能借结果旁路泄露隐藏角色。规则化的“目标重定向”不是异常或必然 partial；它首先是原生施放语义。

## 4. 直接相关的可靠性缺口

### 4.1 普通技能的部分原生异常尚未统一隔离

[Actions.lua:189](../overload/mod/mcp_bridge/Actions.lua#L189) 捕获 useTalent 异常后只返回 `ok=false, code="execution_error", error=...`，没有 uncertain；[Runtime.lua:314](../overload/mod/mcp_bridge/Runtime.lua#L314) 只复制 native_message，不复制 error；[Runtime.lua:321](../overload/mod/mcp_bridge/Runtime.lua#L321) 只在 result.uncertain 时进入原生错误隔离。

原生 action 异常会记录 talent_error 并向外传播（[ActorTalents.lua:186](../../../../game/engines/default/engine/interface/ActorTalents.lua#L186)、[ActorTalents.lua:348](../../../../game/engines/default/engine/interface/ActorTalents.lua#L348)、[ActorTalents.lua:422](../../../../game/engines/default/engine/interface/ActorTalents.lua#L422)）；当 Actions 已捕获且能量仍合法时，Game.tick 外层就不会再看到同一异常。因此不能用 Game tick 守卫或成长/物品的 uncertain 支持证明普通技能已经覆盖。

Rush 在 [combat-techniques.lua:67](../../../../game/modules/tome/data/talents/techniques/combat-techniques.lua#L67) 移动后才攻击、附加效果；原生移动还执行目的格 on_move（[engine/Actor.lua:264](../../../../game/engines/default/engine/Actor.lua#L264)）。异常可能发生在位置已变、伤害已造成或部分费用已扣之后。该问题也适用于现有 Lightning/近战技能。

**P0 建议：** 对所有已进入原生 mutation 的异常统一返回有界 native_message 与 uncertain=true，复用 Runtime 撤销租约、保留失败命令及只读状态、重载后才能写入的机制；同时验证前后能量字段，不能在 pcall 外用坏能量再次抛错或回退为“没有花费”。调用前的明确参数/目标/来源拒绝继续作为确定的失败。不要通过恢复血量、位置、资源或随机数来伪装回滚。

此处主要解决现有同步 useTalent 调用期间的错误。未来若 action 已 yield，随后由 target/dialog/rest continuation 恢复时才出错，首次 Actions.pcall 已经返回；仍需 P3 的命令归属与原生终结观察，不能声称仅统一返回字段就覆盖所有异步异常。

### 4.2 原生成功不是战术效果保证

Rush 在移动尝试后、目标不再相邻或攻击未命中时仍可返回 true（[combat-techniques.lua:73](../../../../game/modules/tome/data/talents/techniques/combat-techniques.lua#L73)）；Daze 还依赖命中和目标可被 stun。`Actor:postUseTalent` 在 ret 为真后处理能量、资源及回调（[Actor.lua:6328](../../../../game/modules/tome/class/Actor.lua#L6328)、[Actor.lua:6504](../../../../game/modules/tome/class/Actor.lua#L6504)），技能冷却随后启动。

Steamroller 的目标/自身效果在命中判断前就施加（combat-techniques.lua:74），因此未命中也不保证没有效果变化。标记目标死亡后，Rush 冷却重置还被安排在 tick end（[Actor.lua:3363](../../../../game/modules/tome/class/Actor.lua#L3363)）；这进一步说明应使用稳定边界快照，不把 useTalent 刚返回时的冷却值当成最终结果。稳定边界也只表示下一决策点，不表示未来所有持续效果或飞行投射物已经结束。

建议保持已有 status 含义，并增加独立的结果证据，避免把 completed 解释为“冲到预期格且击晕指定敌人”：

- 生命周期：queued/executing/settling/completed/failed/needs_input。
- 执行判断：原生正常返回、原生拒绝、发生异常、仍存在原生 continuation；不以受击对象消失推断击杀。
- 效果证据：玩家前后位置、原生即时费用/冷却变化、可感知目标状态；命中和攻击次数未经可靠原生记录时留 unknown。

即时原生费用与最终快照差额要分开。最终资源差额还可能包含恢复、敌人攻击或其他被动效果，不能直接当成技能实际成本。异常时 partial/unknown 指执行完整性未知；普通未命中、免疫或自然重定向不应自动标成异常 partial。

### 4.3 普通原生拒绝只有泛化结果

当前 false/nil 汇总为 native_rejected，可能对应冷却、资源、睡眠、never_move、距离、路径、混乱丢回合等；其中有些失败已经消耗能量。原生 preUseTalent 也执行 AI 元数据解析、资源检查临时标记、hook、技能回调与随机失败（[Actor.lua:5742](../../../../game/modules/tome/class/Actor.lua#L5742)、[Actor.lua:5835](../../../../game/modules/tome/class/Actor.lua#L5835)、[Actor.lua:5946](../../../../game/modules/tome/class/Actor.lua#L5946)、[Actor.lua:5951](../../../../game/modules/tome/class/Actor.lua#L5951)）。

建议先增加 `stage`、有界 native_message/日志游标与 `reason_source`，直接桥接拒绝用稳定 code。更细 native reason 只在审核过的执行分支中采集；未知原因保持 native_rejected。不要为了猜失败原因再次调用 preUseTalent，也不要把 `fake=true` 当纯查询。更不能依赖中英文日志字符串解析作为协议的唯一判断依据。

## 5. 能力发现与纯读取元数据

### 5.1 从一张 ID 表演进为可审核的行为配置

当前 source audit 检查 action、可选 on_pre_use、actor target 的文件后缀，以及 mode/requires_target/no_energy/post_action 形态（[Actions.lua:63](../overload/mod/mcp_bridge/Actions.lua#L63)）。这是兼容性守卫，不是完整代码身份或安全证明：同文件的另一个函数仍可能通过，动态 range/cost/cooldown 与玩家 useTalent/getTargetLimited/canProject 等方法也未全部纳入审核。

建议逐步集中为 Registry/behavior profile：

- 执行形态：single_actor、self、coordinate、direction、sustain_state、reviewed_multistep。
- 审核项：技能定义/关键方法的经过复核来源和具体函数身份或定义位置，允许的可选回调与明确变体；部署版本的源码 manifest 可辅助定位版本差异，不能只看 source 后缀。
- 查询投影：哪些字段可直接读、哪些已复算为纯公式、哪些 unknown。
- 目标策略：是否允许自目标、队友、坐标、自然重定向、玩家特殊目标状态；未知目标类型不默认开放。
- 生命周期：同步原生动作、原生时间任务或经审核的输入 continuation；允许的结果证据与清理规则。

保留已有 supported 的执行支持含义，兼容增加 execution_supported、action_forms、readiness 和 metadata_quality。Progression 的“可学习”不能复用执行 supported；被动/持续/待审核技能依然可见且明确说明无法执行。完整技能能力可通过 inspect 按需获取，connect 保留简短已学习支持列表，避免扩大每帧快照和传输预算。

### 5.2 Rush 的范围与成本可以渐进纯化

当前 [Actions.lua:90](../overload/mod/mcp_bridge/Actions.lua#L90) 只返回静态 base_costs，函数成本是 unknown，完全没有 range。对 Rush 而言缺少这些信息会让调用者反复试错，但它们不是原生执行的前置依赖。

| 字段 | 标准 Rush 规则 | 纯读取限制 |
| --- | --- | --- |
| 范围 | `min(14, floor(combatTalentScale(t,6,10)))`，见 combat-techniques.lua:38 | 应使用有效技能等级，不是只用 raw_level；标准 scale 见 [Combat.lua:1544](../../../../game/modules/tome/class/interface/Combat.lua#L1544) |
| 有效等级 | raw 等级经加成再乘类别掌握度，见 [ActorTalents.lua:913](../../../../game/engines/default/engine/interface/ActorTalents.lua#L913) | 自定义加成可调用函数（[Actor.lua:6949](../../../../game/modules/tome/class/Actor.lua#L6949)）；发现未审核 custom filter 就 unknown，不能直接调用完整 getter |
| 基础资源 | 普通 22 stamina；Steamroller 2；切换 hate 变体为 6/1，见 combat-techniques.lua:31 | 只从审核过的属性/已学技能字段推导；不把“通常是22”写成始终最终费用 |
| 检查成本/实际成本 | stamina cost_factor 的 `check` 参数使 Adrenaline Surge 下检查值可为0，扣除阶段仍走正常因子，见 [resources.lua:66](../../../../game/modules/tome/data/resources.lua#L66) | 必须分清 eligibility_cost 与 spend_cost；fatigue 本身还调用技能 getter（[Combat.lua:1872](../../../../game/modules/tome/class/interface/Combat.lua#L1872)） |
| 冷却 | 基础函数使用 combatTalentLimit；实际 cooldown 还经减免、效果和 hook，见 [Actor.lua:6865](../../../../game/modules/tome/class/Actor.lua#L6865)、[Actor.lua:6921](../../../../game/modules/tome/class/Actor.lua#L6921) | 当前剩余冷却可读 talents_cd；新施放冷却不能仅按基础函数保证 |
| 能量 | 技能使用 weapon 速度，并经速度 getter、技能和 hook，见 [Actor.lua:6286](../../../../game/modules/tome/class/Actor.lua#L6286) | 不写死每次1000；按真实执行能量差与结算边界返回 |

不要从只读路径调用 `getTalentTarget`：它执行 target callback，并写全局 typ 或共享 t.target.talent_mode（[ActorTalents.lua:1063](../../../../game/engines/default/engine/interface/ActorTalents.lua#L1063)）。`getTalentRange` 也会直接执行 range 函数（[ActorTalents.lua:1049](../../../../game/engines/default/engine/interface/ActorTalents.lua#L1049)）。查询所用纯投影需要与原生公式做差分测试，并在观察前后验证无 RNG、getter/hook、角色/地图/技能定义写入。

## 6. 通用形态的支持边界

| 技能形态 | 当前能力 | 下一步范围与禁止泛化 |
| --- | --- | --- |
| 无目标/自身 activated | 已有 Heal、Adrenaline Surge、三类 infusion；要求无 t.target/requires_target | 保留 self profile；“对自己施放的 range=0 AoE 且有 target 定义”不自动等价 |
| 单 actor activated | 已有 Lightning、Stunning Blow、Warshout；Rush 符合请求形态 | actor 是瞄准输入，可产生 beam/cone/移动/原生重定向；不保证只影响一个对象 |
| coordinate | Python/Lua 均无 x/y action 形态 | 单独 profile 验证当前 level、边界、可知坐标策略和原生目标要求；不能把 Map.ACTOR 对象或隐藏格泄露为选项。Dimensional Step 的坐标还可变为角色互换，见 [spacetime-weaving.lua:38](../../../../game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua#L38) |
| direction | 当前仅 move 使用方向；use_talent 没有方向字段 | 单独定义相对哪个起点、是否一步、是否允许空格；Fearless Cleave 的 simple_dir_request 是选格后移动并攻击周围，见 [2h-assault.lua:82](../../../../game/modules/tome/data/talents/techniques/2h-assault.lua#L82)，不能用“附近敌人 ID”完整代替方向 |
| sustained | Actions 审核要求 activated，故明确不支持 | 审核 activate/deactivate、保留费用/互斥槽/回调；建议未来使用 desired_state，而非不带前态的 toggle，防止重连后反向切换。原生 Precise Strikes 见 [combat-techniques.lua:93](../../../../game/modules/tome/data/talents/techniques/combat-techniques.lua#L93) |
| 多次目标/物品/菜单选择 | 无输入序列协议 | 逐技能审核有意义的结构化选项；Phase Door 的角色+目的地、陷阱创建后再选发射方向（[traps.lua:2116](../../../../game/modules/tome/data/talents/cunning/traps.lua#L2116)）可能在第二问前已改变世界，不能取消时假设零副作用 |
| 异步原生时间任务 | Runtime 特别适配 rest，非任意技能异步 | Refit Golem 的 action 会创建休息并 yield（[golemancy.lua:256](../../../../game/modules/tome/data/talents/spells/golemancy.lua#L256)）；不能因已有 rest 动作就推断其整个技能已被托管 |

### needs_input 与 continuation 必须分清

原生 `GameTargeting:targetGetForPlayer` 把当前技能 coroutine 保存为 target_co 并 yield（[GameTargeting.lua:299](../../../../game/engines/default/engine/interface/GameTargeting.lua#L299)）；用户结束选目标时先清 target_co，再 resume 该 coroutine（[GameTargeting.lua:132](../../../../game/engines/default/engine/interface/GameTargeting.lua#L132)）。`talentDialog` 还会在对话 unload 时 resume 技能（[ActorTalents.lua:1261](../../../../game/engines/default/engine/interface/ActorTalents.lua#L1261)）。第一次 useTalent 返回 nil 可能只是挂起，不是最终拒绝；target_co 已清空也不是整个技能已经完成的证据。

当前 Runtime 将任意目标/对话视为 busy，并以 needs_input 终止 MCP 命令、交还控制；Python 把 needs_input 列为终态（[bridge.py:12](../server/src/tome_mcp/bridge.py#L12)）。这是**人工接管边界**，不保证原生技能已取消。stop 仅能取消未启动任务和自身已托管的 rest，不能撤回任意原生 continuation。force_target 在 action 挂起期间还可能保留临时 getTarget 覆写，直至原生 finishUse 运行。

P0 保持该人工接管语义且明确“不保证原生动作已撤销”；不要自动回答任意对话。P3 若支持远程继续，需另建 command-owned continuation：

1. 记录 actor/session/level、原始 command_id、原生 coroutine/对话身份、预期输入形态、输入序号和失效条件；不把 coroutine 地址暴露给客户端。
2. 区分 awaiting_input（仍归原命令）与 needs_input（交还人工）。新状态需能力协商，旧 Python 客户端不能误作可继续或永久轮询。
3. 每次 continuation 输入独立去重，并绑定原命令和当前输入序号；只接受经过审核的有限选项，不接受任意 Lua、按钮路径、回调名称或全套 typ。
4. 在完整原生终结边界收集最终结果。只包装 useTalent 返回、postUseTalent 返回或观察 target_co 为 nil 都不足：后面仍有冷却、post_action、回调或其他异步工作。
5. stop/断线/人工输入/保存/换层必须有逐形态的撤销或交还策略；异常清理失败进入只读隔离，不能偷偷 resume、猜答或重新发起技能。

这需要独立设计原生生命周期钩子及其兼容性测试，不属于 Rush 单目标接入的必要改造。

## 7. 分阶段实施建议与接口草案

### P0：标准 Rush 与现有技能可靠性

- 保持现有 use_talent schema，增加经过审核的 T_RUSH actor profile；保留真实 native action、路径、移动、伤害和效果代码。
- 统一普通技能原生异常为 uncertain 失败和有界消息；确保坏能量状态不逃逸该处理。
- 明确单 actor 输入只替代一次已审核的目标选择；检查特殊玩家目标状态/修改方法，描述原生自然重定向和结果限制。
- 通过下一节 Rush 必要矩阵和旧技能回归再发布。不要求先开放坐标、持续、多步输入或完整最终费用估算。

### P1：发现、纯元数据与结果证据

- 抽取 Registry 复用审核逻辑，保留 supported，兼容新增 execution_supported/action_forms。
- 为 Rush 增加经审核的范围和条件基础费用投影；完整成本无法纯算时 unknown，执行时原生检查保持权威。
- 增加请求目标、玩家前后位置、拒绝阶段和有界原生日志关联。只报告可证明的效果；新字段参与响应预算。

**未来 inspect 示例，非当前响应契约：**

```json
{
  "id": "T_RUSH",
  "supported": true,
  "execution_supported": true,
  "action_forms": [{
    "id": "rush_to_actor",
    "target_kind": "actor",
    "target_semantics": "aim_at_current_actor_position",
    "native_retargeting_possible": true,
    "lifecycle": "synchronous_native"
  }],
  "range": {"value": 6, "status": "audited", "revision": 123},
  "base_costs": {"stamina": 22},
  "costs_are_final": false,
  "readiness": {"status": "unknown", "reason": "native_checks_required"}
}
```

此处 range=6、stamina=22 只是对应标准示例状态的示意值，不是所有 Rush 等级/角色的常数。

### P2：逐形态扩展，不开放整个 targeting 系统

在新增动作版本/能力中，为某个已审核技能开放明确 action_form。例如后续坐标形态可使用 `target={kind:"position",x:10,y:12,level_instance_id:"level-2"}`，方向形态可使用 `target={kind:"direction",direction:6}`；旧 target_id 形式继续兼容，混合旧/新目标字段拒绝。每种形态独立定义可知性、距离、起点与 native actor 第三返回值语义。

持续技能先提供 `desired_state:"active"|"inactive"`，执行前核验当前状态；若已达到期望值，明确报告 unchanged，不再次切换，也不伪造一次原生施放。是否新增 action type 或增加 action_form，应以版本兼容方案确定，不能直接让所有 sustained ID 通过 activated 白名单。

### P3：经过审核的多阶段技能生命周期

再评估 `tome.continue(command_id, input_id, expected_revision, response)`。response 只能匹配当前公布的有限输入 schema；输入选项与 actor/item ID 都遵守当前会话与感知边界。最终 completion 仍绑定最初 command_id，持续记录已经发生的原生变化，不以第二问被取消推断整个技能未执行。

## 8. 待执行测试矩阵

以下均为计划；本轮没有增改测试或执行游戏。P0 应以标准真实原生链路为主，隔离故障注入单独标识，普通角色自然学习/施放记录另存为新证据。

| 范围 | 用例 | 必须验证 | 阶段 |
| --- | --- | --- | --- |
| 支持与发现 | 已学/未学 Rush、定义被替换、原生同文件错误函数 | validate/audit/capabilities/inspect 一致；未知实现拒绝，学习能力不冒充释放能力 | P0 |
| 请求边界 | 缺 target_id、旧 session/level、隐藏/死亡/离图 actor、自身、混合字段、force/ignore_cd | 进入原生前拒绝；无能量/RNG/位置变化 | P0 |
| 普通成功 | 直线与斜线、最小合法距离、武器速度变化 | 原生落点、伤害尝试、原生费用/冷却和后续玩家稳定边界；不人工扣回合 | P0 |
| 原生拒绝 | 相邻、超范围、墙、堵路、拐角、无落脚格 | 使用真实 canProject/lineFOV/map checks；保留 native false/nil 和实际花费 | P0 |
| 目标裁剪 | 请求远处 actor、路径中另一个 actor；队友/中立角色在路径中 | requested 与 resolved 可能不同；不许报告“保证命中请求目标”；无隐藏信息泄露 | P0 |
| 状态限制 | never_move、睡眠、lucid_dreamer、标准 Frozen、独立 encased/目标方法改写 | 玩家目标规则与原生 preUse 均保持；不宣称仅 force move 就可绕过所有限制 | P0 |
| 资源/冷却 | 不足 stamina、疲劳、Adrenaline Surge、Steamroller、hate 变体、冷却中 | 检查与真实扣除分开；原生回调/费用不被预测结果替代 | P0 |
| 随机失败 | 混乱、通用失败、哨兵打断等可适用状态 | false 可花能量/加冷却；不重复 preUse 或消耗第二次随机数 | P0 |
| 效果结果 | 未命中、stun免疫、移动/受击回调改变角色位置或目标状态 | completed 不等于必命中/必Daze；返回真实可证明结果 | P0 |
| 部分异常 | move 后 on_move/attack/effect/postUse/startCooldown 抛错 | uncertain=true、原始命令可查、错误限长、撤销 lease、重连不能恢复写入、无回滚/重放 | P0 |
| 能量异常 | 调用前非法字段、原生后置能量丢失/NaN | 前置明确拒绝，后置不确定隔离，不在统计差值时逃逸 | P0 |
| 去重与控制 | 排队/完成重复，同ID换目标，断线后status，stop排队与执行中，BC接管 | 每个命令最多启动一次；旧lease不能继续；已发生世界结算不撤销 | P0 |
| 原生边界 | 施放中弹对话、玩家死亡、保存/换层、延迟 onTickEnd | needs_input/terminal/scene_changed 语义准确，不遗留误报 completed | P0 |
| 旧能力回归 | Lightning、Heal、Stunning Blow、Warshout、infusion、rest、物品/成长 | 新异常统一不破坏正常拒绝/能量/确认/去重与只读接口 | P0 |
| 普通验收 | 当前普通角色自然学习后在正常地图执行 Rush，再保存重载 | 实际技能可用性、位置、资源、冷却、角色/存档完整性；记录与训练 fixture 分开 | P0 |
| 只读纯性 | 反复 observe/inspect，动态函数、未知 custom level/fatigue/cost getter 哨兵 | 零 RNG/回调/状态/共享目标表变更，未知就是unknown | P1 |
| 纯公式差分 | 多 raw等级/掌握度/加成、Steamroller/hate、疲劳/Adrenaline | 对应已审核原生公式；变体/方法修改后降级unknown；范围并非raw等级线性值 | P1 |
| 响应预算 | 多技能、长文本、引号、未知元数据 | 有界列表/截断，connect/snapshot/status不超传输预算 | P1 |
| 坐标/方向 | 空格、未知格、越界、旧层、移动起点、第三actor返回 | 每profile独立规则，不能经位置请求获取隐藏actor；旧target_id兼容 | P2 |
| 持续态 | activate/deactivate、已满足desired_state、互斥槽、保留资源与drain、false/table返回 | 无意外toggle；原生激活/解除路径及费用正确 | P2 |
| 多阶段 | 首次yield、二次目标、第二问前已创建对象、人工/远程接管、取消/断线/保存 | 有归属的continuation、每输入去重、未答不resume、取消不假装零mutation | P3 |
| 异步终结 | target_co先清后resume、对话unload、原生休息回调、终结时抛错 | 不以首次return或target_co=nil判完成；错误关联原命令并隔离 | P3 |

## 9. 决策建议

近期批准的工程范围宜为：**标准 Rush actor 接入 + 通用原生异常隔离 + 清楚的目标/完成语义 + 原生回归**。之后再增加纯元数据与行为 Registry。坐标、方向、持续态和多步选择各自需要独立审核；保留默认拒绝未知回调/形态的边界，比按 requires_target 或技能 mode 一次性开放全部技能更符合当前 MCP 的可验证能力。
