# ToME MCP Bridge v2 交互契约（0.6.0）

> **已废弃（2026-09-15）**：本仓库已在测试阶段移除协议 v1/v2，仅保留协议 3。本文仅作历史参考，字段与行为以 [v3 契约](tome-mcp-v3-talent-query.md) 和 [API 字段](tome-mcp-api-fields.md) 为准。


适用：本仓库 ToME 1.7.6 原生代码、Bridge / Python server 0.6.0。协议 v1 继续提供旧技能适配，默认连接仍为 v1。完整配置见 [README](../README.md)；设计依据见 [交互设计](tome-mcp-interaction-capabilities-design.md)。

## 连接与动作

调用 `tome.connect(mode="control", protocol_version=2)` 获取控制权。旁观使用 `mode="observe"`。协议版本在 TCP 信封的 `v` 中传递；连接后其他操作必须使用同一版本。旧 addon 拒绝 v2 时客户端不会自动降级。

普通动作保留原生执行路径。v2 在移动、等待、攻击、成长和物品操作中也保留调用归属，以处理动作已生效后出现的原生说明窗口。v2 提供以下技能及物品入口：

```json
{"type":"use_talent","talent_id":"T_RUSH"}
{"type":"set_sustain","talent_id":"T_PRECISE_STRIKES","enabled":true}
{"type":"use_item","item_id":"当前拥有的物品ID"}
```

`use_talent` 不接受 `target_id`；目标在原生流程询问时提供。维持技能必须用 `set_sustain`，已经处于期望状态时返回 `completed / already_in_desired_state`，耗能为 0。被动、未学习、缺少可用执行函数或不兼容入口的技能不能执行。

v2 不按技能 ID 登记脚本。`activation.admitted` 表示原生入口可尝试；`interaction_coverage="runtime_checked"` 表示具体交互在运行中确认。它不保证原生条件满足或每一种后续 UI 都可自动处理。

`use_item` 沿用原生 playerUseItem 协程、Object:use 效果和 playerUseObject 清理。支持通用 use_power / use_simple / use_talent；穿戴、充能、世界地图等限制仍由原生路径检查。成功依据物品返回的 `used`，不会把 playerUseItem 提前返回的 true 当成效果完成。读取已鉴定物品的 activation 只报告现有字段，不执行物品回调；未鉴定属性仍隐藏。

## 剧情和物品说明

`dialog.notice` 暴露当前栈顶的 Close 选项，使用现有 `option` 回答；也接受其声明的原生 `cancel`。`native_ui` 标明 QuestPopup、LorePopup、ShowLore、simplePopup 或 simpleLongPopup。关闭后可能继续显示另一层，仍使用原 command_id；interaction_id 和 sequence 会更新，不能缓存旧问题作为下一层回答。

任务奖励、经验或拾取可能早于窗口完成。回答只调用当前窗口实际的 EXIT 闭包，不重放动作、不清空窗口栈。命令归属沿原生 onTickEnd 注册的回调传递，原生队列仍决定排序、同名去重与重排；不把其他来源的全局窗口自动认领为本命令。无关闭入口或未知 UI 移交玩家。原生休息使用原有被动等待窗口，外部或未归属的剧情仍可触发人工接管。

## 生命周期

| 状态 | 意义 | 客户端下一步 |
| --- | --- | --- |
| `queued` / `executing` / `settling` | 排队、执行或等待原生结算 | 查询原 command_id |
| `awaiting_input` | 本次调用提出了可回答的原生问题 | 按当前 interaction 回答 |
| `running_native_task` | 技能中的原生休息任务仍在运行 | 查询原 command_id；需要中断时 stop |
| `completed` / `failed` / `cancelled` | 命令结果已确定 | 核对执行释放、阶段、快照和控制凭据 |
| `needs_input` | 已移交玩家 | 在原生窗口处理；不能通过新命令绕过 |

新增结果字段：`revision`、`input_owner`（remote/orphaned/manual）、`execution_released`、`energy_spent_complete`、可选 `interaction`、`response_receipt`、`native_task`。observe 在执行占用期间提供 `pending_command`。

命令结束与原生调用释放是两件事。`needs_input` 后仍可能有协程挂起；`execution_released=false` 继续阻止新动作和 Battle Companion。玩家完成界面后状态保留 `needs_input`，仅把 `execution_released` 更新为 true，不改写成自动执行成功。原生错误会保持隔离直到重新加载。

跟踪范围包含 useTalent 的主体、前后检查、消耗、冷却、post_action、嵌套子调用以及已登记的原生任务。第一次 useTalent 返回不代表挂起的主体结束。先扣能量再提问的技能也会暂停世界，回答后才进行后续原生结算。

## 回答

`tome.respond` 接受：

```json
{
  "session_id":"当前session",
  "control_token":"当前lease",
  "command_id":"原命令C",
  "interaction_id":"当前问题I",
  "response_id":"回答R",
  "expected_revision":123,
  "answer":{"type":"position","x":10,"y":8},
  "wait_ms":2000,
  "include_map":false
}
```

`answer` 是严格联合类型，不能混入其他字段：

| type | 唯一额外字段 |
| --- | --- |
| `actor` | `target_id` |
| `position` | 整数 `x`、`y` |
| `direction` | `direction` 为 1–9，排除 5 |
| `option` | `option_id` |
| `cancel` | 无 |

