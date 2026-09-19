# Harness — MCP bridge play-test rig

This directory archives the development/test harness used to exercise the
production bridge in a real game: an isolated ToME 1.7.6 instance, a FIFO-driven
console, session wrappers and the reports/prompts from each play-test round.

Raw session data (per-session `home/`, `runtime/`, `play-mcp.jsonl`, logs, saves)
lives under `/workspace/t-engine4/tmp/tome-mcp-validation/sessions/<name>/` and is
**not** committed. The files here are the reusable rig plus curated artifacts.

## Layout

| Path | Contents |
| --- | --- |
| `console/agent-play.py` | The play console: starts the isolated game via `tests/native/runtime.py`, talks to the MCP server over stdio, and exposes a line-based JSON command channel. |
| `console/send.sh` | Writes one JSON command to a session FIFO and prints the matching reply (correlated by `__rid`). Requires `TOME_AGENT_SESSION`. |
| `console/tome.sh` | Compact wrapper over `send.sh` for gameplay: drops map rows, emits incremental events, strips ToME colour markup. |
| `console/map.sh`, `console/mapjson.sh` | Map views derived from `tome.observe`'s window. |
| `prompts/agent-prompt.md` | Generic play-agent prompt (interface, command shapes, safety rules). |
| `prompts/agent-insane20-prompt.md` | Latest round prompt; embeds the Anorithil guide appendix. |
| `guides/anorithil-guide.md` | Halfling / Celestial-Anorithil Insane playbook (source-verified talent data). |
| `reviews/review-explored-map.md` | Review of the explored-level-map proposal (`tome.map`). |
| `reviews/review-auto-combat.md` | Review of the AI auto-combat integration proposal. |
| `reviews/*-prompt.md` | The prompts handed to the reviewer sub-agents. |
| `reports/agent-*-report.md` | Per-round feedback reports (the raw JSON evidence stays in the session dir). |

## Running a session

Requirements: a runnable ToME 1.7.6 runtime (the workspace uses
`tmp/battle-companion-validation-20260914/runtime`), the Xvfb/X11 deps under
`tmp/worktrees/.../deps/root/usr`, and a Python venv with the MCP SDK
(`tmp/tome-mcp-venv`).

```bash
cd /workspace/t-engine4
N=agent-ham-insane-20
rm -f tmp/mcp-play-support/$N.cmd tmp/mcp-play-support/$N.log
mkfifo tmp/mcp-play-support/$N.cmd
setsid bash -c "cd /workspace/t-engine4; export TOME_BIRTH_ADDON=mcp-play-birth-hai; \
  tail -f /dev/null > tmp/mcp-play-support/$N.cmd & \
  exec tmp/tome-mcp-venv/bin/python tmp/mcp-play-support/agent-play.py $N \
    < tmp/mcp-play-support/$N.cmd >> tmp/mcp-play-support/$N.log 2>&1" < /dev/null > /dev/null 2>&1 &
```

Then create a session wrapper and drive the game:

```bash
cat > /tmp/tome-$N.sh <<EOF
#!/usr/bin/env bash
export TOME_AGENT_SESSION=$N
exec /workspace/t-engine4/tmp/mcp-play-support/tome.sh "\$@"
EOF
chmod +x /tmp/tome-$N.sh
/tmp/tome-$N.sh '{"observe":true}'
/tmp/tome-$N.sh '{"action":{"type":"wait"}}'
```

## Watching the game

The game runs headless on a per-session Xvfb display (see
`tmp/tome-mcp-validation/sessions/<name>/input.json`). To watch it:

```bash
sudo apt-get install -y x11vnc xdotool
DISPLAY=:140 xdotool search --name "Tales of Maj'Eyal" windowmove 0 0   # window at origin
x11vnc -display :140 -forever -shared -nopw -rfbport 5900
```

Connect a VNC viewer to `127.0.0.1:5900` (or bridge `podman exec` from the host);
`5901` can serve the same display for a second viewer.

## Rendering profile（低画质档，2026-09-18 起默认）

