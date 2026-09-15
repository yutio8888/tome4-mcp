# MCP 普通战役功能审阅

日期：2026-09-15。依据：普通战役试玩报告及其 JSON、起始 0.2.0 与本轮冻结 0.3.0 MCP 实现、BC 互操作和 ToME 1.7.6 源码。前六节为实现约束，第七、八节记录实现复核与结论；没有把旧测试竞技场或增强角色当成普通战役证据。

## 1. 换层必须沿用原生 CHANGE_LEVEL

`game/modules/tome/class/Game.lua:2276` 的 `setupCommands.CHANGE_LEVEL` 处理脚下出口、能量、never_move、禁止带负面效果进入 wilderness、地形 change_level_check，并向 `changeLevel` 传递楼梯参数。可在当前主游戏安全输入状态通过 `game.key:triggerVirtual('CHANGE_LEVEL')` 复用。

`Game:changeLevel`（940）可能先开启转化箱界面，真正换层在该对话卸载回调中发生。直接调用 `changeLevelReal` 会跳过这些检查；原生函数返回 nil 也不代表失败。`changeLevelReal`（1047）还会主动执行旧地图的 onTickEnd 回调、弹出加载等待框并强制重绘，在末尾发出 `Game:changeLevel` hook（1442）。

实现约束：

- 执行前固定请求的角色、旧区域、旧 level 实例；只接受当前脚下出口，不接受任意目的区域参数。
- 此命令造成的 scene_changed/加载框可正常撤销控制租约，但不能据此把已完成的换层标为 failed。
- 收到完成信号后仍等 tick 完整退出、加载/保存完成和新地图稳定。返回新旧 level_instance_id、区域/楼层和 control=manual，下一动作需显式重新获取控制。
- 原生拒绝且地图未变应报告原生拒绝；转化箱等输入界面应报告 needs_input；不能自动代答，也不重试换层。
- 人工稍后关闭转化箱可能触发原命令留下的原生换层回调。需要清楚区分“交还输入”与“换层已取消”；stop 无法保证撤回该原生回调。

## 2. 休息任务应运行原生休息生命周期

入口：`engine/interface/PlayerRest.lua:restInit/restStop`，`mod/class/Player.lua:onRestStart/onRestStop/restCheck/restStep`。REST 快捷键只调用 `player:restInit()`。

不能用逐次 wait 冒充原生 rest：`Player:restCheck` 在休息计数达到 15 后会执行原生额外生命和资源恢复；onRestStart/Stop 也会增减专属再生并运行技能回调。restCheck 本身有副作用，禁止从 observe/inspect 调用。

任务约束：

- 建议 `restInit(nil)` 保留原生满血/资源恢复停止逻辑，由 addon 在每个 restStep 前检查严格 max_turns。
- 原生限制用 `cnt > rest_turns`，直接传 max_turns 会多休息一步；restInit 本身还可能消耗首步能量，计数必须包含它。
- restInit 在赋值 self.resting 前就创建模态框。Runtime 需识别“本命令启动期间创建的专属休息框”，只豁免这一实例；其他对话仍中断任务。
- restStop 先 unregisterDialog，随后 on_end/onRestStop，最后清 self.resting。要防止清理回调重入，并只停止命令实际拥有的 resting 对象。
- 原生 onTakeHit、负面效果、onChat、死亡和窒息路径已调用 restStop；额外的 lease/stop/断线/换层/BC 接管必须停止后续休息。
- 停止不能冻结敌人结算；先记录停止原因，再等下一个稳定玩家边界完成命令。
- 命令 ID、已执行步数、限制和停止原因持续可查，去重覆盖整个任务。断线重连不会恢复休息；新请求必须是新决策。
- 长任务 status 不应每次返回完整地图；进行中返回进度，完成后再附快照，减少恢复期反复传输。

## 3. 只读状态扩充

| 信息 | 正确来源与限制 |
| --- | --- |
| 区域 | game.zone.name/short_name、game.level.level、level_instance_id；不要序列化整个 zone/level |
| 成长 | player.level、exp、exp_mod、unused_stats/talents/generics/talents_types/prodigies、descriptor；exp 是当前级经验，下一阈值对应 getExpChart(level+1)，不是累计总经验 |
| 背包 | player.inven、inven_def 的 slot/name/is_worn、物品 UID 与槽位；数量等价于 1+#stacked |
| 鉴定 | 直接读取 identified/auto_id 与 game.object_known_types 合并判断；未鉴定名称用 unided_name，隐藏未获知属性 |
| 可见敌人 | 沿用当前感知过滤，再增加 rank、level（尊重 hide_level_tooltip）、类型、效果和速度；不要因为 actor ID 存在就绕过感知 |
| 战斗数值 | raw 字段明确标注为基础/非最终值，或只复算经过审核的纯公式；不要把 raw combat_def 当界面最终防御 |

