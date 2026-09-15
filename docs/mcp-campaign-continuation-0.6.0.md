# ToME MCP 0.6.0：普通战役续玩与世界地图观测问题

2026-09-15。使用正式 Bridge / Python 0.6.0、显式 protocol 2，从本人上轮 **5 级 Trollmire 3 `(9,5)`** 存档的独立副本继续。

本轮成功通过 MCP 关闭新发现神器的 LorePopup，拾取战利品，并使用 Rod of Recall 完整传送到世界地图。随后确认一个阻碍继续导航的问题：**游戏画面显示周围地形，MCP 却把包括脚下在内的 625 个格子全部报告为未知。** 已在世界地图 Trollmire 入口 `(28,13)` 满生命、满体力保存并结束本轮。整场战役仍未完成。

![原生游戏截图：世界地图显示了附近草地、森林及建筑；角色保持 5 级、218/218 生命、112/112 体力](mcp-campaign-continuation-0.6.0.png)

## 来源与运行隔离

- **直接来源**：[0.5.0 续玩报告](mcp-campaign-continuation-0.5.0.md)及其 [JSON](mcp-campaign-continuation-0.5.0.json)，会话 `campaign-play-v050-01`。本次不是从早期 Lv3 重打 Prox，也没有使用开发者专项场景的奖励存档。
- **新运行目录**：`tmp/tome-mcp-validation/sessions/campaign-play-v060-02`。本次独立运行脚本在已发布来源登记中加入 0.5.0 的 Lv5 记录，验证来源链、六个存档文件、支持 addon 和引擎哈希；`input.json` 明确记载 `source_record = campaign-play-v050-01`。
- 启动后逐项核对等级、位置、生命、体力、经验、属性、点数、效果、装备和背包，与上轮发布的结束状态一致；证据为 `load-verification.json`。
- 正式 `.teaa` SHA-256：`a3bd05bd4968c51dabc25ab8602c5c188e779bbec05f735502d743e15b17a363`。实际运行包、正式包及 34 个生产文件逐字节一致。
- 本次 Python 源码冻结在 `mcp-server-src`，加载路径与哈希已记录；源码和 venv 安装元数据均为 **0.6.0**，MCP SDK 2.2.0。
- Normal / Roguelike 普通战役，`cheat = false`，没有 gameplay fixture、临时赋予物品或技能、改属性、改经验或隐藏地图查询。Battle Companion 全程观测为 idle / actions 0。
- 结束后核对旧三份报告自身、其中共 75 项证据引用及三组共 18 个存档文件，全部一致；另核对本次启动前登记的 27 项 0.6.0 交付证据，全部一致。没有覆盖旧证据或开发者本轮验收结果。

最初启动受沙箱的本地 socket 限制，留下未启动游戏的 `campaign-play-v060-01` 目录；重复使用该名称被运行器的目录保护拒绝。获准使用本地 socket 后，实际游戏使用新目录 `campaign-play-v060-02`。这些启动环境情况没有计作 MCP 游戏动作失败。

## 新能力的实际覆盖

| 命令 | 实际操作 | 结果 |
|---|---|---|
| `play060-00001` | 从 `(9,5)` 走到上轮遗留的稀有怪掉落 `(10,4)` | 原生鉴定出 Serpent's Glare，出现 `dialog.notice / LorePopup`；角色已经移动，执行保持占用 |
| 同一命令的 `play060-answer-00001` | 回答 `interaction-1` 的当前 Close 选项 | receipt applied，原命令 completed，execution_released=true；无需 Escape，没有重放移动 |
| `play060-00002`、`00003` | 拾取 Serpent's Glare 和 horrifying mossy mindstar | 两件自然掉落进入背包；原生耗能分别为 0、1000 |
| `play060-00004` | 通用 `use_item` 使用已有 Rod of Recall | completed，耗能 1000；出现 Recalling 39，物品 power 从 400 变为 199 |
| `play060-00005` 至 `00043` | 在已清理区域原地等待，每步检查场景、角色和敌人 | Recall 的原始 duration 从 38 减到 0；没有受到伤害或遭遇新敌人 |
| `play060-00044` | 再等待一步，让原生效果执行到期回调 | 实际传送至 World of Eyal `(28,13)`，Recall 效果消失，原生日志确认被传送离开 |

最后一次 wait 的命令结果是 **`failed / scene_changed`**，并带有 `native_return = true`、`energy_spent = 1000`、`execution_released = true`。实际传送已经成功，不能把这一状态解释为 Rod 没有生效或重放使用。随后显式重连 protocol 2，角色在世界地图恢复 ready / remote。

这次只自然遇到 **一个 LorePopup、一个原生回答**。没有重新触发上轮已完成的 Prox 奖励，也没有在本轮覆盖 QuestPopup、simplePopup、多层说明窗口或同一技能连续多问；开发者已有专项及普通奖励验收的数量不计入本报告。

## 新发现：世界地图全部未知

