# ToME MCP v1：实现契约与验收边界

> **已废弃（2026-09-15）**：本仓库已在测试阶段移除协议 v1/v2，仅保留协议 3。本文仅作历史参考，字段与行为以 [v3 契约](tome-mcp-v3-talent-query.md) 和 [API 字段](tome-mcp-api-fields.md) 为准。


设计日期：2026-09-15，更新至 addon / server 0.4.0。适用 ToME 1.7.6；假定游戏联网可用。内部协议仍为 v1。本文保留首版设计主体，下列扩展更新其范围；实际结果见 addon 验收文档。

## 0.4.0 扩展约定

- 新动作 `spend_stat{stat}`、`learn_talent{talent_id}`、`learn_category{category_id}` 每次提交一个点，复用已审核的原生 LevelupDialog 分配、完成与清理方法；不开放任意 UI 回调或洗点。类别可解锁或按原生限制强化掌握系数。结果保留 `points_spent`、`point_pool`、`previous_value`、`new_value`，新技能冷却与原生回调照常生效。
- `inspect(kind="progression",id="player")` 返回当前角色已具备的可见树、原始等级、成本和条件；受支持的学习路径以 `supported` 为准，`readiness` 为 available／blocked／unknown。查询不运行技能动态说明、要求函数、原生学习预检或角色复制；它不是保证动作成功的最终预检。
- 新动作 `pickup{item_id}`、`equip{item_id}`、`unequip{item_id}` 使用当前物品身份、原生拾取／穿脱流程、条件、容量、负重、耗时与回调。没有强制标志、任意槽位或方法名。复杂转移和附件流程保守拒绝，原生交互仍返回 `needs_input`。
- `snapshot.ground` 描述当前可见地面物品；远处物品堆只暴露顶层及数量，脚下提供有限拾取列表。拾取仅限脚下。地面 ID 绑定 session／level／坐标，库存 ID 绑定 session；`inspect(kind="item",id=...)` 只检查当前可见或本人拥有的物品。读取不鉴定物品，省略地图时仍可读取地面物品。
- 去重指纹覆盖规范化动作的全部字段及请求版本。新动作沿用单命令队列、租约、手动接管、stop 和读档规则；不重复分配点数或转移物品。原生回调部分失败保留 `uncertain`、终态和已知消耗，隔离写入直到重新加载，不声称回滚成功。

## 0.3.0 扩展约定

工具 schema 和完整用法以 [README](../README.md) 为准。

- 保留 0.2.0 的 `connect(mode="observe" / "control")` 语义及 Battle Companion 互操作。
- 新动作 `change_level` 调用原生 CHANGE_LEVEL。地图加载及后台保存达到稳定边界后，返回 `completed / level_changed` 与新场景；控制租约撤销，下一动作显式 connect。原生对话保留并返回 `needs_input`；不自动选择。相同 command_id 的查询或重放不会重复执行。
- 新动作 `rest` 接受 `max_turns`（1–1000、默认 1000）。原生 restInit/Step/Stop 执行恢复；严格上限包含首步，原生敌人、伤害、效果、外部对话及控制撤销会中断。结果包含 `turns_executed`、`max_turns`、累计 `energy_spent`、`stop_reason` 和可选 `native_message`。中断后只查询结果，不自动恢复；下一次休息须明确提交新命令。
- 技能增加 Stunning Blow、Warshout、Healing/Regeneration/Wild 纹身第 1–6 槽。Warshout 用可见角色确定锥形方向。能力列表只列当前已学习且通过来源与数据检查的技能；`T_ATTACK.action_adapter="attack"` 指向普通攻击动作。
- 快照增加 `scene`、成长和装备摘要、可见对话内容；可见 actor inspect 增加等级、rank、状态、速度和非最终的基础攻防。未知物品不会被观察过程鉴定。
- observe / act / status 接受 `include_map=false`，只省略响应地图。地图明确 radius/window/merge_scope，客户端按场景和窗口合并历史观察。
- observe 的 `events_after` 使用 session 内可见日志游标；事件最多缓存 256 项，每页 16 项，每条文本 512 字节。`gap` / `has_more` 指明丢失与翻页；日志 remove/reset 不表示游戏回滚。
- 观察响应有界，省略内容通过 `*_truncated` 标明。原生异常时失败可能带 `uncertain`，读操作可继续，写操作隔离到新游戏 session；失败的原生休息清理不会继续自动步进。

