# ToME MCP 0.5.0 普通战役续玩记录

2026-09-15。正式 Bridge 0.5.0 + Python 服务 0.5.0，显式 protocol 2，ToME 1.7.6。

本轮从历史 3 级存档的独立副本继续游戏，击败 **Prox the Mighty** 和稀有 **Forest Troll Hedge-Wizard**，升至 5 级，在 Trollmire 3 满血满体力保存。自然学习的 Rush 和 Fearless Cleave 均已通过原生目标交互用于实际战斗。普通剧情和物品说明界面仍造成 4 次人工接管，共用 8 次原生 Escape 关闭。

这是一段实际战役续玩；没有完成整个 Trollmire、Hidden treasure 或整场战役，也没有进入 Trollmire 4 挑战 Bill。

![本轮结束时的原生游戏截图：Trollmire 3，5 级，218/218 生命、112/112 体力](mcp-campaign-continuation-0.5.0.png)

## 运行来源与证据

- 来源：[0.3.0 续玩记录](mcp-campaign-continuation-0.3.0.md)中的原始 3 级 Trollmire 2 存档。新会话为 `tmp/tome-mcp-validation/sessions/campaign-play-v050-01`，拥有独立 HOME、运行目录和存档。
- 正式包：`game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa`；SHA-256 `8e9bf95bc39761cdca28f19ee6a6ea8eabc51dc5bb2603a821585cf6dfa5ec1c`。开局使用该包，结束后再次核对运行包、正式包及 28 个生产文件。
- Python 使用 `tmp/tome-mcp-venv/bin/python`，`PYTHONPATH` 指向本轮冻结的新版源码副本 `mcp-server-src`；4 个运行源码文件哈希有记录。既有 venv 安装元数据仍标为 0.4.0，实际加载源码的版本为 0.5.0；本轮按交付说明使用新版源码，未重装环境。
- 继续使用历史存档的 Battle Companion、Danger Alert 和仅用于原始建角/加载流程的辅助 addon。没有 gameplay fixture、interaction probe、临时赋予技能、改经验、改属性或生成装备；`cheat = false`。地图与作战决策来自 MCP 的玩家可见观测。
- 两份历史报告自身、报告引用的 37 项文件哈希及两组共 12 个存档文件哈希，结束后全部一致；没有覆盖旧记录。
- [结构化证据](mcp-campaign-continuation-0.5.0.json)包含来源、逐命令摘录、原生交互、UI 接管、存档哈希及文件清单。原始 `campaign-mcp.jsonl` 保留 459 次工具调用，凭据已脱敏；`visible-log-events.jsonl` 和 `game.log` 保留可见日志及原生保存证据。

## 实际游戏经过

起点为 Trollmire 2 `(64,36)`，3 级，生命 162.225/162.225、体力 106/106，尚有 9 属性、5 职业、4 通用和 1 系别点。本轮通过成长动作投入这些点数：学习 Rush、提高 Stunning Blow 与 Warshout、提高 Heavy Armour Training、学习 Vitality，并把双手武器攻击系精通从 1.3 提高到 1.5。

在 Trollmire 2 绕树引出狐狸后，Rush 原生询问目标；回答后角色从 `(60,32)` 冲到 `(60,34)`，击杀 `(60,35)` 的狐狸。随后击杀鼠和森林巨魔，拾取自然掉落的 iron greatmaul 并装备，返回入口进入 Trollmire 3。

本轮再次遭遇上次撤退时未击败的 Prox。Warshout 的原生目标回答成功，使首领混乱；Rush 冲近首领后攻击落空，后续使用 Stunning Blow、治疗、回复和普攻完成击杀。`play050-00111` 的最后一击产生原生击杀日志及连续两次升级，角色从 3 级升至 5 级。最低观测生命为 **101.00085**；这是观测样本最小值，不是每个原生内部步骤的生命下界。

