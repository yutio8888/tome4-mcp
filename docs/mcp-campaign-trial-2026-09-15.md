# MCP 普通战役试玩与开发反馈（2026-09-15）

本次实际用 MCP 操作了一名普通战役角色，从 Trollmire 第 1 层出生点走到下一层入口，击败 14 个敌人，最终以 132/132 生命保存。角色没有死亡，也没有通关；试玩停在 `(64,18)` 的 `way to the next level`，因为当前 MCP 没有进入下一层的动作。

## 环境与操作边界

- ToME 1.7.6，Maj'Eyal 战役，Normal / Roguelike，1 级 Cornac Berserker。独立新建角色 `MCP_campaign-play-01`，`cheat=false`。
- 使用正式包：MCP Bridge 0.2.0、Battle Companion 0.1.1、Danger Alert 1.3.1。正式包、运行副本和出生辅助 addon 的摘要见[证据 JSON](mcp-campaign-trial-2026-09-15.json)中的 `input`。
- MCP 不支持创建角色，因此仅用测试辅助 addon 通过正常出生流程选择种族、职业和难度，跳过出生界面；没有战斗场景 fixture，没有增加属性、装备或技能，没有分配出生时可用点数。
- 出生后的移动、攻击、等待和技能尝试均通过官方 Python MCP SDK → stdio server → 游戏 addon 完成。Battle Companion 全程保持 `idle/actions=0`。决策只使用 MCP 返回的可见状态与地图；没有读取隐藏敌人来导航。
- 游戏内 Print 截图、Escape 关闭截图提示，以及 Ctrl+S 保存使用原生键盘输入。它们发生在到达阻塞点之后；没有用键盘替代技能或换层。
- 最终原生日志出现 `Saving done.`，存档描述为 `loadable=true, cheat=false`。本次拥有的游戏进程已正常结束；没有改动用户原有存档，也没有修改生产实现。

## 实际结果

| 项目 | 结果 |
| --- | --- |
| 提交 `tome.act` | 716 次 |
| 完成的动作 | 712 次：93 次移动、25 次近战、594 次等待 |
| 受限的技能请求 | 3 次，均为 `unsupported_talent` |
| 其他未完成动作 | 1 次 `target_not_adjacent`，属于操作者提前预判敌人会靠近，接口正确拒绝 |
| 原生战斗日志确认击杀 | 14 个，包含 2 名盗贼、1 只森林巨魔、2 只狼，以及软泥、虫群、鼠和蛇；包含怪物分裂体 |
| 最低观察生命 | 49.44/132，发生在第一次盗贼战斗中 |
| 最终状态 | Trollmire (1)，1 级，出口 `(64,18)`，生命 132/132，无可见敌人 |
| 全量 MCP JSONL 记录 | 69,765,112 字节；包含请求、响应及本地记录封装，不能直接当作网络流量或模型 token 数 |

两场盗贼战斗后，分别花了 **321** 和 **266** 次普通等待恢复满血。合计 587 次等待只是恢复生命，所有回血来自正常回合结算。这一过程由外层客户端逐回合观察，并在出现敌人、阶段异常、动作失败或满血时停止。

## 已复现的问题与建议优先级

### P0：缺少进入下一层的动作，直接阻断战役推进

`play-00716` 已成功移动至 `(64,18)`；最终快照中该格的地形是 `char='>'`、`name='way to the next level'`。之后多次观察仍为同一 `level_instance_id`，没有换层。服务端动作 schema 只有 `move / wait / attack / use_talent`，不能表达原生 CHANGE_LEVEL 操作。

建议加入有明确能力声明的换层动作，通过正常游戏入口执行，并处理确认框、地图加载、`level_instance_id` 更新、控制权撤销和结果恢复。验收要从本存档的副本实际进入 Trollmire 第 2 层，再完成一次普通行动，不能只验证调用返回值。

### P0：初始职业技能与防御纹身全部不可用

本角色的眩晕打击、战吼、治疗、回复和野性纹身均被标为 `supported=false`。实际尝试如下：

| 指令 | 当时场景 | 返回 |
| --- | --- | --- |
| `play-00010`，`T_STUNNING_BLOW_ASSAULT` | 邻接白鼠时尝试眩晕打击 | `unsupported_talent` |
| `play-00034`，`T_INFUSION:_HEALING_3` | 森林巨魔战斗受伤后尝试治疗 | `unsupported_talent` |
| `play-00042`，`T_INFUSION:_WILD_2` | 被盗贼施加 3 回合 Disarmed 后尝试解控 | `unsupported_talent` |

拒绝均未消耗能量或推进世界；接口如实声明了限制。问题是适配范围尚不能支撑这个常见出生职业。第一次盗贼战斗中只能后撤等缴械消退，再使用普通攻击；恢复时只能逐回合等自然回血。

建议先补齐上述基础纹身和狂战士初始技能，保留原生冷却、资源、状态限制、目标选择与能量语义。`T_ATTACK` 当前在 talent 列表中也显示不支持，而 `attack` 动作可用；可增加 `action_adapter` 或等价说明，避免客户端把普通攻击误判为不可用。

### P1：观察数据不足以支撑战斗判断和角色成长