## 组成与首版范围

- 游戏内独立 addon `tome-mcp-bridge`，Lua 5.1，监听 `127.0.0.1:17646`，非阻塞 TCP。
- 游戏外 Python MCP server，stdio。MCP 的协议协商交给官方 SDK，游戏内部协议独立为 `v:1`。官方 Python SDK 支持 stdio；具体依赖版本由实现锁定，不以文档发布日期推断 SDK 主版本。[官方 SDK 文档](https://py.sdk.modelcontextprotocol.io/)
- 工具：`tome.connect`、`tome.observe`、`tome.inspect`、`tome.act`、`tome.status`、`tome.stop`。
- 动作：八方向移动、等待、相邻普通攻击，以及原生未被覆盖的 `T_LIGHTNING`、`T_HEAL`、`T_ADRENALINE_SURGE`。仅允许角色已学习的技能。
- 复杂对话或目标选择返回 `needs_input`，由玩家处理。背包、升级、楼梯、探索、剧情选择和其他技能暂不执行。
- 配置：`config.settings.tome_mcp_bridge = {enabled=true, port=17646, token='本机共享凭据'}`。`enabled` 缺省为 true；缺少 token 时记录说明且不启动监听。外部服务配置相同 token。

## 内部 TCP 协议

UTF-8 JSON，每条一行；不得接受 Lua 代码、任意方法名、NaN 或无穷值。监听、accept、receive、send 均不得阻塞；接收半包、多包及部分发送由 transport 缓冲。单客户端、消息大小与每帧处理量有界。

```json
{"v":1,"id":"request-1","op":"observe","args":{"session_id":"session-1","radius":8}}
{"v":1,"id":"request-1","ok":true,"result":{"session_id":"session-1","revision":12,"phase":"ready"}}
{"v":1,"id":"request-1","ok":false,"error":{"code":"stale_revision","message":"Observe the current state before acting."}}
```

`id` 是一次网络请求的字符串标识，`command_id` 是一次游戏动作的字符串标识。两者不能混用。

| op | args | result |
| --- | --- | --- |
| connect | `{token}` | `{session_id,control_token,revision,mode,protocol_version,capabilities,snapshot}` |
| connect_observer | `{token}` | 同 connect，另有 `mode:'observe'`，`control_token:null`；不取得控制权 |
| observe | `{session_id,radius?}` | 当前 snapshot；radius 默认 8，允许 1–12 |
| inspect | `{session_id,kind:'actor'或'talent',id}` | 当前可见角色或技能的摘要；不执行动态说明函数 |
| act | `{session_id,control_token,command_id,expected_revision,action}` | command record；可立即返回 queued |
| status | `{session_id,command_id}` | command record |
| stop | `{session_id,control_token}` | `{stopped:true,snapshot}` |

动作结构：

```json
{"type":"move","direction":6}
{"type":"wait"}
{"type":"attack","target_id":"session-1:level-1:actor-42"}
{"type":"use_talent","talent_id":"T_LIGHTNING","target_id":"session-1:level-1:actor-42"}
{"type":"use_talent","talent_id":"T_ADRENALINE_SURGE"}
```

方向使用数字键盘：7/8/9 为左上/上/右上，4/6 为左/右，1/2/3 为左下/下/右下。坐标从 0 开始，x 向右、y 向下。移动沿用原生 `moveDir` 的碰撞、开门和撞击语义。

## 会话、控制与命令结果

- 每次游戏加载创建新的 session；TCP 重连不改变 session。切图使旧实体引用失效，手动输入、stop、保存、切图和角色切换撤销控制权。
- MCP `tome.connect(mode='control')`（缺省）映射到内部 `connect`，验证配置凭据，先暂停已运行的 Battle Companion，再返回新的控制 token。
- `tome.connect(mode='observe')` 映射到独立的内部 `connect_observer`，只认证并保留本地战斗；没有 control token，act / stop 返回 `read_only_connection`。独立操作使旧 Bridge 拒绝新模式，不会忽略可选字段后获取控制。`capabilities.connection_modes` 列出两种模式，连接结果含 `mode`。
- 切回旁观会撤销原远程 token，取消未执行的远程命令；已执行动作继续结算，status 可查询原结果。任何模式切换、断线或 stop 都不自动恢复本地战斗。外部服务不得在断线后自动重新获取控制或重发动作。
- 普通按键按下或鼠标按钮按下，在调用原生输入处理前撤销 token、取消尚未开始的命令并断开旧客户端，防止旧缓冲中的 connect 重新接管。
- 一次最多一个未结束的游戏命令。执行前再次核对 session、token、revision、玩家、场景、交互和目标。
- 同 session 内相同 command_id 和相同动作/expected_revision 返回已有记录；不同参数返回 `command_conflict`。缓存达到上限后拒绝新命令，不淘汰标识再允许复执。
- 网络超时不说明动作失败；外部服务返回未确认的 command_id，显式重连后用 status 查询。跨游戏崩溃不承诺 exactly-once。

command record 的公共字段：`command_id`、`status`、`code?`、`energy_spent?`、`world_tick_before?`、`world_tick_after?`、`snapshot?`。状态为 `queued`、`executing`、`settling`、`completed`、`failed`、`cancelled`、`needs_input`。最后五个中的 completed/failed/cancelled/needs_input 为当前自动请求的结束状态；needs_input 不意味着游戏内原生协程被取消。早期结果的快照可按内存上限移除，记录仍保留 revision 与动作结果。

原生技能返回 false 也可能已经消耗能量，必须等待世界结算；普通攻击未命中仍可 completed。`energy_spent` 记录原生动作调用前后的能量差，不用结算后的能量倒算消耗。

显式 `act` 请求视为用户确认该动作，已适配技能通过 `no_confirm=true` 跳过可选的使用确认框；技能内部产生的其他原生交互仍保留。普通攻击调用原生 `T_ATTACK`，保留混乱等预检、替代攻击和未命中语义。

原生 tick、保存或换层抛异常时，桥接恢复自己的嵌套深度/边界标志并将原始错误交还引擎。已开始命令可返回 `failed`、`uncertain:true` 和对应 `native_*_error`；只读通信继续，写操作暂停到读档或新游戏产生新 session。不能把此错误当作未执行并重发。

## 原生调度：必须遵守的时序

1. `Game:display` 原生显示完成后轮询网络；收到 act 仅入队。
2. 用 `game:onTickEnd` 排入动作，回调再次核对请求版本。
3. `GameTurnBased:tick` 在暂停分支只调用 `engine.Game.tick`；该回调中动作扣能量解暂停后，后续 tick 才进入能量调度。未暂停分支先调用 `engine.Game.tick` 执行 onTickEnd，之后才调用 `tickLevel`。
4. `Player:act` 原生逻辑在足够能量时暂停；薄包装只记录 ready 信号。
5. 原生最外层 `Game:tick` 返回之后，后续 display 才确认结果；还需 `game.paused`、玩家能量足够、无原生待处理 onTickEnd、无模态对话/目标选择/保存/其他自动操作。
6. 瞬发技能不要求出现新的 Player:act，只要执行后的 tick 已返回且处于上述稳定边界即可完成。普通行动必须等待原生玩家重新可行动。

源码依据：[GameTurnBased:tick](../../../../game/engines/default/engine/GameTurnBased.lua)、[GameEnergyBased:tick](../../../../game/engines/default/engine/GameEnergyBased.lua)、[engine.Game:onTickEnd](../../../../game/engines/default/engine/Game.lua)、[ToME Game:tick](../../../../game/modules/tome/class/Game.lua)、[Player:act/useEnergy](../../../../game/modules/tome/class/Player.lua)。`onTickEnd` 会调用 `core.game.requestNextTick()`；ToME Game:tick 存在未处理回调时返回 false，因此可以唤醒原生暂停循环。

revision 是桥接的失效计数，不等于 game.turn。原生 tick、输入、对话、动作、保存及场景变更可增加它；重复只读工具调用不增加。允许保守失效，拒绝过期动作比复用不完整状态更重要。

## 快照与观察纯度

snapshot 固定字段：`session_id`、`revision`、`phase`、`world_tick`、`control_source`、`player`、`map`、`actors`、`talents`。

0.2.0 在安装 Battle Companion 0.1.1 时增加可选 `battle_companion` 摘要，包含 `state`、`actions`、可用时的 `code` 和 `message`，只读取既有运行状态。`control_source` 为 `remote`、`battle_companion` 或 `manual`；本地助手运行时 phase 为 `unavailable`，远程接管先取消助手队列，再等待原生 ready 边界。助手也在每次执行前检查 Bridge 是否持有 token 或有未完成命令，防止两个控制来源同时行动。

- phase：`ready`、`settling`、`needs_input`、`terminal`、`unavailable`。
- player：id、名称、坐标、生命/最大生命/死亡阈值、当前能量、已存在的常见资源、临时效果。
- map：局部范围、可见地形/障碍、之前由桥接观察到的地形记忆。未观察过的记忆区域允许 unknown，不能读取隐藏地形当前值来冒充历史记忆。
- 地形还要求原生视觉 FOV，不能把 ESP 的 seens 当成地形可见。首版对其他角色所在格额外要求静态照明，因此仅被火炬照亮的角色脚下地形可能少报；角色感知独立处理。
- actors：输出原生 `map.seens` 且玩家已有 `can_see_cache[actor]['nil/nil']` 成功记录的角色；已有失败缓存优先。原生 Actor:act 会清空缓存，静止角色的地图显示不一定重建缓存，因此缓存缺失时仅允许经过函数来源审核的确定性普通视觉分支：玩家 canSee/canSeeNoCache、双方 attr 均为原生实现，且不存在失明、隐身、潜行或遮蔽属性。特殊感知或第三方实现缺少缓存时保守省略，不调用 `canSee` 产生随机判定。inspect 同样过滤。
- talents：读取已学习技能的稳定 ID、名称、等级、冷却、支持状态、固定目标模式。动态成本标 unknown，不调用 preUseTalent、target、info、action 进行预测。
- 首版不输出敌人技能、背包、未发现陷阱等后台信息。原生动作有随机结果，候选能力不保证施放成功。

## 文件分工

```text
game/addons/tome-mcp-bridge/
  init.lua; hooks/load.lua
  superload/mod/class/Game.lua; Player.lua
  overload/mod/mcp_bridge/
    Runtime.lua       # 会话、控制、版本、调度、结果缓存
    Observer.lua      # 只读快照与实体解析
    Actions.lua       # 原生动作适配与技能白名单
    Input.lua         # 当前运行态输入包装
    TransportSocket.lua # 非阻塞收发；new/poll/send/close/disconnectClient
    Json.lua          # 严格编解码；encode/decode/null/array
  tests/
tools/tome-mcp-server/ # 官方 SDK stdio 服务、TCP 客户端、schema、测试
```

runtime、socket、队列与目标引用都存放在 Lua 模块局部状态中，不附加到可保存游戏对象。

## 验收门槛

| 检查 | 成功条件 |
| --- | --- |
| 观察纯度 | 连续 observe/inspect 不改变能量、资源、冷却、world_tick，不调用 RNG 或动作/技能预检；隐藏角色不可 inspect |
| 原生动作 | 移动、等待、普通攻击、自疗、Lightning 均由原生入口执行；敌人正常行动，返回 ready 边界 |
| 瞬发 | Adrenaline Surge 产生原生效果/冷却、revision 改变，不要求 world_tick 前进 |
| 去重与版本 | 重复请求不重复行动；同 ID 不同请求冲突；过期 revision 拒绝 |
| 网络 | 半包、多包、部分发送有界；断开后重连并查询状态，不自动重放动作 |
| 接管与边界 | 真实按键/鼠标及 stop 取消 pending，旧 token 失效；读档会话变化；对话中拒绝新世界动作 |
| MCP | 官方客户端 initialize/list_tools/call_tool 经过 stdio 到 TCP，再到原生角色完成闭环 |

测试分为纯 Lua 协议/状态机测试、Python stdio/假桥接测试、独立原生测试角色的端到端验收。每项必须注明实际执行与证据，不能用 mock 代替原生动作验收。
