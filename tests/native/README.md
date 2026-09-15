# Native MCP acceptance

This suite starts a **new debug Cornac Berserker**, creates a dedicated arena,
and drives the production bridge over TCP. It then uses the official MCP Python
SDK to initialize the external stdio server and complete a native wait action.
The test-only `tome-mcp-probe` addon supplies fixtures and records original game
entrypoints, energy, resources, cooldowns, world ticks, and NPC actions.

Every run creates its own runtime and home under
`tmp/tome-mcp-validation/sessions/<name>`. Existing names are rejected. The engine
executable and tested addons are copied; immutable engine assets are hard linked
or copied across filesystems. Source installations, other test sessions, and user
saves are not changed. The initial character imports no save. The later reload
stage copies only the fresh character saved by this same test run. Networking
is enabled in this home.

## Requirements

- Runnable Linux ToME 1.7.6 installation with `t-engine`, `bootstrap/`, `game/`.
- LuaSocket built into that engine.
- Python 3.10+, Xvfb, X11/XTest libraries, software OpenGL, engine dependencies.
- A Python environment containing the external server dependencies, including
  the official `mcp` SDK version required by `server`.

From the repository root:

```sh
python3 game/addons/tome-mcp-bridge/tests/native/run.py native-01 \
  --source /path/to/runnable/tome \
  --deps /usr \
  --mcp-python /path/to/server-venv/bin/python
```

The defaults point to the existing read-only local test installation and
dependencies in this workspace and `tmp/tome-mcp-venv/bin/python`. A free X11
display in `:110`–`:199` and an ephemeral loopback TCP port are chosen per run.
All processes started by the runner are stopped during cleanup.

Pass `--addon-archive /path/to/tome-mcp-bridge.teaa` to run the same suite against
the actual archive loader. The test probe remains a separate sibling addon.
`input.json` records the release archive hash. To test a later development
change, invoke the runner again with a new session name; each run freezes a new
candidate and gives it a fresh character and its own game process.

## Checks

- Ordinary new character birth and ready snapshot over fragmented TCP.
- Multiple JSON messages in one TCP write; repeated observe/inspect preserve
  native position, life, mana, energy, cooldowns, world tick and action counters.
- Instrumented production observer calls no RNG, `canSee` or `preUseTalent`.
- Player-visible target inclusion and hidden native actor inspect rejection.
- Wait, move, instant Adrenaline Surge, Arcane Reconstruction, Lightning,
  ordinary melee; original resource/energy/cooldown and NPC scheduler behavior.
- Original command replay, conflicting command IDs and stale revisions.
- TCP disconnection followed by explicit reconnect/status, without replay.
- Batched queued action plus stop cancels before execution.
- Actual XTest keypress revokes the old control token; native Escape menu
  reports `needs_input` and prevents a world action.
- Official MCP initialize, list-tools, rules resource, all six tools, native
  wait completion at a ready snapshot, duplicate command and stop.
- Real Ctrl+S save, reload of a copy of this test's home, listener rebind to the
  same port, fresh session and command history, rejection of the old session,
  no automatic action after reload, and a new wait action after reconnect.
- Hashes prove neither the original nor copied fixture save was rewritten by
  loading it. Diagnostic wrappers live on classes rather than saved instances.

`input.json` and `candidate.zip` freeze the engine hash and addon candidate.
`result.json`, `wire.json`, `game.log`, `reload.log`, `mcp.log` and `xvfb.log`
retain evidence. `reload-input.json` records the exact restart command.
The initial test secret is redacted from `wire.json`; runtime settings and all
test-session files are local artifacts, not release files.

## Scope of the evidence

For the optional Battle Companion combination, run
`tmp/tome-mcp-venv/bin/python game/addons/tome-battle-companion/tests/native/mcp_control.py <new-name>`
from the repository root. Add `--packages` to load all three release archives.
This adds official MCP observer/control switching and real local combat checks;
see the [combination runner](../../../tome-battle-companion/tests/native/README.md).
The shared `Runtime` accepts an explicit `extra_addons` mapping and records and
freezes those additional inputs with the base candidate.

These are controlled native fixtures, not a full campaign or every supported
platform. Real window minimization/background throttling, campaign level
changes, multi-stage talent interactions and all other addons require additional
native scenarios. The probe changes test stats, learns original talents and
wraps methods for diagnostics; it does not replace their game-rule bodies.
Unit and state-machine tests complement these checks and are not substitutes
for native engine evidence.
