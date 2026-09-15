# MCP 0.3.0 普通战役续玩记录

2026-09-15，从[首次试玩](mcp-campaign-trial-2026-09-15.md)留下的存档副本继续。这次自然升至 **3 级**，进入 **Trollmire 3**，遭遇 Prox the Mighty 与一名稀有施法者后撤回 **Trollmire 2**。角色存活，最终生命 **162.225/162.225**、耐力 **106/106**，已保存并正常退出。没有击杀 Boss，也没有完成整个战役。

[结束时的原生截图](mcp-campaign-continuation-0.3.0.png) · [可核验摘要 JSON](mcp-campaign-continuation-0.3.0.json)

## 本轮条件与结果

使用 [0.3.0 正式包](../dist/tome-mcp-bridge.teaa)与对应 Python 服务；正式包 SHA-256 为 `e88a46a8888f9a0d9ae2ddbb5642dae5010e0830b7a45c7114cf103036035a8d`。角色为 Normal / Roguelike 的 Cornac Berserker，沿用原有属性、装备、技能与未分配点数。只加载原存档的独立副本，没有注入敌人、物品或技能，没有修改游戏规则。存档 `cheat=false`。

所有探索、战斗、休息和换层均通过官方 MCP SDK。导航仅使用 MCP 已报告的地形与当前可见敌人；实际落点变化后重新规划。原生键盘仅用于最后截图、关闭截图通知和保存。Battle Companion 在全部动作完成快照中均为 `idle / actions=0`。

| 项目 | 实际记录 |
| --- | --- |
| MCP 动作 | 829 次，全部 completed；未记录工具错误 |
| 动作构成 | 移动 620、攻击 72、等待 56、技能 53、休息 25、换层 3 |
| 本轮新增击杀 | 38；由玩家可见原生击杀日志确认 |
| 最低观察到的生命 | 104.769；不是连续帧生命下限 |
| 自然升级 | `campaign-00132` 升至 2 级；`campaign-00728` 升至 3 级 |
| 楼层路线 | `00001`：1→2；`00615`：2→3；`00828`：3→2 |
| 原生休息 | 25 次，累计 387 步；21 次恢复完成、3 次受伤中断、1 次发现敌人中断 |
| 日志增量 | 连续 cursor 1–720，无 gap、无文本截断；552 append、168 remove |

击杀计数来自本轮 `game.log` 的 `[LOG] ... killed ...` 行，未把敌人离开视野或日志 remove 计为击杀。日志 remove 是显示历史的移除；不是死亡事件。与前次 14 次合计为这条试玩存档的 52 次击杀，本轮自身为 38 次。

## 0.3.0 在普通战斗中的表现

换层成功后出现新的 `level_instance_id`，显式重新连接后可以继续移动与战斗。最终向上一层撤退也成功，随后 `campaign-00829` 原生休息 19 步恢复至满生命、满耐力，所有已激活技能冷却归零，当前无可见敌人或负面状态。

五个初始核心技能均实际成功执行：Stunning Blow 28 次、Warshout 10 次、Regeneration 8 次、Healing 5 次、Wild 2 次。成功执行不等于每次攻击命中；例如对 Prox 的 Stunning Blow 两击和一次普通攻击均未命中。

**本轮补充了 Wild 真实解除眩晕的证据。** `campaign-00712` 之前，石巨魔的原生 Stun 使角色具有 `EFF_STUNNED`（原始 duration=2）。调用 `T_INFUSION:_WILD_2` 后，眩晕消失，出现 Infusion Saturation 与 Pain Suppression；能量消耗为 0，前后 `world_tick` 均为 17148。日志 cursor 364–370 同时记录石巨魔使用 Stun、角色被晕、使用 Wild、眩晕解除与 cured。这证明本次自然眩晕被清除，不能扩写成所有异常状态或特定缴械场景均已验证。

休息保留了原生中断行为：`00329`、`00330`、`00331` 因持续伤害各执行 1 步后停止，`00332` 随后恢复完成；`00663` 在 16 步后因发现森林巨魔停止。结束截图通知被准确报告为 `needs_input`，包含可见标题、保存路径与 Close 按钮，关闭后恢复 ready。

## Boss 接触与撤退

在第三层观察到 **7 级、rank 4、最大生命 470.125 的 Prox the Mighty**，接近后又出现 **6 级、rank 3.5 的 Forest Troll Hedge-Wizard**。Warshout 对两者施加了混乱，但短暂近战没有命中 Prox；面对两名强敌，我选择沿已探索路线撤退，并用原有治疗与再生维持生命。