实际 `tome.inspect(kind='actor')` 只返回 ID、名字、位置、生命和阵营；没有等级、rank、速度、敌方状态、抗性或攻防信息。玩家快照没有等级、经验、可用属性/技能点、装备信息。也没有区域名、实际楼层、战斗事件或伤害来源。

盗贼伏击与缴械时只能看到生命下降和效果列表；击杀数量必须在试玩后从玩家可见的原生战斗日志核实，无法仅凭“敌人从 actors 列表消失”严谨判断。截图显示 1 级、经验约 51%，这些信息不在 MCP 快照中。

建议提供符合玩家知情边界的战斗事件游标、伤害/击杀/效果变化，补充区域与角色成长摘要，并扩大可见敌人的 inspect。出生加点、升级、背包、拾取和装备操作也缺少接口；本局没有升到 2 级，因此不能声称已复现“升级弹窗阻塞”，但这些是继续完整战役的功能缺口。

### P1：缺少可中断休息，产生大量重复调用

`play-00051..00371` 为连续 321 次等待；`play-00391..00656` 为连续 266 次等待。每次仍是原生单回合行为，没有加快生命恢复。建议提供有回合上限、遇敌/受伤/弹窗/控制权变化即中断的原生休息任务，返回可恢复的 command ID 和结束原因。

### P2：地图通行信息与响应大小

本局已观察到的普通草地、树、道路和出口均出现 `block_status='unknown'`，因为原生 `block_move` 是函数。导航只能结合已知地形名、字符和实际移动结果。保留未知状态是正确的，但应研究不调用有副作用回调的安全可通行性信息或原生路径预览。

显式观察请求半径为 12，而 `act` 内附快照使用默认半径 8；客户端若直接用后者替换地图，会丢掉当前响应范围外的规划上下文。建议声明响应范围与合并语义，并提供可选的紧凑响应、地图增量和事件增量。记录体积的主要代价是多次重复返回地图；这里不把客户端选择每步额外 observe 的成本全部归因于服务端。

### P2：需要人工输入时，缺少可读的对话框内容

到达出口后用 Print 留证，原生“Screenshot taken!”提示使 MCP 返回 `phase='needs_input'`，但没有对话框标题、正文或选项；只能使用 Escape 关闭。这是本局真实发生的 UI 阻塞，但由取证操作触发，不能写成正常行走自动出现的阻塞。

建议提供可见对话框的只读摘要，再按对话框类型逐步开放受控选择。避免提供任意 Lua 执行作为替代。

### 附：第二客户端连接的诊断体验

曾尝试让另一个 MCP stdio 客户端接管安全等待；在原客户端仍连接时，新的 `tome.connect` 返回 `bridge_disconnected` 与 `uncertain=true`，未提交游戏动作。原客户端显式重新连接后继续正常游戏。单连接设计可以保留，建议返回更明确的占用/连接限制说明。本次没有重复复现，因此不将其认定为新的控制权回归。

## 证据与复现入口

- [结构化证据及摘要](mcp-campaign-trial-2026-09-15.json)：失败请求、全部近战记录、首次/最终快照、等待区间、包摘要和原始文件 SHA-256；不含控制凭证。
- [出口截图](mcp-campaign-trial-2026-09-15.png)：原生游戏截图，显示 Trollmire (1)、1 级、132/132 生命。
- [完整 MCP 调用记录](../../../../tmp/tome-mcp-validation/sessions/campaign-play-01/play-mcp.jsonl)、[决策记录](../../../../tmp/tome-mcp-validation/sessions/campaign-play-01/decisions.jsonl)、[玩家可见战斗日志摘录](../../../../tmp/tome-mcp-validation/sessions/campaign-play-01/player-visible-combat.log)。完整调用记录只用于本地调试，内含已失效的会话控制凭证。
- [动作 schema](../../../../tmp/tome-mcp-validation/sessions/campaign-play-01/action-schema.json)、[最终会话摘要](../../../../tmp/tome-mcp-validation/sessions/campaign-play-01/play-summary.json)、[出生及加载输入](../../../../tmp/tome-mcp-validation/sessions/campaign-play-01/input.json)。
- [保存的角色描述](../../../../tmp/tome-mcp-validation/sessions/campaign-play-01/home/.t-engine/4.0/tome/save/mcp_campaign_play_01/desc.lua)与同目录 `game.teag`。重新测试应复制该存档到另一个隔离 HOME，并保留出生辅助 addon；不要覆盖原存档。
- [试玩驱动](../../../../tmp/mcp-play-support/play.py)通过官方 MCP SDK 操作；出生辅助 addon 位于相邻的 `tome-mcp-play-birth` 目录。安全等待最终通过原连接逐个提交 `wait`，旁边的 `rest.py` 是未能连接、未执行动作的辅助尝试，不能当作本局实际回血驱动。

开发完成后，应保持现有 MCP 幂等、revision、控制租约、只读观察和 Battle Companion 互操作约束。继续运行既有回归，并以普通角色和真实换层补充验收；这些反馈不是允许绕过原生战斗规则或读取隐藏状态。

## Paseo 交接

已在本局结束、保存和证据核对后，通过 Paseo 发送至原 MCP 开发 agent：`31bbc9fd-4cd3-4714-afbb-b5fa198e0378`。发送工具确认 `success=true`，采用后台任务并开启完成通知。任务要求实际完善上述功能、完成回归和普通战役验证；这里确认的是交接成功，不代表改进已经实现。
