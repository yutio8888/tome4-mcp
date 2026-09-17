# ToME MCP 首版独立审阅

> **历史资料，非规范（Historical / non-normative）。** 本文是当时的审阅记录。其中“observe/inspect 不得调用
> `preUseTalent`、技能 action、一般 tooltip、project 或 Chat.generateList；把 RNG、preUseTalent、canSee
> 设置为失败哨兵”等约束已被 `AGENTS.md` 与 `docs/tome-mcp-auto-combat-plugin-design.md` §8.3 **取代**：
> 当前只读边界仅为**不提交动作、不泄露玩家未知信息**，实时 getter/builder（含动态 tooltip/目标函数）
> 可调用（允许 RNG/读副作用）。保留原文仅作历史证据。

日期：2026-09-15。审阅依据：当前原生 Lua/C 源码、架构草案与本地 Battle Companion；以下是实现约束，不代表 MCP 已通过原生验收。

## P0：首版必须满足

### 1. 动作完成必须晚于执行回调，且确认玩家重新可行动

`engine/GameEnergyBased.lua:tick` 先调用 `engine.Game.tick`（其中执行 `onTickEnd`），随后才运行实体能量循环；`tickLevel` 还会在玩家暂停时保留 `last_iteration`。`mod/class/Game.lua:tick` 在能量循环之后处理延迟日志。

- 动作可在 `onTickEnd` 执行，但结果应在后续完整 Game tick / display 后评估。
- 耗能动作要观察新的 `Player:act` 就绪信号，再核对暂停、能量、UI、保存和切图状态。
- 瞬发动作可能不触发新的 Player act；需要独立完成路径，至少越过当前回调及其延迟任务。
- 不以 `game.turn` 变化作为唯一完成条件，也不为等待网络强行设置 `game.paused`。

依据：`game/engines/default/engine/GameEnergyBased.lua:tick/tickLevel`、`game/engines/default/engine/Game.lua:onTickEndExecute`、`game/modules/tome/class/Player.lua:act/useEnergy`。

### 2. 技能 false/nil 不等于无操作，__talent_running 也不能判定协程完成

`Actor:preUseTalent` 的混乱、失误、Fumble、Sentinel 路径会消耗能量后返回 false。`ActorTalents:useTalent` 在 yield 后返回 nil，并清除 `__talent_running`；目标协程／对话仍可能存在。

- 结果保留原生返回值、即时能量差、结算状态；执行失败后仍应等原生世界结算。
- 一律禁止自动重试执行失败或网络超时的动作。
- 首版只开放经过核对的技能 ID；执行时仍必须检查已学技能。原生 `useTalent` 本身不负责阻止调用未学习技能。
- `game.target.active`、`game.target_co`、模态对话出现时进入 needs_input，保留原生交互；不能再发下一条世界动作。
- 不为“取消 MCP”删除目标协程、清空 getTarget 或关闭原生对话；停止后续动作即可。

依据：`game/modules/tome/class/Actor.lua:preUseTalent`、`game/engines/default/engine/interface/ActorTalents.lua:useTalent`、`game/engines/default/engine/interface/GameTargeting.lua:targetGetForPlayer`。

### 3. observe/inspect 不能执行一般游戏回调

`Actor:canSee` 缓存未命中时可调用 RNG，写缓存并改变地图显示对象；`preUseTalent(fake=true)` 仍会解析 AI 信息并运行 hook。技能描述、成本函数也不普遍只读。

- 仅提取经过核对的字段；可见性消费既有 `can_see_cache[actor]['nil/nil']`。
- 缺失可见性结果时保守隐藏，或使用明确审核的静态规则；不得为了观察调用 canSee。
- 禁止调用 `preUseTalent`、技能 action、一般 tooltip、project 或 Chat.generateList 作为查询。
- observe 的纯度测试应把 RNG、preUseTalent、canSee 设置为失败哨兵，比较玩家能量／资源／冷却／地图与快照前后。

依据：`game/modules/tome/class/Actor.lua:canSeeNoCache/canSee/preUseTalent`；`game/addons/tome-battle-companion/overload/mod/battle_companion/Scene.lua:visible` 仅是较窄参考。

### 4. 玩家视角不能简化为 seens 格子上的全部对象

`Map:applyESP` 能将角色所在格标为 seens，却不记录 has_seens/remembers；seens 既包含视觉也包含 ESP。盲目序列化该格地形、物品和陷阱会泄漏信息。