关键危险点：`ObjectIdentify:isIdentified`（engine/interface/ObjectIdentify.lua:48）会写 self.identified；`Object:getName`（mod/class/Object.lua:566）调用它并展开 descAttribute。一般 getName/getDesc 不适合作为只读背包接口。

`Combat:combatDefense(true)` 仍可能调用 T_TACTICAL_EXPERT.do_tact_update；combatAttack 会触发 callbackOnCombatAttack；combatArmor 会调用多个技能函数。`Actor:tooltip` 还运行感知和 hook。因此增加面板信息不能直接执行整套 tooltip。原生 `combatGetResist`（Combat.lua:2310）是可独立审核的字段公式，但需处理 force_use_resist、all 与类型叠乘、cap。

ToME 经验公式定义在 `game/modules/tome/load.lua:194`；CharacterSheet（615）使用 player.exp / player:getExpChart(player.level+1)。只有来源审核通过时才复算，否则阈值 unknown。

## 4. 游戏日志游标

权威可见文本来源为 `game.uiset.logdisplay.log`。`engine/LogDisplay.lua:call` 将文本插入索引 1，条目含 str 和 timestamp。伤害汇总和击杀通过 Game:displayDelayedLogDamage 直接调用 logdisplay，因此仅包装 game.log 会漏报。

- 消费已经形成的可见文本，禁止重新运行 Game:logVisible/logMessage 以恢复事件；前者会调用 canSee。
- 使用会话内单调序号作为 cursor。timestamp 同毫秒可以重复，不能充当唯一游标。
- 不通过改全局共享 LogDisplay metatable 来捕获消息，否则可能误采集在线聊天。可以按原生条目对象身份读取增量。
- 区分普通追加、最旧条目截断、最新条目 rollback 与整个 logdisplay 重建；声明 gap/source_reset，必要时提供撤回标记。不能把相同文字合并去重。
- 事件保留有界，返回 oldest_cursor、next_cursor 和截断状态；分页游标应停在本页最后已交付事件，避免漏掉未返回事件。
- 原生日志有延迟汇总，怪物离开当前感知列表不是击杀证明。首版优先交付可见日志文本，结构化击杀统计需额外定义依据。

## 5. 必须保留的 BC 互操作

MCP control 显式调用 BC.remoteTakeover；observe 连接不接管 BC。BC 的 boundary 同时检查 Runtime.hasControl 和 player.resting。休息任务尚未完全结算时应保持 active，防止 lease 已撤销但任务仍休息时被 BC 抢入；停止后不能自动重启任何一方。

## 6. 普通战役验收要求

使用 `campaign-play-01` 保存角色的隔离副本；保留 cheat=false、原有技能/装备/属性和出生辅助 addon。实际用官方 MCP SDK 从出口进入 Trollmire 第二层并完成后续普通动作，验证当前职业技能/纹身。恢复任务验证 max_turns、原生恢复、停止、断线和遇敌；不足条件只能报告未覆盖，不能通过增加技能或强化角色伪造普通战役证据。

## 7. 实现复核记录

### Actions 与任务生命周期

已对照真实技能定义和 KeyBind:triggerVirtual 核对 Actions：Stunning Blow、两个原生 Warshout ID、三类纹身每类 1–6 槽使用原生 useTalent；装备、资源、冷却与范围拒绝仍由原生执行路径决定。换层直接执行经过来源检查的 CHANGE_LEVEL closure，与 triggerVirtual 的底层调用等价，没有绕过 changeLevelCheck 或转化箱输入。

新增 `game/addons/tome-mcp-bridge/tests/test_tasks.lua`。它载入真实 `engine/interface/PlayerRest.lua` 的 restInit/restStop 和当前 Game.lua 的 CHANGE_LEVEL closure，用小型游戏循环与 Dialog 替身验证任务边界；不声称替代普通战役、完整恢复公式、原生调度或磁盘存档验收。