仅使用当前 `answer_types` 声明的类型。每次新提问有唯一 interaction_id 和递增 sequence，仍属于同一 command_id。回答排在原生 onTickEnd 执行；执行前再次检查控制权、版本、交互归属、场景和角色状态。

### 提供方

- `target.grid`：通过原生 setSpot / targetMode 提交格子。actor 是当前感知角色位置的快捷方式，包含自身；候选最多 32 个，不表示必中或可到达。坐标可指定地图范围内未知格子，不提供隐藏内容判断。最终范围、投射、玩家目标重定向和原生自我警告保持有效。
- `target.direction`：仅在已确认的原生即时方向模式、玩家为方向起点时开放，调用原生 setDirFrom；其他目标仍使用 grid。
- `dialog.confirm`：原生 yesnoPopup / yesnoLongPopup 的真实按钮和退出回调。自定义按钮文字不会被转换为猜测的布尔值。
- `dialog.choice`：原生 listPopup 已构造的列表和 ACCEPT 回调。
- `inventory.select`：原生 ShowInventory / ShowEquipInven 当前已显示的项目和原始 use 回调。保留当前筛选／页签；不额外运行过滤或物品命名函数。被原生修改为无法确认的回调或过期库存项目不能执行。

列表每页 32 项，提供 `options_total`、`options_offset`、`options_next`。用 `tome.status(command_id, options_offset=...)` 读下一页。`option_id` 绑定当前问题和行，重复标签不合并；重发问题后旧选项 ID 失效。选择后原生界面若继续保留，会生成新问题 ID。

目标与对话必须属于本次调用。无法识别的自定义窗口或裸 yield 会转人工并保留执行占用；若原生流程没有人工恢复入口，需要重新加载可恢复的游戏状态。

## 去重、超时与接管

- command_id 的首次动作请求与 expected_revision 一起去重；同 ID 不同内容冲突。
- response_id 绑定完整回答、interaction_id 和 expected_revision；同 ID 同请求查询已有结果，不重复回调；同 ID 不同请求返回 `response_conflict`。
- 问题被接受一次后记下消费记录；换 response_id 回答同一个旧问题返回 `interaction_consumed`。每个命令最多接受 128 次回答，耗尽则转人工。
- `response_receipt.state` 为 queued/applied/rejected。applied 表示原生回调已调用，即便回调后发生错误，也不能再次执行。
- 超时或断线后保留 command_id 与 response_id，显式 connect 后 `status(command_id, response_id)` 查询。Python 不自动重发写入；respond 的轮询不会把旧问题的 queued 回执误当成下一次提问。
- 明确的 stale_revision 拒绝未执行本次回答，需读当前状态再决定。排队后版本失效会拒绝回执，并为仍有效的原生界面发新 interaction_id。
- 断线不代答取消；未人工接管且角色／楼层未变的孤立输入可以由显式 v2 控制连接收回。任务会走原生停止，不因重连恢复。
- 普通键鼠、stop、观察模式切换、v1 降级或不支持窗口会移交玩家；重新连接不能夺回已经人工接管的调用。
- stop 在输入阶段不关闭界面；cancel 是原生当前问题的取消，后续代码仍可执行。Catapult Trap 的第二次选点取消后，已放下的陷阱仍存在。

## 原生任务、保存与错误

`task.rest` 跟踪原生 restInit、restStop、最终回调和清理，累计每个命令最多 1000 个原生任务步（包含首步）。`native_task` 报告任务 ID、running/ended、实际步数、原生回合目标和停止原因。预算耗尽调用原生 stop，报告 task_budget_exhausted；不替换 Refit Golem 自身的 `cnt > max` 完成判断。

`energy_spent` 累计原生 useEnergy 的实际消耗，不把跨暂停的能量差当作总成本。若发现无法完整计量的直接能量变化，`energy_spent_complete=false`。原生拒绝可能已经扣资源，命令失败不代表回滚。

保存遇到未释放调用会延期，不序列化命令、协程、交互闭包或远程凭据。原生输入解决后，在安全结算边界发起保存，并继续启动原生后台保存调度。重新加载建立新 session，不恢复旧命令或自动控制。

同步与恢复后的异常记录有界 native_message 和 uncertain，并隔离后续写入。状态和回执仍可查询；不能声称撤销了已移动、已扣资源或已放置的对象。保存延期但原生调用无法解决时，不会把无法恢复的挂起执行保存成有效快照。

## 实现与兼容

`InvocationTracker` 管调用树与协程；`Interactions` 管原生输入；`NativeTasks` 管任务；`Runtime` 管队列、版本、租约、回执、结算与执行占用。原生方法插入点由 `tools/generate_native_seams.py` 从当前引擎源文件生成，打包前检查一致性，无核心游戏文件改动。

相关原生函数来源和文件校验值用于兼容检查，并核对当前函数身份。MD5 仅作为引擎可用的代码兼容校验，不作为安全认证。Dialog 在 addon 加载前已被缓存，因此对其审核过的构造函数使用早期安装模块；普通非跟踪调用保留原方法。

生产 `.teaa` 不包含测试 probe。原生隔离场景验证边界；普通存档回归验证既有成长、装备、保存和插件配合。具体数量、哈希与限制以 [验收记录](../VALIDATION.md) 为准。
