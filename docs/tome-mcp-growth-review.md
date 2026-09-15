# MCP 0.4 成长与物品操作审阅

日期：2026-09-15。依据为本地 ToME 1.7.6 原生源码、本轮 MCP 实现、隔离单元检查和已生成的原生验证记录。历史 0.3 战役审阅保持原样。

**源码交叉审阅通过，当前无未解决的阻断项。** 本轮独立执行 `game/addons/tome-mcp-bridge/tests/run.sh`，共 **790 项通过**：JSON 62、Transport 28、Actions 159、Journal 29、Observer 75、Progression 214、Items 97、Tasks 62、Runtime 64。完整普通角色成长、自然掉落及存档重载验收在本报告写入时仍由原生验收流程执行；本文不将单元替身或竞技场记录当成普通战役完成证据。

职责说明：审阅代理实现了 Items、共享物品摘要及相应测试；Progression 作者对这些文件交叉审查，未发现阻断项；其提出的前置能量类型检查建议已合入并回归。本文对 Progression、Runtime、Actions 和 Observer 接线的结论来自独立源码复核。

## 1. 成长操作保留原生分配路径

对应原生入口为 `game/modules/tome/dialogs/LevelupDialog.lua` 的 `incStat`、`learnTalent`、`learnType`、`finish`、`unload`。每个动作只分配一个点，外部请求不能传入 force、数量、回退或任意回调。

- **属性：** 原生等级上限、绝对上限、属性变更回调和点池扣除由 `LevelupDialog:incStat` 执行。查询仅复算已审核的 `ActorStats:getStat` 数值规则。
- **职业/通用技能：** 原生 `canLearnTalent` 先检查，随后 `LevelupDialog:learnTalent` 调用原生学习路径。该对话内部的 `force=true` 是已经完成原生前置检查后的原有实现，调用者不能指定。学习回调、被动应用、资源更新和最后学习历史均保留。
- **类别：** 使用原生 `learnType`，保留解锁、掌握度增加 0.2、仅能提升一次、等级限制和类别点扣除；解锁前值使用明确的 `false`。
- **结束：** 建立与原生对话一致的临时标记和备份，调用真实 `finish` 与 `unload`。持续技能刷新、新学技能冷却、`on_levelup_close`、`on_levelup_changed` 和学习历史裁剪均保留。仅替换界面展示方法，不吞掉技能回调创建的真实游戏对话。

只读成长信息限定为角色拥有且原生界面可见的树与技能。普通 Berserker 的 11 类、46 个默认可见技能使用经过来源及定义行审核的需求公式；未知或修改后的实现报告不支持/未知。观察不会执行 `canLearnTalent`、需求函数、技能 `info`、完整描述或 clone。查询的 readiness 明确为非最终判断，执行时仍运行原生检查。

交叉审阅发现并修正两项边界：

1. 原生 `LevelupDialog:generateList` 使用 `levelup_hide_unknown_catgories` 隐藏锁定树。当前 `visibleCategory` 已遵守该门控，描述与执行共用此检查。
2. 原生回调可能在部分变更后破坏能量字段。当前执行前拒绝缺失/非有限能量；执行后出现该状态报告 `progression_execution_error` 与 `uncertain=true`，不以旧能量假装成功。

独立复跑 Progression 214 项通过，包括原生属性/技能/类别操作、需求公式、需求拒绝、临时属性加成、学习后冷却、持续技能刷新、回调次数、历史裁剪、隐藏树、只读守卫和部分异常。

## 2. 物品操作保留原生库存路径

对应源码为 `game/engines/default/engine/interface/ActorInventory.lua`、`game/engines/default/engine/Object.lua`、`game/modules/tome/class/Actor.lua:doWear/doTakeoff` 与 `game/modules/tome/class/Player.lua:playerPickup`。

| MCP 动作 | 原生路径及核验 |
| --- | --- |
| pickup | 从当前可见且位于脚下的对象 ID 定位地面索引，调用 `pickupFloor`；保留拾取前/后回调、堆叠、容量限制、原生识别和新拾取标记 |
| equip | 仅从背包选择物品，调用原生 `doWear`；保留需求、默认槽/副槽选择、替换旧装备、原生效果、能量和持续技能检查 |
| unequip | 仅选择实际穿戴容器中的物品，调用原生 `doTakeoff`；保留背包容量、卸下否决、效果移除、能量和中断回调 |

原生 `doWear/doTakeoff` 成功也返回 nil，因此按同一个物品对象操作后的真实容器判断完成，不将 nil 直接当失败。原生异常不回滚或重试，报告不确定状态供 Runtime 隔离。

原生能量行为有两处容易误判，当前均按原样保留：

