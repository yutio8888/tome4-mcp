# MCP 0.4.0：角色成长与物品操作

日期：2026-09-15。Bridge 与 Python server 均为 **0.4.0**；组合使用 Battle Companion **0.1.1** 和 Danger Alert **1.3.1**。依据为 [0.3.0 续玩反馈](mcp-campaign-continuation-0.3.0.md) 及同名 JSON、截图。

已完成技能树读取、四类点数的原生分配，以及可见地面物品、拾取、穿戴和卸下接口。冻结源码与正式安装包分别从自然等级 3 角色的独立副本完成实际加点、自然物品换装、保存及重载验收；两份历史存档与原试玩证据均保留。

## 产物

- 游戏 addon：[tome-mcp-bridge.teaa](../dist/tome-mcp-bridge.teaa)，15 个生产文件，未包含测试 probe。
- SHA-256：`ff627dd0a9c686b27da034e86db0a5b3bc3ce075e1feeb7858aa1dc16e2c9a74`；[逐文件清单](../dist/manifest.json)。
- [Python 服务](../server/README.md) 需一起更新；工作区 `tmp/tome-mcp-venv` 的运行版本及安装元数据已核对为 0.4.0，官方 SDK 保持 2.2.0。
- [使用说明](../README.md)、[协议增量](tome-mcp-v1-contract.md)、[交叉审阅](tome-mcp-growth-review.md)、[验收总览](../VALIDATION.md)。

## 新接口与实际规则

| 接口 | 行为 |
| --- | --- |
| `inspect(kind="progression", id="player")` | 当前角色可见技能树、已学原始等级、下一等级条件、点数成本、类别解锁及掌握度。标准 Berserker 的 11 类树经过审核；各项 `supported` 与 `readiness` 表示当前适配范围和可用性。 |
| `spend_stat {stat}` | 六项属性之一增加 1 点，使用属性点；遵循原生等级上限、属性上限及回调。 |
| `learn_talent {talent_id}` | 学习或升级 1 级，按技能使用职业或通用点；保留原生需求、被动效果、学习后冷却和关闭成长界面时的回调。 |
| `learn_category {category_id}` | 花费 1 类别点解锁已有锁定树，或将已解锁树基础掌握度提高 0.2；同树只允许强化一次。 |
| `observe` 的 `ground.items`；`inspect(kind="item", id=...)` | 当前视野内的地面物品及自有物品详情。远处物品堆只显示顶层及数量，脚下显示可选择列表；未鉴定属性保持未知。 |
| `pickup {item_id}` | 仅拾取脚下的当前可见物品；沿用原生拾取、堆叠、容量、鉴定和拾取回调。 |
| `equip {item_id}` / `unequip {item_id}` | 从背包穿戴，或把当前装备卸回背包；原生入口决定槽位、替换装备、需求、负重、耗时和回调。 |

动作对象还须包含 `type`，并通过原有 `tome.act` 携带 session、控制 token、expected_revision 和唯一 command_id。每次成长动作直接提交一个点；不接受数量、force、任意槽位、Lua 或 UI callback。学习支持与主动释放支持相互独立，例如 Rush 可学习，但本版尚无其主动释放适配。

成长查询不运行 `canLearnTalent`、技能需求函数、动态说明或 clone；物品查询不运行鉴定、命名或 tooltip 方法。需求通过已审核的原生规则和现存字段读取，未知或修改后的实现明确返回未知/不支持，执行时重新进行原生检查。地面读取受当前视野、感知、失明及隐藏条件约束；不提供未见世界物品列表。

成长沿用 `LevelupDialog` 的 `incStat` / `learnTalent` / `learnType` / `finish` / `unload`。物品沿用 `pickupFloor`、`doWear`、`doTakeoff`。原生单件普通拾取耗一回合，多件选择分支不额外耗能；穿脱也可能因原生技能或否决条件出现不同耗时，以 `energy_spent` 为准。

控制租约、去重、只读、stop、手动接管和 `needs_input` 语义继续生效。完整动作参数均进入去重指纹；重发同命令不重复扣点或转移物品。部分原生变更后异常会报告 `uncertain`、撤销租约并阻止该会话继续写入，保留读取和查询；重新 connect 不解除这种隔离，需重新加载游戏。

## 普通角色的最终原生证据

两轮从 `campaign-play-v030-01` 的原存档复制到全新隔离 HOME。进入时是 Trollmire 2 的 Lv3 Cornac Berserker，9 属性、5 职业、4 通用、1 类别点，`cheat=false`、无 gameplay fixture。保留原存档所需的出生辅助和 BC／Danger addon；没有注入技能、属性、物品、敌人或恢复。

| 最终候选 | 检查 | 唯一 MCP 动作请求 | 类别点分支 |
| --- | ---: | ---: | --- |
| [源码 growth-source-final-01](../../../../tmp/tome-mcp-validation/sessions/growth-source-final-01/result.json) | **91/91** | **76** | 解锁 `cunning/dirty` |
| [正式包 growth-package-final-01](../../../../tmp/tome-mcp-validation/sessions/growth-package-final-01/result.json) | **92/92** | **73** | `technique/2hweapon-assault` 掌握度 1.3 → 1.5 |