任务边界 **62 项复核通过**，覆盖：专属休息框、包含首步的 max_turns=1/3、累计能量、命令去重、停止/断线/保存不冻结后续世界结算、未结算任务阻止另一个控制器接管、0 步原生恢复完成、受伤中止、替换的手动休息不被清理、换层后旧 lease 失效、新地图稳定后完成、原生输入保留、排队和执行中的保存，以及自然/上限/双重原生异常下的终态与只读状态。

审阅发现并推动修正：

1. **原生自然 restStop 的重入。** 只在 Runtime 主动 stopRest 设置 guard 不足；原生 onRestStop 回调中出现对话时也会触发 revoke。当前薄包装覆盖整个原生 restStop 调用，真实 PlayerRest 隔离用例确认只执行一次清理。
2. **清理错误使任务永远 settling。** native tick error 后的 restStop 也可能抛错，先前会阻止 finish。当前实现记录 uncertain、终态失败，并以原生 resting 对象身份禁止该失败对象继续自动步进，不假装原生效果已经清理。自然停止/达到上限时发生同类错误也清除 lease，新增用例已通过。
3. **保存管道刚排队但尚未启动。** SavefilePipe.push 先入 pipe、注册 coroutine，直到 doThread 首次运行才将 saving 设为 true；Game.tick 在 onTickEnd 前运行 coroutine。换层发生于 onTickEnd 时，仅检查 saving 会提前完成。当前 nativePhase 同时检查 pipe、saving 与 waiton；queued pipe 与 running save 两阶段断言已通过。

### Observer、日志与报文预算

完成 `Observer.lua`、`ObservationDetails.lua`、`Journal.lua` 与 Runtime 接线审阅。没有从观察路径调用鉴定、物品命名、战斗 getter、tooltip、开门或按钮回调。经验阈值复算与真实 ActorLevel/ToME 公式一致；敌人详细资料仍需通过当前感知校验，隐藏等级维持 unknown；未鉴定装备不泄露真实名称或属性。原始效果回合、速度和战斗字段均标明 raw/非最终值。

修复背包占满 32 项后装备列表消失的问题：优先当前装备，其次备用装备，最后背包，inventory/equipment 分别声明截断。描述符和未用 prodigy 点数使用固定白名单；敌人详细资料包含 type/subtype。对话仅投影已存储的可见文字，排除 hidden/hide/不可见部件，最上层对话优先保留。

Journal 使用会话内单调序号，保留 256 项，16 项/页，默认最近 12 项，每条最多 512 字节并去除不可显示控制字符。append/update/remove/reset 描述日志变化，remove 明示包含回滚、清空或历史淘汰，不声称游戏动作撤销。分页 cursor 停在本页最后交付事件；重复文字不会因文本相同而被合并。

最初完整压力报文达到 383,013 字节，超过 262,144 字节传输限制。最终实现将观察主体限制在 192 KiB 内，在压力下缩短地图名称、裁减列表并显式标记截断，为日志和协议字段保留余量；BC 摘要和原生停止消息也限长。冻结版本中，含 250 字符引号技能 ID、大量引号文字和满页日志的独立压力报文为 **213,756 字节**，控制字符日志版本为 **197,372 字节**，均低于传输限制。裁减只影响输出，不修改原生对象、地图记忆或日志游标。

## 8. 最终独立结论

**冻结 0.3.0 源码审阅通过，当前没有未解决的阻断项。** 独立运行 `tests/run.sh` 全部通过，共 **457 项**：JSON 62、Transport 28、Actions 159、Journal 29、Observer 72、Tasks 62、Runtime 45。Observer 自带压力快照为 192,969 字节；另有上节完整协议/日志压力检查。

同时只读核对 `campaign-source-01/result.json`：普通战役源码运行记录为 30 项检查、72 次 MCP 动作，passed=true、cheat=false、gameplay_fixture=false、original_save_unchanged=true、lua_error=false。该记录支持正常战役进展，但本独立结论不替代正式冻结安装包的原生复验；安装包及真实回合、存档证据由本轮最终验收记录负责。

范围仍明确：任意对话需人工处理；动态未适配技能和未知回调不承诺执行；战斗面板只提供明确标注的原始字段；日志是已显示日志的有界变化记录。异常清理失败会提供 uncertain 失败结果并禁止后续自动步骤，不伪装原生效果已恢复。
