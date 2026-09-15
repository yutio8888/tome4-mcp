# ToME MCP Bridge 0.8.0

让 MCP 客户端读取 ToME 1.7.6 的玩家视角状态，并执行一个原生游戏动作。由游戏内 Lua addon 与游戏外 Python MCP 服务组成，使用本机 TCP 通信。

## 能力

- 玩家生命、资源、效果、能量、等级经验与可用点数，区域和实际楼层，背包／装备摘要、局部地图、当前感知角色及已学习技能。
- 八方向移动、等待、相邻普通攻击、当前位置的原生换层命令，以及有回合上限的原生休息任务。
- 通用原生技能调用：目标格子／方向、确认框、列表和物品选择、连续提问、明确开关的维持技能、原生休息型多回合任务。
- 只读技能查询（射程、消耗、冷却、条件/可用性提示）与一次性目标预填。
- 原生结算、状态版本检查、命令与回答去重、结果查询、手动接管；可见游戏日志游标与可选省略地图的紧凑响应。
- 受控的单点属性、技能和类别成长；可见地面物品、脚下拾取、原生穿戴与卸下。
- 只读旁观模式；与 Battle Companion 0.1.1 的控制交接，以及助手状态／暂停原因摘要。

根据执行中出现的原生界面提供输入；不按技能 ID 编写施法脚本。未覆盖的自定义界面仍返回 `needs_input`，由玩家在游戏窗口处理。属性/类别洗点和创建角色不在本版范围内；`unlearn_talent` 只退还原生最近学习窗口内的技能点。联网能力可用是本版前提。

## 原生 Chat 对话（0.7.0）

原生 Chat 通过 `dialog.choice` / `native_ui="Chat"` 暴露当前已显示的选项。使用当前 `interaction_id` 和 `option_id` 调用 `tome.respond`；分页仍为 32 项，`tome.status(options_offset=32)` 读取下一页。选项文本不含原生键盘字母快捷键。读取不重新执行条件、文本生成或奖励回调。选项对应的原生 `Chat:use` 负责奖励、跳页和关闭。

护送开场、完成奖励、告别可以属于同一条原始命令的后续页面。只显示实际栈顶，每个新页面有新的 ID；不能沿用上一页的 ID。原生自动页面由游戏自行继续。没有原生取消选项时不提供 `cancel`。重复 act/respond 不重放已经发生的移动、换层或奖励。

已归属的 `change_level` 跨场景后保留当前对话和原命令，但控制租约失效：显式重新 `connect`，再 `status` 原 command_id 并回答，不能再次发起换层。原生加载等待窗口由游戏自动关闭；自动保存延后到这次交互全部结束。其他未声明的场景切换、未知 UI 或修改过的原生入口仍交给玩家。Battle Companion 的已发布换层包装及其下层原生入口均作源码校验。

`stop` 和真实键鼠输入保留原生对话供玩家接手；手动保存也等待执行占用结束后才落盘。本版不把已有的手动对话收编到新命令中。普通单角色护送奖励已专项验证；奖励转入其他自定义窗口时按实际 provider 支持范围处理。

## 世界地图观测（0.6.1）

世界地图沿原生 `playerFOV → computeFOV → applyLite` 的当前可见缓存报告地形与入口；检查相关方法身份和完整源码校验和。普通地牢仍要求 `seens + infovs`，失明时不新增地形知识。观测不触发视野计算、随机判定或移动回调。

`known=true` 表示本桥接会话曾观察过，`visible=true` 表示当前可见。原生 `remembers`、全图照明和已发现地点列表不会自动导入。视野外保留已有桥接记忆，不读取隐藏变化；重启游戏后重新积累。地图范围仍最多为身周 12 格，`is_exit` 标识可见通路，`name` 为其可见名称；不会返回隐藏目的地数据。`block_status` 只表示地形通行规则，实际移动和进入仍由原生命令判定。

## 安装游戏 addon

将源码目录 `tome-mcp-bridge` 或生成的 `tome-mcp-bridge.teaa` 放入游戏 `game/addons/`，保留其中一个版本，在插件管理中启用。先使用启用 addon 后创建的测试角色；旧存档会受其记录的 addon 集合约束。