无 GPU 的 headless 环境里 LÖVE 回退到 Mesa `llvmpipe`，会按核数并行光栅化整帧——**空闲也持续
占 ~370–400% CPU**。因此 `tests/native/runtime.py` 现在默认写入**低画质渲染档**（唯一 settings 来源）：

| 项 | 值 | 说明 |
| --- | --- | --- |
| `display_fps` | 30 → **10** | 帧率降低 ⇒ 每帧成本 ×1/3 |
| `fbo_active` / `shaders_active` | **false** | 关闭整屏后处理与 shader |
| `particles_density` | **5** | 粒子大幅减少 |
| `aa_text` | **false** | 关闭文字抗锯齿 |
| `window` | **保持 1920×1080** | **刻意不改**：ToME 的 FOV/可见格集由视口尺寸决定，改分辨率会改变观测几何、破坏与历史原生/实机结果的可比性 |
| `background_saves` | **不动** | 关掉它会让引擎自身 `savefilepipe` 协程报 `cannot resume dead coroutine`，而 runner 把该串计为 Lua 错误 ⇒ 每次 probe 都会因无关原因失败 |

实测：单会话 **375% → 78%（约 −79%）**；已验证 **probe 173/173（source+dist）** 与
**原生验收 101/101（source+dist）** 全部通过（即观测结果不变）。
需要复现历史全画质档时：`TOME_MCP_LOW_QUALITY=0`。

## Teardown（强制流程：会话用后必须回收）

一场实机/原生会话结束后（**报告落盘即算结束**），由**派发方（开发对话）**立刻回收，`[Test]`
代理无权也不得代劳。原因是无头 Xvfb 下 ToME 渲染不节流：一个被遗忘的会话会持续占用
**200–360% CPU**（实测 3 个残留会话 ≈ 900% CPU，16 核机器 load 冲到 30）。

```bash
# 列出还活着的会话及其 CPU
/workspace/t-engine4/game/addons/tome-mcp-bridge/harness/console/reap-session.sh --list

# 默认：杀整个进程组（agent-play.py + t-engine + Xvfb + tome_mcp），并删除该会话 FIFO
.../harness/console/reap-session.sh <session>

# 需要保留现场继续取证：先暂停（CPU≈0），取证后再杀
.../harness/console/reap-session.sh <session> --stop
.../harness/console/reap-session.sh <session> --cont
.../harness/console/reap-session.sh <session>

# 清场：回收所有存活会话
.../harness/console/reap-session.sh --all
```

证据文件（`game.log`、`play-mcp.jsonl`、`result.json`、控制台 `.log`）**从不删除**，只移除 FIFO。
派发下一位代理前先 `--list`，确认没有残留会话在烧 CPU。

## Command channel (summary)

- `{}` / `{"observe":true}` — snapshot; `{"observe":{"sections":["player"]}}` trims domains.
- `{"action":{"type":...}}` — `move` (direction), `wait`, `attack`, `use_talent` (+`target_id`/`x,y`),
  `set_sustain` (+`enabled`), `use_item`, `pickup` (+`item_id`), `equip`/`unequip`, `rest`,
  `auto_explore`, `change_level`, `spend_stat`, `learn_talent`, `learn_category`.
- `{"respond":{...}}` — answer a command-owned interaction; `{"dismiss":{...}}` — answer a session popup.
- `{"status":true|"<cmd-id>","compact":true}` — direct command query.
- `{"inspect":{...}}`, `{"list":{...}}`, `{"map":true}`, `{"mapfull":true}`, `{"sheet":true}`,
  `{"connect":"control"}`, `{"stop":true}`, `{"abandon":true}`, `{"key":"..."}`, `{"walk":[...]}`,
  `{"bench":N}`, `{"quit":true}`.

## Notes

- `send.sh` fails fast when `TOME_AGENT_SESSION` is unset, so a bare call can
  never target the wrong session.
- Each session is isolated (own home, display, TCP port); the harness never
  touches user saves.
- The reports are feedback snapshots; the accompanying raw `play-mcp.jsonl`
  evidence is intentionally kept out of the repository.