召回后重新连接并观测，场景正确为 `wilderness / World of Eyal`，角色坐标和资源正确，但半径 12 的 25×25 地图窗口：

```json
{
  "map_cells": 625,
  "known_cells": 0,
  "visible_cells": 0,
  "player_tile": {"x": 28, "y": 13, "char": "?", "known": false, "visible": false}
}
```

`rows` 只保留表示角色的 `@`，其余全部为 `?`；脚下格子的 `char` 本身仍是 `?`。原生游戏截图显示附近草地、森林、雪林和建筑。没有使用截图中的建筑身份推断隐藏任务或目的地。

为排除传送后暂未刷新视野，本轮仅做两个诊断移动：`play060-00045` 根据原生画面可见的相邻草地向西一步至 `(27,13)`，`play060-00046` 沿刚走过的位置向东返回 `(28,13)`。动作均 completed，原生位置实际改变，但每次重新观测仍是 **625 格全部 unknown / invisible**。本轮后续没有依据未知的 MCP 地图盲目规划城镇或地牢路线。

这两次诊断移动的方向参考了玩家实际可见截图，而非 MCP 地形字段；动作执行仍通过 MCP。这个例外已单独记录，不能据此声称本轮所有导航决策都由 MCP 地图独立支持。

源码中的路径与现象吻合：

- [Observer.lua](../overload/mod/mcp_bridge/Observer.lua) 第 112 行要求同时存在 `map.seens` 和 `map.infovs` 才认为地形可见。
- [Player.lua](../../../../game/modules/tome/class/Player.lua) 第 550–561 行的 `playerFOV()` 先清理 FOV；世界地图分支通过 `computeFOV(... applyLite ..., true, true, true)` 更新视野，随后直接返回。
- [ActorFOV.lua](../../../../game/engines/default/engine/interface/ActorFOV.lua) 的 `no_store` 分支只调用所给 apply 回调。
- [Map.lua](../../../../game/engines/default/engine/Map.lua) 的 `applyLite` 写入 seens、has_seens 和 remembers，没有写入 infovs；普通 `apply` 路径才写入 infovs。

因此当前使用普通地牢 FOV 条件的观察逻辑漏掉了世界地图的原生可见地形。上述源码副本已冻结在本次会话的 `diagnostic-source`，避免后续修复后丢失定位依据。

建议按世界地图的真实原生感知路径补齐读取，并保留普通地牢、ESP、失明及隐藏信息边界。不能简单全局移除 infovs 条件，或把整张世界地图标成已知。应验证：正常可见地形和入口可读、视野外未知内容不泄露、移动与重新连接后的地图一致、地牢感知规则不退化。

精确证据：`world-map-issue.json`、`world-map-after-move-observation.json`、`world-map-observation.png`、完整 `campaign-mcp.jsonl`。前一张现场对照图为 Xvfb 根窗口抓取，边缘有窗口偏移造成的裁切；本报告主图是游戏自身的完整原生截图。

## 数量、存档与范围

| 项目 | 本轮结果 |
|---|---|
| MCP 动作 | 46 个唯一命令：3 move、2 pickup、1 use_item、40 wait |
| 动作结果 | 45 completed；1 failed / scene_changed，对应已经发生的 Recall 传送 |
| 原生交互回答 | 1 次，关闭真实 LorePopup，applied |
| 工具调用 | 151 次；无工具错误、无 Lua 错误栈 |
| 可见日志 | 17 条连续唯一 cursor，无 gap |
| 生命与成长 | 始终 217.75/217.75；本轮没有战斗击杀或升级，仍为 5 级 |
| 游戏 UI 人工关闭 | 0 次；未将诊断截图的窗口算入能力覆盖 |
| 结束状态 | World of Eyal `(28,13)`，生命 217.75/217.75、体力 112/112，效果空，无待处理原生调用 |

结束时用原生 Print 保存截图，Escape 关闭截图提示；随后 `tome.stop` 释放控制，原生 Ctrl+S 保存。截图和保存按键与游戏 UI 能力覆盖分开记录。原生 game/world 保存校验通过，日志出现 `Saving done.`；驱动退出码 0，隔离游戏进程已退出。`desc.lua` 标记 5 级、World of Eyal、loadable=true、cheat=false。**结束存档未再次启动读档测试**；本轮启动时对上轮 Lv5 存档的加载验证另有记录。

新存档：`tmp/tome-mcp-validation/sessions/campaign-play-v060-02/home/.t-engine/4.0/tome/save`。后续应从这个世界地图存档的独立副本继续，明确保留来源和哈希。

[结构化报告](mcp-campaign-continuation-0.6.0.json)包含命令结果、来源校验、交互、最终存档 SHA-256 和证据清单。原始 JSONL 为 6,477,604 字节，含重复快照，不代表网络或模型 token 消耗。

本轮没有修改生产实现。按用户要求，将世界地图观测问题及正向实战结果通过 Paseo 反馈给原 MCP 开发 agent；实际投递回执见配套 JSON 的 `handoff`。