在游戏用户目录的 `settings/` 中新建 `mcp-bridge.cfg`。Linux 通常是 `~/.t-engine/4.0/settings/mcp-bridge.cfg`；其他平台使用实际游戏用户目录。内容：

```lua
tome_mcp_bridge = {
    enabled = true,
    port = 17646,
    token = "替换为你生成的本机共享凭据",
}
```

可以用 Python 生成凭据：

```sh
python3 -c 'import secrets; print(secrets.token_hex(24))'
```

重启游戏后进入已启用 addon 的角色。addon 只监听 `127.0.0.1`，没有配置 token 时不会启动监听。每个游戏实例使用不同端口。

## 安装 MCP 服务

需要 Python 3.11 或更新版本。在仓库根目录执行：

```sh
python3 -m venv server/.venv
server/.venv/bin/python -m pip install -e server
```

Windows 使用相应环境的 `Scripts/python.exe`。

向支持 stdio 的 MCP 客户端添加服务。以下是通用配置示例，路径和凭据需要替换：

```json
{
  "mcpServers": {
    "tome": {
      "command": "/absolute/path/t-engine4/server/.venv/bin/python",
      "args": ["-m", "tome_mcp"],
      "env": {
        "TOME_MCP_PORT": "17646",
        "TOME_MCP_TOKEN": "与游戏配置相同的凭据"
      }
    }
  }
}
```

