# Battle Companion 0.1.1：使用 MCP 开发与验证控制交接

日期：2026-09-15。MCP Bridge / Python server 0.2.0；Danger Alert 保持 1.3.1。

## 实际问题与改进

先复跑 MCP 首版真实游戏验收，`mcp-handoff-02` 的 92 项通过。随后在隔离角色上同时加载三个插件，用 MCP 移动到敌人旁边，用真实 Ctrl+B 开始自动战斗，再通过 MCP connect 获取控制。修复前 MCP 报告 `remote`，助手却仍继续行动：行动次数从 1 增至 4，世界时间从 32 增至 65。

现在提供两种明确的连接意图：

| `tome.connect` 参数 | 行为 |
| --- | --- |
| `{"mode":"observe"}` | 只认证，不生成控制 token，不停止助手；可以 observe / inspect / status，拒绝 act / stop |
| `{"mode":"control"}` 或缺省参数 | 先暂停助手、使助手队列失效，再生成远程 token；等待原生 ready 边界后操作 |

快照可选字段 `battle_companion` 提供已有状态、行动次数和暂停原因。助手运行时 `control` 为 `battle_companion`，`phase` 为 `unavailable`；它只表示当前的动作归属，不代表游戏故障。摘要不执行危险评估、技能预检或随机判定。

助手在开始、调度和排队执行前检查 MCP 是否持有控制或有未完成动作，避免依赖 addon 加载顺序。模块只查询已加载的可选对端，不增加强制 MCP 依赖。停机、断线、降为旁观、保存和读档均不重启之前的自动战斗。

内部协议仍为 v1，但旁观使用独立 `connect_observer` 操作；旧 Bridge 会拒绝它，不会忽略参数后意外取得控制。客户端不能自动回退到 control 模式。

## 实现与验证

- [Controller](../../../../game/addons/tome-battle-companion/overload/mod/battle_companion/Controller.lua)：纯读取摘要、远程接管、执行前控制检查；中文暂停说明同步更新。
- [Runtime](../overload/mod/mcp_bridge/Runtime.lua)：认证模式、只读写入拒绝、控制交接与快照所有者。
- [Python server](../server/src/tome_mcp/server.py) 和 [TCP client](../server/src/tome_mcp/bridge.py)：模式 schema、独立握手操作、无自动回退。
- [原生 MCP 驱动](../../../../game/addons/tome-battle-companion/tests/native/mcp_control.py)：官方 SDK stdio 到真实游戏，真实键盘触发本地助手和保存；fixture 只布置场景并记录调用。

| 已完成检查 | 结果 |
| --- | --- |
| 三插件源码与正式包组合 | 各 35/35 项 |
| 新 MCP 包的完整原生验收 | 92/92 项 |
| 助手、Danger Alert、Bridge Lua | 486、1,540、135 条断言 |
| Python client / schema / SDK | 16 个测试 |

组合验证包含只读持续观察真实攻击、双方交接后至少 650 毫秒无多余行动、原生等待消耗 1,000 能量、重复命令不重复执行、键盘菜单接管、保存新角色及重载其副本。源码与包各有 36 次观察纯度检查，没有 RNG、感知判定或技能预检调用。重载后状态 idle、行动数 0、既有偏好保留，原存档和副本的哈希不变。

首次修复验证中，测试把可选 `message` 字段也当作必须不存在，导致读档断言误报；两次 MCP 快照实际完全一致且为 idle/0。修正断言后，最终源码与包验证全部通过。

证据和 SHA-256 位于 [validation/2026-09-15](../../../../game/addons/tome-battle-companion/validation/2026-09-15/sha256.json)。完整交互记录、冻结候选和日志保留在 `tmp/tome-mcp-validation/sessions/companion-control-{before-01,after-02,package-01}/` 与 `mcp-control-release-01/`。复现命令见 [原生说明](../../../../game/addons/tome-battle-companion/tests/native/README.md)。

## 交付与范围

- [Battle Companion 0.1.1](../../../../game/addons/tome-battle-companion/dist/tome-battle-companion.teaa)
- [MCP Bridge 0.2.0](../dist/tome-mcp-bridge.teaa)，配合 [Python 服务](../server/README.md)
- [Danger Alert 1.3.1](../../../../game/addons/tome-battle-companion/dist/tome-danger-alert.teaa)，生产代码与上一版一致

全部使用 Linux + Xvfb 的隔离新角色，未使用用户存档。本轮解决控制交接与旁观能力；技能清单、风险规则和当前战斗的范围保持既有实现。未新增完整战役、后台最小化、多段目标或所有第三方插件组合的证据。