- 将角色感知与地形记忆分开；首版可少报，不得把 ESP 看成获知格上所有内容。
- 记忆地形使用桥接曾观察的缓存；未曾保存的历史格只返回 known 标记，不从当前后台地形补全。
- inspect 必须重新执行同等感知过滤，不能只凭 UID 从 `level.entities` 返回对象。

依据：`game/engines/default/engine/Map.lua:apply/applyLite/applyExtraLite/applyESP`、`game/modules/tome/class/Actor.lua:canSeeNoCache`。

### 5. 游戏侧去重必须跨 TCP 重连保留

- 在排队前登记 command_id，重发相同请求返回现有状态；ID 相同、动作不同返回冲突。
- 查重先于 revision 拒绝，避免重发已成功动作被误报 stale。
- 容量耗尽拒绝新命令或保留 tombstone；不能删除旧结果后把同一 ID 当新命令执行。
- TCP 断开取消尚未执行的旧队列并保留取消结果，已开始动作继续原生结算。
- 读档、Game/Player/Level 更换必须使旧引用失效；读档后的新会话不得接受旧命令。
- 超时返回 unknown/pending 和 command_id，通过 status 查询；不能重新生成 ID 再试。

依据：动作与 `onTickEnd` 存在异步时间差；`engine/GameEnergyBased.lua:loaded` 明确重新分配实体 UID。

### 6. 控制权变更必须发生在原生输入处理之前

- 包装当前 `game.key.receiveKey`、`game.mouse.receiveMouse`，先撤销队列和控制租约，再调用原处理器。
- 引擎输入类在 addon 之前可能已经载入，单纯 superload KeyBind 不足以保证接入。
- held WASD、running/resting 和 automaticTalents 会在原生 display/act 里自行行动：获取控制时要拒绝这些活动状态，或明确暂停后再接管。
- 对话键鼠有自己的 handler；应通过对话注册/关闭事件失效 revision 和待执行命令，不能仅依赖 game.key。
- stop 不应把敌人结算冻结在中途。

依据：`game/addons/tome-battle-companion/overload/mod/battle_companion/Input.lua:attach`、`game/modules/tome/class/Game.lua:display/onRegisterDialog`、`game/modules/tome/class/Actor.lua:act`。

### 7. 普通攻击应走 T_ATTACK，而非直接 attackTarget

原生 `Combat:bumpInto` 通过 `useTalent(T_ATTACK, ..., target)` 发起攻击。T_ATTACK 负责 `never_attack`、投射合法性、Warden 武器切换、Double Strike 等替代攻击，并经过技能前置检查。直接调用 `attackTarget` 会漏掉这些上层规则。

首版的 `attack` 动作应复用原生 T_ATTACK；耗能未命中仍是一项已经执行的攻击。Battle Companion 的直接近战入口不能原样视为通用普通攻击接口。

依据：`game/modules/tome/class/interface/Combat.lua:bumpInto/attackTarget`、`game/modules/tome/data/talents/misc/misc.lua:T_ATTACK`。

## P1：协议和可操作性

### 8. 非阻塞 socket 仍需每帧预算和正确偏移

监听和客户端都设 `settimeout(0)`；收包、发包、解析消息数、最大消息及队列均需限额。LuaSocket 的 `send(data,start)` 返回最后发送的**绝对索引**，失败第三返回值也是该索引，下一次应从 `index+1` 继续。`receive(n)` 超时第三返回值中的半包必须保留。

JSON 不复用含 loadstring 的 Json2，拒绝非有限数、控制字符、错误 unicode surrogate、尾随垃圾与过深结构。UTF-8 字符串不可按字符数计算网络字节预算。

依据：`src/luasocket/buffer.c:buffer_meth_send/buffer_meth_receive`、`game/thirdparty/Json2.lua:decode_scanNumber/decode_scanString`。

### 9. display pump 要避免保存期间与内嵌渲染重入

`Game:display` 也可能为存档截图执行，且 `savefile_pipe.saving` 会改变 tick 行为。pump 只接收/发送与排队；执行器再次检查 saving、creating_player、对话和切图。不要在保存对象图中放 socket、租约或协程引用。

后台或最小化是否继续 display 依平台而异，外部服务应给有限超时和“实例暂无响应”，不能无限等待或自动重试写操作。

依据：`game/modules/tome/class/Game.lua:display/tick/saveGame`、`src/main.c:call_draw/on_tick/main`。

### 10. 单动作结果与测试应包含真实世界推进