使用新获得的成长点数后，基础力量 24、体质 19；学习 Fearless Cleave、Precise Strikes 和 Berserker Rage，提高 Combat Accuracy。拾取 Prox 的幸运脚、Silk Current、Rod of Recall 等自然奖励，并装备幸运脚。拾取纸条触发 Hidden treasure 任务。

开启两项持续技能继续探索，遇到自然生成的稀有 Forest Troll Hedge-Wizard。Fearless Cleave 通过 `target.direction` 回答东北方向，原生攻击造成 51 点伤害。敌人占据目标格，角色留在原位；本例证明方向输入及攻击成功，不能据此声称实际前进一步。随后使用 Wild 清除 Burning、治疗、Stunning Blow 和普攻击杀该敌人。

战后残留燃烧使第一次休息在 1 回合后以 `damaged` 停止。关闭两项持续技能后再次休息，恢复到满生命、满体力，所有冷却归零，异常效果为空，周围没有可见敌人。新掉落的物品仍留在 `(10,4)`，没有为取完战利品继续延长本轮。

## v2 原生交互覆盖

所有 `use_talent` 请求均不预填 `target_id`。遇到 `awaiting_input` 后保留同一 `command_id`，按当前 `interaction_id`、`revision` 提交唯一 `response_id`，没有重新发起技能。

| 命令 | 自然技能与场景 | 原生问题 | 回答与结果 |
|---|---|---|---|
| `play050-00028` | 新学 Rush，攻击狐狸 | `interaction-1`，`target.grid` | actor 回答；`completed`，消耗 1000 energy，冲近并击杀 |
| `play050-00069` | Warshout，攻击 Prox | `interaction-2`，`target.grid` | actor 回答；`completed`，原生混乱生效 |
| `play050-00070` | Rush，接近 Prox | `interaction-3`，`target.grid` | actor 回答；`completed`，移动成功、原生命中判定落空 |
| `play050-00150` | 新学 Fearless Cleave，攻击稀有施法者 | `interaction-4`，`target.direction` | `direction: 9`；`completed`，造成原生伤害 |

4 次回答全部为 `response_receipt.state = applied`，原调用结束后均为 `execution_released = true`。本轮持续技能的显式 `enabled: true/false` 也均成功；开启后体力上限由 112 降为 62，关闭后恢复。

Precise Strikes 启用时及后续攻击的 `energy_spent = 1111.111111111111` 与其原生减速一致；关闭时为 1000，Berserker Rage 开关为瞬时 0。没有把这些耗能差异、Rush 的一次落空或燃烧打断休息误报为 MCP 故障。

**本轮所有原生问题的 `sequence` 都是 1。** 同一次技能连续多问、确认选项、分页、物品选择、第二问取消、网络不确定恢复，以及挂起调用保存/重载，没有在这段普通游戏中自然发生。开发者此前的专项验收提供了这些能力的另一类证据，本报告不把它们计入本轮实际覆盖。

## 尚需接管的普通 UI

下表四个命令均返回 `needs_input / unsupported_interaction` 且 **`execution_released = true`**。原生操作已有副作用，不能因该状态重放攻击、移动或拾取。每次只用原生 Escape 关闭当前 UI，随后显式重连 protocol 2 并重新观测。

| 命令及触发条件 | 未覆盖界面 | 已发生的原生结果 | 本轮处理 |
|---|---|---|---|
| `play050-00111`：击杀 Prox 的普攻 | `QuestPopup`：Of trolls and damp caves 更新 | 击杀、经验、升级均已完成；耗能 1000 | Escape 1 次 |
| `play050-00123`：向东走上首领战利品 | 3 个 `ShowLore`：Rod of Recall、Silk Current、幸运脚 | 已移动并触发鉴定；宝石自动进入背包；返回耗能 0、tick 不变 | Escape 3 次 |
| `play050-00126`：拾取 Rod of Recall | `simplePopup`：Rod of Recall 使用说明，含 Close 按钮 | 物品已进入背包；耗能 0 | Escape 1 次 |
| `play050-00129`：拾取 tattered paper scrap | Hidden treasure `QuestPopup`、任务说明 `simplePopup`、纸条 `ShowLore` | 新任务已接受，纸条按原生逻辑处理；耗能 0 | Escape 3 次 |

