# MCP 0.6.0：剧情窗口、物品使用与恢复验收

> **历史资料，非规范（Historical / non-normative）。** 本文是 0.6.0 的交付记录。其中“生成插入点检查来源与
> 完整文件校验值……只读查询不执行物品效果和动态说明”体现的是已被 `AGENTS.md` 与
> `docs/tome-mcp-auto-combat-plugin-design.md` §8.3 **取代**的读取纯度/身份前提。当前：读取仅受两条红线
> 约束（不提交动作、不泄露玩家未知信息），当前实时的动态 getter 可调用（允许 RNG/读副作用）；
> 源摘要/身份仅作重审遥测，不是运行门槛。历史观测与哈希保留作证据。

日期：2026-09-15。针对 [0.5.0 实战反馈](mcp-campaign-continuation-0.5.0.md)，已完成实现、修复及正式包验收。Bridge 和 Python server 均为 **0.6.0**；默认仍兼容协议 v1，新能力须显式连接协议 v2。

## 交付内容

- **原生剧情与物品说明。** QuestPopup、LorePopup、ShowLore、可关闭的 simplePopup / simpleLongPopup 作为 `dialog.notice`。每次只回答实际栈顶的 Close 选项，之后检查同一命令的下一层窗口。
- **动作已生效后继续执行。** 击杀、经验、升级和拾取保持原有结果；等待说明窗口期间保留执行占用，原生回合末回调继承命令归属。重复 act / respond 不会重复攻击、发奖或拾取。
- **通用 `use_item`。** 通过原生 playerUseItem 协程、Object:use 和 playerUseObject 清理，支持物品现有的 use_power / use_simple / use_talent。原生规则决定能否使用、充能、耗能和消耗品移除；没有 Rod 专用白名单。
- **接管和加载。** 人工接管后完成原生窗口，旧命令保留 needs_input 历史状态并释放执行权。保存与重载保留角色和物品效果，建立新 session，不恢复旧命令或协程。

原生核心文件未修改。生成插入点可记录来源与文件摘要作为**重审遥测**（**v1.6：** 不再作运行期身份/摘要门槛）；未知窗口、无关闭入口或所需实时值不可得时仍需玩家处理。只读查询不提交物品效果（动作边界），当前也不通过 tooltip/动态说明方法取信息（数据模型/能力取舍，非纯度门槛）。

## 使用新版

同时更新 [游戏 addon](../dist/tome-mcp-bridge.teaa) 和 [Python server](../server/README.md)，然后：

```text
tome.connect(mode="control", protocol_version=2)
```

物品动作：

```json
{"type":"use_item","item_id":"当前背包或装备中的物品ID"}
```

出现 `awaiting_input` 时，保存当前 command_id，按 interaction 提供的类型回答。说明窗口使用：

```json
{"type":"option","option_id":"当前 Close 选项的ID"}
```

这是 tome.respond 的 answer 字段；仍须提供当前 interaction_id、唯一 response_id、控制凭据和 expected_revision。关闭后若出现下一层，使用新问题 ID。网络结果不确定时用原 command_id / response_id 查询，禁止为关闭弹窗重放原动作。完整字段见 [v2 契约](tome-mcp-v2-interactions.md)。

## 最终验收

| 验收 | 结果 |
| --- | --- |
| Lua / Python | 864 项 / 25 个测试通过 |
| v2 原生三插件专项 | 95/95 |
| v1 原生兼容回归 | 99/99 |
| 无 fixture 的自然战役奖励 | 51/51，91 次动作全部完成，8 个原生说明窗口 |
| 击杀后接管 / 拾取后接管 | 10/10、10/10 |
| 自然保存副本重载 | 5/5 |

普通存档副本原生击败 Prox，升至 5 级；任务更新、掉落说明、Rod 教程及 Hidden treasure 三层界面均通过 MCP 完成。Rod 已自然获得并通过通用入口激活，耗能与充能消耗生效，保存重载后 Recall 仍剩 39 回合。两种人工接管恢复均没有重复奖励；Battle Companion 保持 idle / actions=0。

本轮没有执行完 Rod 后续 40 回合传送，也未完成整场战役。技能连续多问由专项场景验证，不能用奖励窗口的多层关闭替代其自然实战覆盖。早期脚本失败和自然战斗死亡均保留，未计入通过结果。

**正式包：34 个生产文件**，逐字节匹配当前源码；以上六个最终原生运行使用同一 SHA-256：

```text
a3bd05bd4968c51dabc25ab8602c5c188e779bbec05f735502d743e15b17a363
```

Python 代码与验证环境安装元数据均为 0.6.0。历史三轮存档和证据的 75,740 个文件哈希全部保持不变；所有新测试使用独立副本。

详见 [验收记录](../VALIDATION.md)、[冻结结果与哈希](../validation/2026-09-15-native-ui/summary.json)、[复现说明](../tests/notices/README.md)。后续普通试玩可继续复制 0.5.0 安全存档，显式使用新版协议 v2，观察剧情 UI 和实际物品使用，并继续收集未覆盖的原生交互。

验收完成后，已按用户要求通过 Paseo 通知原试玩主对话使用 0.6.0 继续普通战役；发送成功见 [交付通知记录](../validation/2026-09-15-native-ui/paseo-handoff.json)。此记录表示通知已发送，不表示后续试玩已经完成。
