# MCP 首版之后：自动战斗插件开发交接

日期：2026-09-15。工作区：`/workspace/t-engine4`。首版验收已完成：Lua 120 项、Python 14 个测试通过；真实游戏源码与安装包分别通过 92/92 项（`native-06`、`package-01`）。

验收完成后已通过 Paseo 向已有独立 agent `c5c1aed2-49b7-4d8c-92b2-143184e27c6c`（`gpt-6-astra`、xhigh，原自动战斗插件开发会话）发送本任务和完整背景；Paseo 返回发送成功。后续开发由该 agent 继续，本记录不代表后续改进已经完成。

## 用户要求

用户要求在完成 MCP 首版验收之后，通过 Paseo 找另一位独立 GPT-6 agent，告知当前进展，并请其**使用这个 MCP 继续开发自动战斗插件**。接手后应实际实现和验证改进，不止提出方案。

## 已交付的基础

- [MCP addon 和安装说明](../README.md)：独立的游戏内 Lua addon，本机非阻塞 TCP。
- [外部 MCP server](../server/README.md)：Python 3.11+，官方 `mcp==2.2.0` SDK，stdio 服务；工作区已安装到 `tmp/tome-mcp-venv`。
- [v1 契约](tome-mcp-v1-contract.md)：`tome.connect`、`tome.observe`、`tome.inspect`、`tome.act`、`tome.status`、`tome.stop` 和 `tome://rules`。
- 支持八方向移动、等待、相邻普通攻击、原生 Lightning / Arcane Reconstruction / Adrenaline Surge。技能必须已学习且符合来源检查；其余技能和复杂 UI 仍需扩展。
- [首版验收记录](../VALIDATION.md)与[独立审阅记录](tome-mcp-review.md)给出实际证据和限制。生产包 `game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa` 的 SHA-256 为 `023f67a1b5762e9c1acba858b5ed0bdac3b68e2669e54ed0aaeace09b91bff1a`；证据目录 `tmp/tome-mcp-validation/sessions/package-01/`。

## 接手后的工作

1. 阅读现有 [Battle Companion README](../../../../game/addons/tome-battle-companion/README.md)、[架构](../../../../game/addons/tome-battle-companion/ARCHITECTURE.md)与[验收记录](../../../../game/addons/tome-battle-companion/VALIDATION.md)，确认它和 Danger Alert 的当前实现。`documentation/auto-talent-assistant-optimization.md` 是更早的旧插件分析，不能代替当前 Battle Companion 代码。
2. 先用真实 MCP stdio 调用建立一次观察 → 决策 → 原生动作 → 结果查询的闭环，熟悉能力与限制，再选择一个有实际收益的自动战斗改进并实施。
3. 复现问题、验证修复和评估战斗行为时使用 MCP。必要的测试场景布置可沿用隔离 probe；不要把绕过 MCP 的调试 Lua 动作当成 MCP 验收证据。
4. MCP 若缺少继续开发所必需的技能/观察能力，可增量适配；每项新增动作须沿用原生入口，并验证资源、能量、冷却、敌方回合、失败和接管。保持一个控制来源，明确处理 Battle Companion 与 MCP 的控制权。
5. 运行受影响插件的回归及真实游戏 MCP 场景，记录修改、证据、适用范围和剩余问题，向用户报告。

## 在本工作区启动真实 MCP

现有可运行 ToME 安装在 `tmp/battle-companion-validation-20260914/runtime`；仓库根的 `t-engine` 与当前系统 glibc 不兼容。复用隔离运行器会复制可执行程序和 addon，并为每次运行创建独立 HOME、端口、Xvfb、新测试角色。

完整验收命令（使用新的运行名）：

```sh
python3 game/addons/tome-mcp-bridge/tests/native/run.py mcp-handoff-01 \
  --mcp-python ../../../../tmp/tome-mcp-venv/bin/python
```

交互实验可在 Python 中把 `game/addons/tome-mcp-bridge/tests/native` 加入 `sys.path`，使用 `runtime.Runtime(name, DEFAULT_SOURCE, DEFAULT_DEPS)`，调用 `start()`、`wait_ready()`。运行期间读取该实例的 `port`、`token`，构造官方 SDK `StdioServerParameters`：

```python
StdioServerParameters(
    command="../../../../tmp/tome-mcp-venv/bin/python",
    args=["-m", "tome_mcp"],
    env={
        **os.environ,
        "PYTHONPATH": "../../../../tools/tome-mcp-server/src",
        "TOME_MCP_PORT": str(runtime_instance.port),
        "TOME_MCP_TOKEN": runtime_instance.token,
    },
)
```

使用 `from mcp import Client, StdioServerParameters`，在 `async with Client(params)` 中调用工具。每次结果检查 `structured_content["ok"]`，业务数据位于 `structured_content["result"]`。可直接参考 [mcp_smoke.py](../tests/native/mcp_smoke.py)，它覆盖六个工具、规则资源和真实等待动作。收尾在 `finally` 调用 `runtime_instance.close()`。虚拟环境的 Python 路径不要调用 `Path.resolve()`，否则会解引用到没有 SDK 的系统解释器。

运行器当前只安装 MCP bridge 和测试 probe。若验证 Battle Companion / Danger Alert 的组合，应显式将需要的 addon 加到新的隔离候选中，保持记录可复现。

## 必须保留的行为

- 使用玩家视角信息；只读观察不调用 RNG、`canSee`、技能预检或动态说明函数。缓存缺失的普通视觉分支有严格来源检查，未知时保守省略。
- 一次只提交一个动作，使用当前 `session_id` / `control_token` / `revision` 与唯一 `command_id`。超时只查询原命令，不能换 ID 重试。
- 手动输入撤销控制并继续原生操作；stop 取消未执行工作。保存、切图、读档不能恢复旧自动动作。
- runtime/socket/队列不进入存档。TCP 重连保留游戏 session，重新加载创建新 session。
- 不将首版支持范围描述为任意职业、全流程或全平台已通过。
- 使用隔离测试角色；保留用户存档和其他工作区。该仓库原本已有多处未跟踪/未提交内容，不要清理、覆盖或提交与当前任务无关的文件。
- 按用户约定假定联网可用；本版 TCP 链路无需增加禁网后备路径。

## 本轮解决的问题

- 普通攻击经过原生 `T_ATTACK`，保留原生限制和替代攻击语义。
- 原生回合清空可见性缓存时，对满足严格条件的普通可见角色使用无随机副作用的判断。
- 输入包装同时覆盖游戏和当前对话框；读取旧客户端 EOF 后再接受重连，避免快速重连竞态。
- 原生异常不会误报动作成功；tick/保存/切图状态正确退出，写操作隔离到新游戏会话。
- 去重标识有界保留；达到上限拒绝新动作，历史快照最多保留最近 16 项，避免保存整个旧场景。

## 接手验收标准

- 已实际通过 MCP 操作隔离真实游戏并保存证据。
- 自动战斗插件至少一项有明确价值的改进完成实现和验证。
- 原生结算、手动接管、保存重载和已有配置行为未被破坏。
- 新能力、安装方式、限制及复现步骤有更新后的文档。