第一次任务提示只呈现三个文本组件，看起来像通知，但源码中的 `QuestPopup` 确实是等待 EXIT/ACCEPT 的原生界面，不能按“被错误识别为模态的被动通知”归因。`play050-00123` 的零耗能移动是本次返回值和坐标变化的实测记录；本轮未做原生对照，不据此认定耗能错误。

接管后再次查询 `play050-00111`，其历史记录仍是 `needs_input`、`execution_released = true`。状态记录保留曾发生的接管结果；UI 已关闭及当前可继续状态由新的观测确认。

截图：[任务更新界面](mcp-campaign-continuation-0.5.0-quest.png)、[战利品 lore 界面](mcp-campaign-continuation-0.5.0-loot-lore.png)。两张弹窗图来自隔离 Xvfb 根窗口，窗口偏移使右侧部分画面被裁切；最终角色图来自游戏自身 Print 截图，未做内容编辑。

建议优先补齐这些常见说明界面的原生关闭交互，支持层叠窗口逐个处理，并继续保留已发生副作用、执行是否释放以及防重复执行的语义。应根据真实原生类和回调实现，避免用文本匹配或任意界面执行代替。

另一个自然暴露的后续需求是**物品使用**：本轮已获得 Rod of Recall，但当前动作能力没有对象激活入口。这里记录的是能力缺口，没有尝试不存在的动作，也没有把它记为运行失败。

## 数量与结束状态

| 项目 | 本轮结果 |
|---|---|
| 动作请求 | 161 个唯一 command ID；157 completed，4 次已释放执行的 UI 接管 |
| 非动作原生回答 | 4 次 `tome.respond`，均应用成功 |
| 成长 | 15 次属性、13 次技能、1 次系别投入；结尾剩余点数为 0 |
| 原生击杀日志 | 5 只：Fox、Giant brown mouse、Forest troll、Prox、Forest Troll Hedge-Wizard |
| 休息 | 8 次，共 117 原生回合；7 次 native_complete，1 次 damaged |
| 可见日志事件 | 265 条连续、唯一 cursor；无 gap，无文本截断 |
| 工具错误 / Lua 错误栈 | 0 / 0；4 次预期 UI 接管单列，不计作完成 |
| Battle Companion | 全程观测 actions 0、idle；没有参与代打 |
| 最后玩家状态 | Trollmire 3 `(9,5)`，5 级，经验 210.38/254，生命 217.75/217.75，体力 112/112 |
| 最后调用状态 | 无挂起原生交互；关闭持续技能，冷却 0、效果空、phase ready |

截图时额外使用 Print 和 Escape，结束时通过 `tome.stop` 释放控制，再用原生 Ctrl+S 保存。这些诊断/保存输入与游戏过程的 8 次 UI 接管分别记录，不能把本轮称为完全不需人工输入的战役。

存档位于 `tmp/tome-mcp-validation/sessions/campaign-play-v050-01/home/.t-engine/4.0/tome/save`。`desc.lua` 为 5 级、Trollmire 3、`loadable = true`、`cheat = false`；原生日志确认 game/world 保存校验通过及 `Saving done.`，随后结束隔离运行进程。驱动退出码 0。**本轮结束后未另行重启验证读档**。

数据整理从 `campaign-mcp.jsonl` 的最后一次真实结果取各命令最终字段。交互驱动内部字典合并可能保留早先的 `interaction` 字段，因此报告把问题历史与最终结果分开；不能据内部残留字段认定原生调用仍在等待。

本轮没有修改生产实现。新增的运行记录、截图、报告和整理脚本保留在各自路径；局部 JSONL 为 13,266,266 字节，包含重复快照，不代表实际网络流量或模型 token 用量。

## 开发反馈

按用户要求，本轮结束后通过 Paseo 将普通 UI 接管和物品激活缺口反馈给原 MCP 开发 agent；实际投递回执见配套 JSON 的 `handoff` 字段。