撤退中的 `campaign-00792` 和 `campaign-00819` 遭到击退，实际落点与计划中的一步移动不同。MCP 返回了正确的新坐标，调用方据此重新规划，最终返回第三层入口并上楼。敌人的击退是正常游戏行为。本次撤退是战术判断，不证明 Boss 无法击败，也不是 MCP 指令故障。

日志 cursor 599 记录了稀有施法者的 Manathrust 对 Prox 造成 41 点奥术伤害；不能把 Boss 的这段生命下降计为玩家攻击成果。actor inspect 提供的基础战斗字段也不能直接当作最终伤害或命中面板。

## 继续推进最需要的接口

1. **角色加点。** 起始已余下 3 点属性、3 点职业、2 点通用技能点；两次自然升级后累计为 **9 / 5 / 4**，另有 1 点类别点。升级没有卡在弹窗，但 MCP 缺少学习、升级技能和分配属性的动作，无法正常形成后续角色构筑。下一阶段需要读取可学习项目、等级、条件、成本，再由受控动作调用原生分配流程。
2. **可见地面物品与拾取、穿戴。** 0.3.0 可以读背包与已装备物品，本轮仍使用初始 iron greatsword、iron mail armour 和 brass lantern。当前动作能力列表只有 move/wait/attack/use_talent/change_level/rest。应补充玩家可见地面物品及原生拾取、穿戴、卸下；保留未知鉴定信息、负重、装备条件和换装耗时等规则。
3. **成长相关的对话操作。** 现有摘要能解释 needs_input；后续应针对已审查的原生界面提供明确动作或选择接口。不要依赖任意 UI 回调来绕过能力边界。

这些是现有范围尚未覆盖的能力，不作为 0.3.0 回归缺陷。本轮已有技能、恢复、楼层转换、感知与日志能力正常工作；没有据此声称整场战役或其他职业已获验证。

## 保存、证据与后续复现

新存档位于 [campaign-play-v030-01/save](../../../../tmp/tome-mcp-validation/sessions/campaign-play-v030-01/home/.t-engine/4.0/tome/save/)，角色目录为 `mcp_campaign_play_01`。`desc.lua` 显示 `loadable=true`、`cheat=false`、3 级、Trollmire 2。原生日志记录 Saving done，进程退出码为 0。本轮没有重新加载这个最终存档做额外验收。

独立运行目录包含 [input.json](../../../../tmp/tome-mcp-validation/sessions/campaign-play-v030-01/input.json)、[MCP 原始调用](../../../../tmp/tome-mcp-validation/sessions/campaign-play-v030-01/campaign-mcp.jsonl)、[决策记录](../../../../tmp/tome-mcp-validation/sessions/campaign-play-v030-01/decisions.jsonl)、[可见日志增量](../../../../tmp/tome-mcp-validation/sessions/campaign-play-v030-01/visible-log-events.jsonl)、[原生可见日志](../../../../tmp/tome-mcp-validation/sessions/campaign-play-v030-01/player-visible-combat.log)、[最终完整记录](../../../../tmp/tome-mcp-validation/sessions/campaign-play-v030-01/play-summary.json)及冻结 Python 源码。新摘要列出证据与存档的 SHA-256。86,136,193 字节是本地 JSONL 文件大小，包含重复快照，不是网络流量或 token 用量。

检查确认原始试玩存档 6 个文件哈希未变，0.3.0 正式包、候选包、冻结 Python 与续玩驱动均匹配记录。原生日志中未发现 `Lua Error` 或 `stack traceback`。本轮没有改动生产实现，也没有重复运行上一轮的单元或回归验收；[此前 0.3.0 验收](tome-mcp-campaign-improvements.md)仍是独立历史结果。

以后续存档继续时，先复制到新的隔离运行目录。现有 campaign 验收执行器固定校验最初 1 级存档的哈希，不能直接把本轮目录当作兼容的 `source_session` 参数；需要明确支持本轮已记录的来源与哈希后再加载，保留两份历史证据。

2026-09-15 已通过 Paseo 将本报告、新存档位置及上述优先事项发送至原 MCP 开发会话 `31bbc9fd-4cd3-4714-afbb-b5fa198e0378`，发送工具返回 `success=true`。请求其继续实现成长与物品接口并做原生验收；此处仅记录任务已送达，不代表下一阶段开发已经完成。