本服务使用官方 Python MCP SDK `mcp==2.2.0`。MCP 客户端由 SDK 处理协议协商；游戏内部使用独立的 JSON TCP 协议 v3。[官方 SDK](https://py.sdk.modelcontextprotocol.io/)

## 使用方式

1. 读取 `tome://rules`。
2. 自动操作时调用 `tome.connect(mode="control")`，获取 `session_id`、`control_token`、`revision` 和能力列表。只旁观时使用 `mode="observe"`，其 `control_token` 为 null。
3. 调用 `tome.observe`，需要详情时使用 `tome.inspect`。
4. 调用 `tome.act`，携带上述会话、控制凭据、快照版本和一个唯一的 `command_id`。
5. `awaiting_input` 时，用 `tome.respond` 回答当前问题；`running_native_task` 时查询原 command_id；只有结算并释放执行后才提交下一个动作。

| 工具 | 参数概要 |
| --- | --- |
| `tome.connect` | 可选 `mode`：`control`（缺省）或 `observe`；从服务环境读取共享凭据 |
| `tome.observe` | `session_id`、可选 `radius`（1–12，默认 8）、`include_map`、`events_after` |
| `tome.inspect` | `session_id`、`kind`（`actor` / `talent` / `progression` / `item`）、`id`；v3 的 `kind=talent` 可选 `target_id` 或 `x`/`y` 以附加距离 |
| `tome.act` | `session_id`、`control_token`、`command_id`、`expected_revision`、`action`、可选 `wait_ms`、`include_map` |
| `tome.respond` | `session_id`、`control_token`、`command_id`、`interaction_id`、`response_id`、`expected_revision`、`answer`、可选 `wait_ms`、`include_map` |
| `tome.status` | `session_id`、`command_id`、可选 `response_id`、`options_offset`、`include_map` |
| `tome.stop` | `session_id`、`control_token` |

`tome.act` 的 `action` 示例：

```json
{"type": "move", "direction": 6}
```

```json
{"type": "use_talent", "talent_id": "T_RUSH"}
```

方向使用数字键盘，`6` 向右、`8` 向上；坐标从 0 开始，x 向右、y 向下。移动沿用原生碰撞、开门、撞击等行为。等待会触发原生装填和等待回调。

`act` 默认轮询约 2 秒等待结果，可设置 `wait_ms=0` 立即返回。轮询窗口上限 10 秒，每次桥接请求另外受 5 秒网络超时约束。`queued` / `executing` / `settling` 表示尚未完成，继续查询 `status`。

### 技能查询与目标预填

以下两项能力随协议 3 始终可用。

**只读技能查询。** `tome.inspect(kind="talent", id=..., target_id=...)`（或传 `x`/`y`）在原有技能摘要外返回 `query`：

| 字段 | 含义 |
| --- | --- |
| `range` | 存储的射程；动态函数标 `unknown`，不执行 |
| `requires_target` / `target_type` | 存储的目标要求；动态函数标 `unknown` |
| `cooldown_remaining` | 当前剩余冷却 |
| `current_costs` / `costs_complete` | 当前实时消耗（原生 `postUseTalent` 公式，含疲劳/效果）；不可知时对应项为 `unknown` |
| `base_costs` | 存储的基础消耗，供对照 |
| `affordable` | 用当前资源对已知消耗的比较；不可知为 `unknown` |
| `readiness` / `readiness_reason` | 仅基于已存储标量的保守提示（`available`/`blocked`/`unknown`），不是原生预检 |
| `distance` / `in_range` | 传入 `target_id` 或 `x`/`y` 时的距离与射程比较 |
| `prefill_supported` / `prefill_modes` | 本版本支持 `actor` 与 `position` 预填 |

查询不运行 `preUseTalent`、动态 `info`、投射或命中计算，因此不会因查询产生副作用或消耗 RNG；实时 `current_costs` 只调用原生 `cost_factor`（可能读取只读疲劳 getter）。`query_is_advisory=true`，实际能否施放仍由原生执行决定。

**一次性目标预填。** v3 的 `use_talent` 可带 `target_id` 或 `x`/`y`：

```json
{"type":"use_talent","talent_id":"T_RUSH","target_id":"s1:level-1:actor-2"}
```

预填在**第一次原生 `getTarget` 消费一次**，随后立即交还原生目标流程；同一动作的后续提问仍用 `tome.respond` 回答。**射程与边界沿用原生规则**：静态射程在动作开始前拒绝越程（`target_out_of_range`），动态射程在第一次 `getTarget` 处校验；越界/越程或会触发原生自我警告时回退到原生目标提示，而不是盲发坐标。`tome.respond` 的 `target.grid` 位置答案也按射程校验（`position_out_of_range`）。不设置全局 `target.forced`；`target_id` 必须当前可见，`x`/`y` 不得同时与 `target_id` 出现。

### 原生交互

`use_talent` 只传 `talent_id`，可选预填 `target_id` 或 `x`/`y`；`set_sustain` 使用明确布尔值：

```json
{"type":"set_sustain","talent_id":"T_PRECISE_STRIKES","enabled":true}
```

动作可以直接结束，也可以提出一个或多个问题。击杀、升级、移动和拾取可能已经生效，随后才出现剧情或物品说明。`awaiting_input` 不是最终结果；保留同一 `command_id`，按当前 `interaction.answer_types` 提交回答：

```json
{
  "session_id":"来自连接",
  "control_token":"来自连接",
  "command_id":"原动作命令ID",
  "interaction_id":"当前问题ID",
  "response_id":"本次回答唯一ID",
  "expected_revision":123,
  "answer":{"type":"actor","target_id":"当前感知的角色ID"}
}
```

| 输入类型 | 回答内容 |
| --- | --- |
| `target.grid` | `actor` + `target_id`，或 `position` + `x/y`，或 `cancel` |
| `target.direction` | `direction` + 数字键盘方向，或 `cancel` |
| `dialog.confirm` / `dialog.choice` | `option` + 当前 `option_id`；只在声明支持时使用 `cancel` |
| `dialog.notice` | 当前 `Close` 选项的 `option_id`，调用该层原生关闭回调 |
| `inventory.select` | 原生界面当前筛选／页签中的 `option_id`，或 `cancel` |

选项每页 32 个；用 `status(options_offset=interaction.options_next)` 继续读取。重复标签有不同 ID。按钮文字仅描述其原始含义，选择直接执行对应原生回调，不把“是／否”标签猜成布尔值。候选角色只来自当前感知，包含玩家自身；选择角色表示选择其当前格子。坐标不能用于探测隐藏内容，原生投射和范围检查仍决定最终结果。

`dialog.notice` 支持原生 QuestPopup、LorePopup、ShowLore，以及可关闭的 simplePopup / simpleLongPopup。只显示实际栈顶；每次回答关闭一层，可能随后出现下一层。原生回合末回调继承发起动作的归属。不要为关闭弹窗再次攻击、移动或拾取；去重、断线恢复、人工接管和 Battle Companion 互斥覆盖整个过程。已归属换层中的原生加载等待弹窗由游戏自动完成；其他无关闭入口的等待弹窗、未知类或被改写的回调仍交给玩家。

### 原生物品激活

```json
{"type":"use_item","item_id":"当前背包或装备中的物品ID"}
```

通用入口调用原生 `playerUseItem → playerUseObject → Object:use`，支持物品原有的 use_power / use_simple / use_talent，不登记特定物品 ID。目标和确认由实际原生界面提出。原生规则检查穿戴、失明、沉默、充能、冷却和世界地图限制，并处理消耗品移除、鉴定和能量消耗。`native_return` 来自物品原生 `used` 结果，包含后续清理；取消不代表回滚。

已鉴定物品的 `activation` 提供存储中的充能等字段；`present` 表示存在激活定义，`runtime_checked` 表示仍须原生执行检查。读取不调用物品效果或动态说明。使用后的持续效果按普通游戏回合运行；例如 Rod of Recall 激活完成后还需要原生回合才能传送。

`response_receipt.state` 为 `queued` / `applied` / `rejected`。网络超时后保留 **command_id 和 response_id**，显式连接后查询 `status(command_id, response_id)`；不能换 ID 重发。同一请求可幂等查询；复用 ID 更换内容会冲突；同一问题只能接受一次回答。明确的 `stale_revision` 拒绝未执行回答，应先查询最新问题和版本再决定是否提交。

`running_native_task` 表示技能正等待原生休息结束；没有需要回答的 UI。`native_task` 报告实际步数、原生目标和累计最多 1000 回合的自动化预算。完成、停止、失去控制或预算耗尽均走原生清理与回调。能量统计累计实际 `useEnergy` 调用；`energy_spent_complete=false` 表示发现无法完整计量的原生变化。

`cancel` 只取消当前原生输入，技能可能继续并产生效果。`stop` 在等待输入时将界面交给玩家，不代答取消。`needs_input` 是人工接管；`execution_released=false` 表示旧技能仍占用执行，不能开始新动作或自动战斗。没有人工接管或上下文变化的孤立输入可在显式控制连接后恢复；后台任务不会因重连重新开始。

原生协程不进入存档：挂起期间的保存会推迟到本次调用解决后。无法恢复的原生错误会保留部分结果、标记 `uncertain`，并限制写入直到重新加载。能力列表的 `activation.admitted` 表示允许尝试原生入口，不保证资源、距离或后续界面都满足；具体输入在运行中验证。若另一插件改写了相关原生入口而无法确认兼容，桥接拒绝自动执行或交给玩家。

### 换层、技能与休息

站在出口上提交 `{"type":"change_level"}`。它调用原生 CHANGE_LEVEL，保留禁行状态、区域限制、转化箱确认、地图加载与后台保存。成功时返回 `completed / level_changed` 和新的 `level_instance_id`、`scene`。换层会撤销控制凭据，下一步应显式 connect；重复查询／重发同 command_id 不会再次换层。需要对话时返回 `needs_input`，不能靠换一个 ID 重试来绕过确认。

Stunning Blow 和 Warshout 需要可见角色的 `target_id`；Warshout 沿该目标方向释放原生锥形战吼。三类纹身使用快照里的实际 ID（例如 `T_INFUSION:_HEALING_3`），不传目标。`T_ATTACK` 的 `action_adapter="attack"` 表示应使用普通攻击动作。

提交 `{"type":"rest","max_turns":1000}` 开始原生休息。上限允许 1–1000，包含第一步；不会直接添加生命或改写原生恢复。任务遵守游戏自身的资源、生命和冷却恢复规则，原生敌人、伤害、负面效果、其他弹窗、stop 和控制变化均可中断。

使用原 command_id 查询 `turns_executed`、`max_turns`、累计 `energy_spent`、`stop_reason` 和可选的 `native_message`。常见结束原因是 `native_complete`、`native_stopped`、`max_turns`、`damaged`；原生敌人提示通过 `native_message` 返回，不依赖文本语言生成原因码。主动取消的任务可能已执行部分回合；断线、读档或重新连接不会恢复它。

### 成长与物品

调用 `tome.inspect(kind="progression", id="player")` 读取当前角色已具备的技能树、原始技能等级、点数成本和经过审核的条件。信息只来自玩家已有类别与已知状态；没有为展示信息调用动态技能说明或学习预检。未适配的动态条件保留 unknown，执行时仍经过原生检查。

本版审核了普通 Berserker 可用的 11 类技能树。其他类别可以有只读摘要，学习支持以各项 `supported` 为准。**最近学习的技能点可以退还**（`unlearn_talent`），受原生 `last_learnt_talents` 窗口、非战斗和 item 授予保护约束；属性点与已解锁类别在原生升级对话框之外不可退还，因此不提供。传奇点和纹身槽扩展尚未适配。

```json
{"type":"spend_stat","stat":"str"}
```

```json
{"type":"learn_talent","talent_id":"T_WEAPONS_MASTERY"}
```

```json
{"type":"learn_category","category_id":"technique/conditioning"}
```

```json
{"type":"unlearn_talent","talent_id":"T_RUSH"}
```

`unlearn_talent` 每次退还一个点，仅限原生 `last_learnt_talents` 窗口内且不在战斗中；`inspect(kind="progression")` 的 `respec.unlearnable` 列出当前可退还的技能与原因。

这些动作每次提交一个点并完成原生确认流程。属性只接受 `str/dex/mag/wil/cun/con`；技能自动使用其职业或通用点数。类别动作解锁角色已有的锁定树，或将已解锁树的基础掌握系数提高 0.2，每棵树至多强化一次。检查返回的具体可用条件；这三个示例不保证任意角色当下都能执行。

分配是已提交的角色变化，不提供预览回滚（洗点见下方 `unlearn_talent`）。学习新技能会保留原生冷却与学习／完成回调；是否能激活以当前协议的能力信息和运行时原生检查为准。原生条件拒绝不扣点；若原生回调在中途抛错，结果会标明 `uncertain` 并限制本会话继续写入，直到重新加载游戏。

快照的 `ground.items` 列出当前窗口内可见地面物品。远处物品堆只报告原生界面可知的顶层物品及数量；脚下可读取拾取列表。它不是物品地图记忆，物品离开可见范围后应重新观察。`include_map=false` 仍可返回地面物品摘要。

```json
{"type":"pickup","item_id":"来自脚下地面物品的ID"}
```

```json
{"type":"equip","item_id":"来自背包的ID"}
```

```json
{"type":"unequip","item_id":"来自当前装备的ID"}
```

拾取仅限当前脚下，地面 ID 绑定会话、楼层和位置。库存 ID 绑定会话，执行时按物品身份重新定位；穿戴和卸下使用原生装备流程，不接受强制条件、任意目标槽位或回调。通过 `tome.inspect(kind="item", id=...)` 可读取该物品当前已知详情，未鉴定属性仍隐藏。堆叠、替换装备或原生回调可能改变位置和 ID，每次操作后用新快照继续。

装备条件、睡眠等限制、负重、背包容量、耗时和回调沿用原生规则。拾取沿用原生单件／多件拾取分支：单件普通拾取成功消耗一回合，多件选择分支本身不额外耗能；以结果的 `energy_spent` 为准。

### 超时与接管

- **保留 command_id。超时后不生成新 ID 重试动作。** 显式重新 connect，再用原来的 session_id / command_id 查询状态。
- `failed` 可能已经消耗行动；以结果中的能量和快照为准。
- 普通按键或鼠标按钮按下会撤销远程控制并让原生输入继续处理。
- `stop` 取消未开始的工作并中断当前 MCP 休息任务，已发生的动作和原生世界结算正常完成。
- 游戏重新加载产生新 session；旧命令失效。TCP 重连保持原来的游戏 session。
- 与 Battle Companion 配合时，获取远程控制会先暂停助手；普通键鼠仍可接管。释放控制、断线、保存或读档都不会重启助手。
- 原生自动施法、休息、奔跑和其他自动控制可能影响行为；以 addon 返回的阶段和能力限制为准。旁观模式不暂缓原生自动施法。

### 旁观本地自动战斗

在游戏里用 Ctrl+B 开始 Battle Companion 后，调用 `tome.connect`，参数为 `{"mode":"observe"}`。随后可以调用 observe、inspect、status；act 和 stop 返回 `read_only_connection`。需要操作时明确调用 `{"mode":"control"}`，它会暂停助手；切回旁观会撤销远程凭据、取消尚未执行的远程动作，但不会重启助手。

安装 Battle Companion 0.1.1 后，快照增加 `battle_companion` 对象，含 `state`、`actions` 及可用时的 `code`／`message`。这是已有状态的只读摘要，不重新计算威胁。助手运行期间 `control="battle_companion"`、`phase="unavailable"`；远程接管后须等到 `phase="ready"` 再行动。没有安装助手时不提供该摘要。

旁观认证与控制认证使用不同内部操作，因此旧版 Bridge 会拒绝旁观请求，不会忽略新参数后意外接管。请同时更新游戏 addon 与 Python 服务；客户端不得自动从旁观回退到控制模式。

### 观察范围

优先使用已存在的感知缓存；不会为观察额外调用 `canSee`、随机函数或技能预检。原生实现清空缓存后，只对原生可见性方法未被改写、位于当前视野且无致盲／隐形／潜行／隐匿条件的普通角色使用确定性判断；无法安全判断时省略角色。地形记忆从桥接实际看见的内容累积。未适配成本标注为未知或基础值，不保证实际施法成功。

地图附带半径与窗口边界。`act` 的快照默认半径 8，`observe` 可请求 12；同一 level_instance_id 内只替换响应覆盖的格子，保留窗口外的历史观察。不同 level_instance_id 的地图必须分开保存。原生普通地形的通行信息只描述地形，不保证没有角色、陷阱或后续交互。

`include_map=false` 适用于 observe / act / status，返回 `map=null`，适合休息和短间隔轮询。省略地图不代表地图为空。

`events` 来自玩家已经看见的游戏日志。将返回的 `events.cursor` 传入下一次 observe 的 `events_after`；若 `has_more=true` 则继续取页，`gap=true` 表示游标已落在有限缓存之外。append / update / remove / reset 描述日志变化，remove 可能来自撤回、清空或历史淘汰，不代表游戏动作回滚。`observed_world_tick` 是桥接采集时点，不是每条日志的精确发生时点。

等级经验、点数、物品和可见敌人检查使用现存字段。未知物品保持未鉴定；基础攻防和抗性不等于最终战斗公式。接口不会为填充这些信息运行物品鉴定、动态说明或战斗预检。

观察列表和文本有长度上限，压力较大时也可能缩短地图名称、技能或角色列表；顶层 `truncated` 和各字段的 `*_truncated` 会标明省略。事件缓存最多 256 项，每页最多 16 项、单条文本最多 512 字节。需要完整日志取证时仍应保留本机原生日志。

桥接仍只允许一个 TCP 客户端。第二个客户端连接失败时会提示检查是否已有客户端占用；该提示也保留其他连接故障的可能性。

## 开发与验证

从仓库根目录运行：

```sh
bash game/addons/tome-mcp-bridge/tests/run.sh
PYTHONPATH=server/src server/.venv/bin/python -m unittest discover -s server/tests -v
```

真实游戏的隔离环境、依赖与命令见 [原生验收说明](tests/native/README.md)。实际测试结果见 [VALIDATION.md](VALIDATION.md)。

打包：

```sh
python3 game/addons/tome-mcp-bridge/tools/package.py
```

输出在 `dist/`，生产安装包不包含测试 probe。Python MCP 服务单独安装。

源码依据与实现约定见 [架构分析](docs/tome-mcp-architecture.md) 和 [v3 契约](docs/tome-mcp-v3-talent-query.md)、[API 字段](docs/tome-mcp-api-fields.md)。
