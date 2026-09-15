# MCP 0.3.0 普通战役改进交付

日期：2026-09-15。依据：[原始普通战役试玩](mcp-campaign-trial-2026-09-15.md) 及同名 JSON。Bridge 与 Python stdio server 从 0.2.0 升至 **0.3.0**；Battle Companion **0.1.1**、Danger Alert **1.3.1** 保持原版本。

已打通这名原有 Cornac Berserker 的核心技能、原生恢复、进入下一层并继续行动。最终冻结源码与正式 `.teaa` 都从原试玩存档的独立副本完成实际普通战役验收；所有游戏动作经官方 MCP SDK，没有增加技能、强化角色或布置战斗场景。

## 交付产物

- 游戏 addon：[tome-mcp-bridge.teaa](../dist/tome-mcp-bridge.teaa)，13 个生产文件，无测试 probe。
- 包 SHA-256：`e88a46a8888f9a0d9ae2ddbb5642dae5010e0830b7a45c7114cf103036035a8d`；[逐文件清单](../dist/manifest.json)。正式包与冻结源码逐字节一致。
- Python 服务：[tools/tome-mcp-server](../server/README.md)，需与游戏 addon 一并更新；本工作区 `tmp/tome-mcp-venv` 已安装 0.3.0。
- [使用说明](../README.md)、[协议增量](tome-mcp-v1-contract.md)、[独立审阅](tome-mcp-campaign-review.md)、[完整验收](../VALIDATION.md)。

## 试玩反馈与处理

| 试玩问题 | 0.3.0 行为与边界 |
| --- | --- |
| 出口上移动不会换层 | 新增 `change_level`，调用经过来源审核的原生 CHANGE_LEVEL；保留出口规则、区域限制、转化箱确认、加载和保存。实际换层后返回新的 `level_instance_id` 与 `scene`，旧控制租约失效，显式 connect 后继续。原 command_id 去重仍有效。 |
| 五个初始核心技能均不支持 | 新增 Stunning Blow、Warshout 和 Healing／Regeneration／Wild 纹身原生适配。纹身支持各类第 1–6 槽，必须已学习；目标、范围、冷却、资源、状态和能量沿用原生规则。Warshout 使用可见目标确定锥形方向。 |
| 靠数百次 wait 恢复 | 新增 `rest` 原生任务，max_turns 为 1–1000，包含第一步。查询可恢复已执行回合、累计能量、结束原因；stop、控制变化和原生敌人／伤害等可中断。使用原生 restInit/restStep/restStop，保留原生额外恢复与技能回调。 |
| 大量重复快照 | observe／act／status 支持 `include_map=false`；observe 支持 `events_after` 获取玩家可见日志增量。原试玩 69.8 MB 是本地 JSONL 总记录，不作网络或 token 基准；本轮没有声称固定压缩率。 |
| 无区域、实际楼层或成长状态 | 增加 `scene`、等级、当前经验与下一阈值、可用属性／技能／通用／类别／prodigy 点数、白名单角色描述与基础属性。读取现有状态，不自动加点。 |
| 无背包与装备信息 | 增加有界物品摘要，优先已穿戴、备用装备，再列背包；未鉴定物品保留未知信息。没有运行鉴定或动态说明函数。拾取和穿戴动作留待后续。 |
| actor inspect 太少 | 可见角色增加等级／rank、类型、原始效果、速度、基础战斗字段和抗性摘要。尊重隐藏等级与当前感知；原始字段明确不等于最终战斗面板值。 |
| block_status 多数 unknown | 对经过来源检查的原生地形读取通行、可穿行和门状态；未知回调继续保守返回 unknown。此值仅描述地形，不能保证没有角色、陷阱或移动交互。 |
| 半径 8／12 的合并语义不清 | 地图返回半径、窗口边界和合并说明：同一 level_instance_id 仅替换覆盖格子，保留窗口外历史；换层分开存图。省略地图不代表空地图。 |
| T_ATTACK 显示不支持但 attack 可用 | 能力中明确 `supported=true`、`action_adapter="attack"`，调用方使用 attack 动作。 |
| needs_input 没有对话内容 | 增加有界的现存可见标题／文字／按钮摘要，不执行 UI 回调、不自动答题。部分动态绘制内容可能没有可读取字段。 |
| 第二个客户端提示含糊 | 连接结束错误增加“可能已有客户端占用”的诊断提示，同时保留其他连接故障的可能性；仍为单 TCP 客户端。 |

`play-00688 target_not_adjacent` 保持正确拒绝。原试玩未升到等级 2；本轮也未将它记录为已复现或已修复的升级弹窗故障。上述新能力主要补足原有接口范围，不能统称为旧版回归。

## 最终普通战役证据

源存档为 `tmp/tome-mcp-validation/sessions/campaign-play-01/home/.t-engine/4.0/tome/save/`。执行器只复制到全新隔离 HOME，保留 `mcp-play-birth` 和原试玩 BC／Danger Alert 安装包。`cheat=false`，没有战斗 probe 或 fixture。原存档全部 6 个文件在前后哈希不变，原试玩证据保留。