- 当前格只有一个地面物品，`playerPickup` 获得对象时消耗一回合；当前格有至少两个地面物品，多选回调不扣能量。原生已处理的金钱类拾取也可能返回 true 且不扣能量。
- `doTakeoff` 在 `on_cantakeoff` 否决后仍可能消耗一回合；Swift Hands 则可使成功的穿脱为零能量。结果报告原生实际能量差。

复杂转移暂不自动适配：附着 tinker、装备堆叠、特殊槽以及添加/移除否决钩子进入明确拒绝路径。原因是原生 `doWear` 先移除源对象，其转移流程不能保证这类情况的安全恢复。更换普通物品时，也检查当前穿戴物，避免隐式进入复杂旧装备转移。

Items 97 项通过。测试加载真实 ActorInventory/Object、Actor 穿脱和需求函数；四项差分用例还实际调用 `Player:playerPickup`，仅将界面选择替换为保存后调用其原生 callback，比较单/多物品与清醒/睡眠的能量、背包、地面、changed 和新拾取标记，均一致。引擎穿脱回调及 wielder 应用由真实代码运行；完整 Player 负重公式、冷却效果与磁盘存档仍以原生战役验收为准。

## 3. 地面观察和物品识别

物品摘要由 `ObservationDetails.item` 共用。未鉴定物品仅暴露未知外观、数量和位置，不暴露真实名称、类型、装备槽、需求、材质或战斗属性。原生已知类型和 auto_id 只在鉴定实现来源通过审核时参与纯读取推导；不调用会写状态的 `isIdentified`、命名、tooltip 或需求描述函数。

已鉴定物品报告固定白名单中的原始战斗字段、材质、每件负重、装备槽和有界需求，明确 `requirements_are_final=false` 与战斗数值非最终。背包/装备另报告原生转化标记，不替用户操作转化箱。

地面仅读取当前视野与感知格，不保留地面物品记忆；失明、不可见格、ESP 下未实际照明的其他角色所在格，以及隐藏物品均不泄露。远处物品堆只显示顶层与数量，脚下显示原生可选择列表。地面 ID 包含 session、level 实例、坐标和 UID；旧会话、旧层、猜测的隐藏/远处埋藏物品均拒绝。拾取还必须在当前脚下。自有物品 ID 只在当前背包/装备中解析，重复 ID 拒绝。

地面列表最多 32 项，半径最多 12，物品堆计数最多 128，均有明确截断标记。`include_map=false` 保留 ground。ground 与 inventory/equipment 一起参与 192 KiB 观察预算；Observer 压力快照为 **194,837 字节**，未超过 196,608 字节上限。成长 inspect 单独限制为 96 KiB。

## 4. Runtime 与协议接线

- 所有成长/物品动作先经过严格规范化，再生成包含完整动作 JSON 与 revision 的指纹。JSON 对象键排序，新增 stat、category_id、item_id 不会因遗漏字段而错误去重。
- 命令去重仍先于当前 lease/revision 检查；排队、完成、重连后的同命令不会再次扣点或转移物品，不同参数复用 ID 报冲突。
- 零能量成长/穿脱仍在原有队列与结算边界运行，改变 revision 后才形成完成快照。不会把一次调用返回等同于完整游戏结算。
- 不确定的部分原生变更设置 `native_error`、撤销控制租约并产生 failed 终态；保留只读观察与命令查询。重连无法重新开启写入，须新加载会话。
- 状态保留有界的 points_spent、point_pool、previous_value、new_value 与 native_message；锁定类别的 previous_value=false 不会丢失。
- `inspect(progression, player)` 仅指向当前角色；`inspect(item, id)` 全部通过 Items 的自有/当前可见解析。未增加任意脚本、按钮选择或 force 参数。

## 5. 原生证据与结论范围

独立读取了以下原生记录：

- `tmp/tome-mcp-validation/sessions/growth-candidate-readonly-01/result.json`：11 项通过，普通自然 Lv3 Cornac Berserker，cheat=false、gameplay_fixture=false、0 次动作，两个历史来源及源存档未改变，无 Lua error；成长、四个原有物品和地面检查前后角色/回合状态相同。
- `tmp/tome-mcp-validation/sessions/growth-native-source-01/result.json`：99 项通过，无 Lua error；这是一份隔离原生回归记录，包含竞技场 fixture，支持原生调用、只读与互操作回归，不证明普通战役自然成长或自然掉落。

以上足以支持当前源码进入真实成长与物品验收。正式发布结论还需与冻结安装包、普通角色实际点数分配、自然物品拾取/穿脱、保存重载及源存档完整性记录对应。当前不支持任意成长树、prodigy、洗点、铭文槽操作、特殊装备转移或自动处理任意对话；已知数值中标为 raw 的字段不能当成界面最终计算值。