请求计数包含用于验证非法输入、条件和点数不足的失败命令，不代表所有请求都应成功。两轮分别使用同一原存档的独立副本，不在同一角色上花费两次原有类别点。

实际分配结果：

- 力量 +5 至 **20**，体质 +4 至 **17**；原生最大生命增加到 **178.225**。
- Stunning Blow、Warshout 各升至原始等级 **3**，新学 Rush **1**；验证新学技能冷却及升级已有技能的冷却行为。
- Heavy Armour Training 升至 **2**，新学 Vitality 并升至 **3**。
- 四类可用点池全部降至 **0**；耗尽后的分配拒绝，前提不足和未知 ID 拒绝，重复命令不再次扣点。

两轮通过玩家可见信息发现自然铁质巨锤（iron greatmaul），验证远处拾取拒绝，再走到脚下拾取，替换初始双手剑、卸下和重新穿戴；初始剑留在背包。每次成功物品操作均核对实际对象去向和原生能量，并验证重复命令不重复转移。首次未知摘要不暴露隐藏属性，后续按原生鉴定行为显示已知详情。

最后用真实 Ctrl+S 保存，并加载该轮新存档的副本。属性、技能、类别、剩余点数及装备状态保留；保存的第一份副本未被重载改写。新会话拒绝旧 session；BC 全程 idle/actions=0，无 Lua Error 或 stack traceback。所有成长、战斗、移动与物品操作使用官方 MCP SDK，原生按键仅用于保存。

保存比较保留原始前后快照，离散点数和技能等级严格相等；只允许浮点序列化舍入误差（绝对 1e-9、相对 1e-12）。开发候选曾因驱动在预期拒绝后使用旧 revision，以及直接比较 `12.379999999999999` 与 `12.38` 而中止；修正的是验收驱动，最终两轮使用同一冻结驱动通过。

来源执行器已显式支持两份发表记录及继承关系：完整核对每份存档的 6 个文件，拒绝缺失、多余、篡改或错误绑定的来源。两个历史 session 的 12 个存档文件以及原试玩/续玩报告列出的全部证据均复核一致。详见 [成长验收汇总](../validation/2026-09-15-growth/growth-summary.json) 和 [复现说明](../tests/growth/README.md)。

各最终 session 保留 input/candidate、官方 MCP JSONL、决策与可见日志、`growth-before/after.json`、`natural-item.json`、`saved-state.json`、`reloaded-state.json` 和原生运行/重载日志。

## 回归与边界

| 验证 | 结果 |
| --- | --- |
| MCP Lua | **790 项通过**：62 JSON + 28 Transport + 159 Actions + 29 Journal + 75 Observer + 214 Progression + 97 Items + 62 Tasks + 64 Runtime |
| Python MCP | **19 个测试通过**，含官方 SDK stdio 和严格 schema |
| 成长验收驱动 | **16 个测试通过**：11 来源保护 + 5 存档比较 |
| [正式包完整原生回归](../../../../tmp/tome-mcp-validation/sessions/growth-native-package-final-01/result.json) | **99/99**，包含新增成长/物品查询的 RNG、感知、预检、动态说明与鉴定纯度守卫 |
| [三插件正式包互操作](../../../../tmp/tome-mcp-validation/sessions/growth-control-package-final-01/companion-result.json) | **35/35**，旁观、控制交接、键盘接管、去重、保存与重载 |

单元日志与冻结文件复核见 [回归摘要](../validation/2026-09-15-growth/regressions.json)。交叉审阅无未解决阻断项。上述 99/35 项采用隔离测试角色和场景；多物品零能量拾取、Swift Hands、否决/异常回调等特殊分支主要由原生入口单元与差分测试覆盖，不将它们算成普通战役中自然触发的情形。

剩余范围：

1. 成长执行限定审核过的标准 Berserker 类别；不支持任意职业树、传奇点、洗点、铭文槽扩展或特殊进化。可学习技能不一定已有主动释放适配。
2. 普通装备转移已支持；附着 tinker、装备堆叠、特殊槽或复杂添加/移除钩子保守拒绝。转化箱操作、物品使用、买卖、丢弃和任意对话仍未适配。
3. 地面列表最多 32 项、半径最多 12、堆计数最多 128；完整观察预算 192 KiB，成长检查 96 KiB，省略带截断标记。已鉴定 combat/需求中的 raw 字段不等于最终面板计算值。
4. 验收环境为 ToME 1.7.6、Linux/LuaJIT、Xvfb 和软件 OpenGL；未验证全部职业、完整战役、Windows/macOS 或所有第三方 addon。

0.3.0 续玩中的 Wild 实际解除 Stun 是已有功能的新增正向证据，不是本版新增净化修复，也不构成缴械净化证据。本轮完成接口与验收，未修改战斗平衡或宣称已击败 Boss/通关。

已按此前授权，通过 Paseo 向原试玩会话 `c5c1aed2-49b7-4d8c-92b2-143184e27c6c` 发送本阶段的版本、产物、证据及限制，工具返回 `success=true`。