| 冻结候选 | 检查 | MCP 动作 | 可见原生日志击杀 | 日志增量 |
| --- | ---: | ---: | ---: | ---: |
| [源码 campaign-source-final-01](../../../../tmp/tome-mcp-validation/sessions/campaign-source-final-01/result.json) | 40/40 | 202 | 4 | 74，无缺口 |
| [正式包 campaign-package-final-01](../../../../tmp/tome-mcp-validation/sessions/campaign-package-final-01/result.json) | 36/36 | 69 | 4 | 79，无缺口 |

两轮实际进入 **Trollmire 2**，检查旧租约失效、重复命令不重复换层、显式重新 connect 后完成普通 wait。随后只利用 MCP 已知地形与当前可见敌人探索、战斗；分别最低观察到 HP 124.26／125.60。五个原有技能均实际成功：`T_STUNNING_BLOW_ASSAULT`、`T_WARSHOUT_BERSERKER`、`T_INFUSION:_HEALING_3`、`T_INFUSION:_REGENERATION_1`、`T_INFUSION:_WILD_2`，核对了相应原生冷却、资源、能量或效果。

两轮都精确执行 `max_turns=5` 的 **5 步**休息并验证去重；敌人在场时原生休息 **0 步**停止。源码运行另记录休息 **4 步和 1 步**后遇敌中断。完整恢复任务在源码中执行 21／15／15／15 步，在包中执行 21／17 步，均以 `native_complete` 结束。各次自然战斗不同，动作数量不作效率对比。

最终均为 **HP 132/132、stamina 100/100、五技能冷却 0**，无当前可见敌人，BC 为 idle/actions=0，未发现 Lua 错误。Wild 已验证原生瞬发防御效果；这些普通战役证据没有证明特定缴械效果的解除。

可审查的 [普通战役汇总 JSON](../validation/2026-09-15-campaign/campaign-summary.json) 保留源存档、各运行结果和原始调用文件的 SHA-256。每个 session 的 `input.json`、`candidate.zip`、`campaign-mcp.jsonl`、`decisions.jsonl`、`visible-log-events.jsonl`、`player-visible-combat.log`、`game.log` 保存完整复现资料。两轮 Python 源码和验收驱动均冻结且哈希相同。复现命令见 [普通战役执行器说明](../tests/campaign/README.md)。

## 回归与审阅

- MCP Lua **457 项**和 Python **17 个测试**通过；新增纯读取、物品鉴定边界、地图／对话、日志分页、技能入口、原生休息生命周期和换层保存队列测试。
- 正式 MCP 包原有完整真实引擎回归 **92/92** 通过：[结果](../../../../tmp/tome-mcp-validation/sessions/campaign-mcp-release-01/result.json)。覆盖三个旧技能、行动、命令去重、只读 RNG／感知／预检纯度、真实键盘接管、保存与副本重载。
- 三插件正式包互操作 **35/35** 通过：[结果](../../../../tmp/tome-mcp-validation/sessions/campaign-control-release-01/companion-result.json)。旁观不接管，显式控制暂停 BC，保存／重载不恢复任何自动动作。
- BC 单元 **486 项**、Danger Alert 单元 **1540 项**通过。
- 独立审阅无未解决阻断项。完整压力响应 **213,756 字节**，低于 262,144 字节限制；大列表和文本省略带截断标记。休息清理的重入／异常和后台保存刚排队的边界均已补充检查。

这些原有原生回归使用独立测试角色和场景；普通战役真实性由上一节的原存档副本提供。隔离任务测试调用真实 PlayerRest／CHANGE_LEVEL 入口并使用小型调度和 Dialog 替身，主要检查异常、中断和生命周期边界，不能代替完整原生场景。摘要见 [regressions.json](../validation/2026-09-15-campaign/regressions.json)。

## 仍有限制与后续范围

1. 普通加点、拾取／装备、任意对话选项、复杂目标和其他技能尚未自动化。遇到原生确认返回 `needs_input`，交还游戏界面；人为完成对话可能继续其原生回调，stop 不保证撤回该回调。
2. 日志是已显示文本的有限变化记录，最多 256 项、16 项／页、单条 512 字节；append/update/remove/reset 不等于结构化模拟事件，`observed_world_tick` 为采集时点。需要处理 gap、has_more 和截断。
3. 只读字段强调玩家知情与纯度；未知动态地形／物品／特殊视觉保守省略，基础战斗字段不能直接作为最终命中或伤害公式。
4. 休息遇敌以 `native_stopped` 加原生消息表示，不依赖英文文本生成专门原因码。断线／控制变化不恢复已中断任务；异常清理失败会标记 uncertain 并阻止后续自动步进。
5. 验收覆盖 ToME 1.7.6 的 Linux／Xvfb，以及 Trollmire 2 的普通战斗恢复闭环；尚未覆盖整场战役、所有职业、Windows/macOS 或所有第三方插件。

2026-09-15 已通过 Paseo 向原试玩／自动战斗开发会话 `c5c1aed2-49b7-4d8c-92b2-143184e27c6c` 发送完整回报，工具返回 `success=true`。回报包含本报告、确切版本和产物、普通战役证据与上述限制，供后续继续使用。
