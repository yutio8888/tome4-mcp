# AGENTS.md

## 项目背景

ToME MCP Bridge 把 ToME 1.7.6（T-Engine）接入 MCP，让 LLM / Agent 以**玩家视角**读取游戏状态，并执行**经过原生结算**的游戏动作。它由两个组件组成：

- **游戏内 Lua addon**（本仓库根目录）：随游戏加载，负责观察和执行。
- **外部 Python MCP server**（`server/`）：实现 MCP 协议，监听 stdio。

两者通过 `127.0.0.1` 上的非阻塞 TCP + 行分隔 JSON（当前协议 v4）通信。

## 目录速览

| 路径 | 内容 |
| --- | --- |
| `init.lua`, `hooks/`, `overload/`, `superload/` | 游戏 addon（`overload/mod/mcp_bridge/` 是核心 Lua 模块） |
| `server/` | Python MCP server（`bridge.py` 传输、`server.py` 工具与 schema） |
| `tests/` | Lua 单元测试与集成驱动 |
| `tools/` | `generate_native_seams.py`（生成 superload）、`package.py`（打包 `.teaa`） |
| `docs/` | 架构、契约、字段清单与各版本设计文档 |
| `validation/` | 按日期归档的验收证据与生成包 |

核心模块说明见 `docs/tome-mcp-architecture.md`，接口字段见 `docs/tome-mcp-api-fields.md`，验收结果见 `VALIDATION.md`。

## 重要约定

- **不修改游戏核心**。所有介入只通过 addon 的 hooks / superload / overload 缝隙完成。
- **`superload/` 下标注 `GENERATED ... do not edit by hand` 的文件由 `tools/generate_native_seams.py` 生成**，不要手改；源码哈希由 `NativeCompatibility` 在运行时校验。
- **观察不改变游戏状态**：读操作不得触发 RNG、推进回合或产生副作用；只暴露玩家已知信息。
- **写操作严格串行且只走原生入口**：不按技能 ID 写死脚本；未适配的界面返回 `needs_input` 交给玩家。
- **运行态不进存档**：socket、命令队列、协程引用、控制租约只保留在内存。
- 改动协议字段或新增能力时，同步更新 `server/`、`docs/` 与测试。

## 常用命令

```sh
# Lua 单元测试
bash tests/run.sh

# Python 测试
PYTHONPATH=server/src server/.venv/bin/python -m unittest discover -s server/tests -v

# 重新生成原生缝隙（改动了 superload 相关逻辑时）
python3 tools/generate_native_seams.py

# 打包正式 addon（会先校验生成的 superload 是否为最新）
python3 tools/package.py
```

游戏安装、配置与 MCP 客户端接入方式见 `README.md`。

## 开发对话与测试对话（反馈循环）

本项目用两个角色反复迭代，**不要混用**：

- **开发对话（拥有仓库/MCP 实现的这方）**：负责启动游戏、评审反馈、修改代码、跑单测、打包、重启测试、归档测试对话。
- **测试对话（每轮由开发对话通过 Paseo CLI 启动的 agent）**：**只负责实机游玩与反馈**；不得修改仓库/游戏文件，不得重启或 kill 进程。

### 一轮循环

1. 开发对话启动隔离游戏 + FIFO 控制台（`tmp/mcp-play-support/agent-play.py`，会话名如 `agent-ham-insane-02`），用 v4 出生插件创建目标角色（如 半身人/星月术士/Insane）。
2. 开发对话用 Paseo CLI 启动测试对话：
   `paseo run -d --provider pi --model commandcode/deepseek/deepseek-v4.1-flash --thinking high --cwd /workspace/t-engine4 --title "ToME4 MCP play roundN…" "$(cat tmp/mcp-play-support/agent-insaneN-prompt.md)"`
   prompt 里给出会话专用接口 `tome-insaneN.sh` / `map-insaneN.sh`、目标与反馈要求。
3. 测试对话通过控制台游玩；在**死亡 / 长时间卡住 / 完成**时：
   - `paseo send <开发对话 agent id> "<一句话结论>"` 通知开发对话；
   - 写报告到 `tmp/mcp-play-support/agent-<session>-report.md`（最终状态、经过、技能/物品、**MCP 问题 + 原始 JSON 证据**）。
4. 开发对话：收集报告 → 实现修复 + 新增/更新单测 → 提交推送（开发分支经 PR 评审）→ **确认本轮反馈的所有问题都已处理（已实现/已测试/已提交，未修项已记入 TODO 并说明）后，才 `tools/package.py` 重建并重启新一局** → 启动新测试对话 → **归档上一轮测试对话**。

> **顺序约束（重要）**：不得在处理完当前反馈前重启。每轮必须先把该轮报告的问题处理到“已修且有证据/单测”或“明确记入待办并说明原因”，然后再停止游戏、重建、重启下一轮。

### 边界与约定

- 测试对话只通过 `tome-insaneN.sh` / `map-insaneN.sh` / `send.sh` 交互；不写代码、不改 addon、不 `kill`/`quit` 游戏。
- 开发对话不替测试对话长时间游玩；用 `paseo ls` / `paseo send` / 报告文件收集反馈。
- 每轮修复必须落成文档（如 `docs/tome-mcp-0.9.0-round*-feedback.md`）并新增/更新单测；未修项记入 `docs/tome-mcp-0.9.0-todo-*.md`。
- 每轮结束，开发对话主动 `paseo archive <测试对话 id>`。


## 代理派发原则（独立上下文，必须遵守）

- **测试、开发、审核必须使用彼此独立的代理，禁止混用上下文。** 一个代理只承担一种
  角色：不得让测试代理改代码、开发代理扮演审核、或审核代理延续实现者的假设。
- **审核（Review）每轮都必须使用全新代理**，以保证独立视角，不受上一轮实现细节影响。
- **唯一例外**：当本轮工作就是"修复/回应上一轮审核发现的问题"时，可以**复用上一轮的
  那个审核代理**来做复核（只有它持有该轮问题与证据的上下文）。
- 派发时在 agent 标题与简报里标注角色前缀（`[Dev]` / `[Test]` / `[Review]`），并在简报中
  明确"不得越过角色边界"。
- 开发对话（拥有仓库的这方）负责：派发、验收、合并、打包、归档；**不代替审核**——审核
  结论必须来自独立的审核代理。
- 角色与产物：
  - `[Dev]`：改仓库代码/文档 + 单测 + 打包；交付分支/PR。
  - `[Test]`：只游玩/实测与反馈，不改文件、不 kill 进程。
  - `[Review]`：只读，只出问题清单（P0–P3 + 证据）；不改代码。