验收至少覆盖：移动一次、撞击攻击、等待触发原生 wait 回调、正常耗能技能、瞬发技能、失败但耗能、对话阻塞、手动接管、切图/读档失效、重复/半包/断线请求。原生验收记录原生资源/冷却与敌方行动计数，不能仅测试 mock 中函数被调用。

现有 Battle Companion native runner 明确禁用联网，MCP 原生测试不得直接沿用该配置。建立独立测试 home 与新角色；启用内置 LuaSocket，隔离用户存档。

依据：`game/addons/tome-battle-companion/tests/native/README.md`；该现有测试结果不能作为 MCP 链路验收。

## 实现审阅结论

审阅日期：2026-09-15。已独立审查本次新增的 `Runtime.lua`、`Observer.lua`、`Actions.lua`、`Input.lua`、Game/Player superload 和外部 Python bridge/server；JSON 与 TCP 组件由审阅代理独立实现并测试。

**当前源码层面的阻断项已清零，可以进入最终原生和打包验收。** 这是实现审阅结论；完整测试结果由独立验收报告给出，不以本文替代实际游戏验证。

| 审阅发现 | 最终处理 |
| --- | --- |
| onTickEnd 早于整次世界结算 | 执行只排队；后续完整 tick、玩家就绪序号和 UI/能量共同决定完成 |
| 普通攻击绕过 T_ATTACK | 通过原生 useTalent(T_ATTACK) 执行，保留前置失败及替代攻击 |
| false 加耗能误报攻击成功 | T_ATTACK 的 miss 本来返回 true；原生 false 报失败并继续结算 |
| 布尔 false 被 Lua and/or 丢弃 | 地形 blocked 和 native_return 使用明确赋值 |
| 普通静止敌人缺失感知缓存后消失 | 缓存优先；经原生方法来源审核的普通确定性分支使用纯字段 fallback，特殊感知仍保守处理 |
| 模态对话输入没有交还控制 | 包装主游戏和现有对话 handlers，注册时立即附加，对话关闭撤销控制 |
| 立即重连被当成第二连接拒绝 | 每帧先限额读取旧连接并处理 EOF，再接受新连接；真正活跃的第二连接仍拒绝 |
| tick 异常导致 tick_depth 永不归零 | 逐层清理深度，撤销控制；活动命令标不确定失败；读接口可用，写接口隔离到新会话；原错误重抛 |
| 错误清理再抛错遮盖原始异常 | 错误收尾使用保护调用，随后重抛最初原生错误 |
| 完成命令长期持有旧地图 | 完成时清除 player/level/control_token 引用；去重元数据保留，快照仅保留最近 16 条 |
| Lua 5.1 弱键记录经 Input callback 保留旧 Game | 元数据使用弱值，callback 使用弱 Game 引用；旧 Game 回收哨兵测试通过，已只读核对实现与测试 |

已经独立运行的组件测试：

- Lua 5.1 和 LuaJIT：JSON 62 项、TCP 28 项通过。
- 在两个 Lua 运行时，500 个随机嵌套、Unicode 与浮点 JSON fixture 的往返结果与 Python 标准 JSON 完全一致。
- TCP 用确定性 socket 测试覆盖半包、绝对发送偏移、字节与消息预算、畸形消息、立即重连、单控制连接及断线回调重入。

实现代理另报告 Runtime 30 项 focused 测试通过；已只读核对其中的嵌套 tick 异常、save/change 异常、原生攻击 false 耗能及旧 Game 回收测试。最后一项内存注意已解决，审阅文档与生产代码现已冻结；不存在尚未处理的审阅发现。

### 保留的范围与限制

- 首版仅适配移动、等待、原生普通攻击和 Lightning / Arcane Reconstruction / Adrenaline Surge。复杂技能、剧情选择、背包和自动探索不在本次范围。
- 目标选择与对话遇到未适配交互时交由玩家处理，不宣称覆盖全部协程路径。
- 玩家视角保守少报；缺失缓存的特殊感知、隐身、潜行和 concealment 不会为了补全信息进行随机判定。原生地形回调的通行性仍可为 unknown。
- 单实例、本机 TCP、显式控制租约、单动作闭环；动作历史容量 4096，满后拒绝新命令。最近 16 条以外的命令只保证可查询去重元数据。
- 超时和原生错误不承诺回滚，不保证跨进程崩溃 exactly-once；需要重连后按原 command_id 查询。
- 窗口失焦／最小化、全部 addon 组合与长期完整流程不因基础链路通过而视为已验收。
