# AGENTS.md

## 项目背景

ToME MCP Bridge 把 ToME 1.7.6（T-Engine）接入 MCP，让 LLM / Agent 以**玩家视角**读取游戏状态，并执行**经过原生结算**的游戏动作。它由两个组件组成：

- **游戏内 Lua addon**（本仓库根目录）：随游戏加载，负责观察和执行。
- **外部 Python MCP server**（`server/`）：实现 MCP 协议，监听 stdio。

两者通过 `127.0.0.1` 上的非阻塞 TCP + 行分隔 JSON（当前协议 v3）通信。

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
