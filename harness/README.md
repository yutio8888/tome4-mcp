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
