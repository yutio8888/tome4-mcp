# Ordinary campaign MCP acceptance

This runner resumes a **copy** of the recorded non-cheat Cornac Berserker at
the Trollmire 1 exit. It uses the official MCP Python SDK and the real stdio
server for every gameplay action. It adds no gameplay probe, actors, items,
skills, attributes, damage, healing, or temporary effects.

The preserved `mcp-play-birth` addon is required by the saved addon list. Its
birth hook does not run when loading this existing character. Battle Companion
and Danger Alert are copied from the original trial's frozen runtime; Battle
Companion must remain idle while MCP owns the actions.

## Run

From the repository root, using the Python environment for the MCP server:

```sh
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/campaign/run.py campaign-source-01

tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/campaign/run.py campaign-package-01 \
  --addon-archive game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa
```

Each session name must be new. The default source is
`tmp/tome-mcp-validation/sessions/campaign-play-01`; use `--source-session` for
another preserved copy with the same test character. `--preflight-only` checks
loading and observation without issuing gameplay actions. `--max-actions`
bounds exploration and combat after the initial level transition (default 300).

The loader reuses the native runtime utilities without changing them. It creates
its own runtime, Xvfb display, home and TCP port, then removes the debug native
probe before starting the game. Only connection settings change in the copied
home. The original save's SHA-256 values are frozen and checked again after
cleanup. Existing sessions and the original trial evidence are never rewritten.

## Assertions

1. The ordinary saved character retains its position, life and birth talents;
   observation does not advance it and Battle Companion stays idle. Original
   equipment and unspent birth points are observable; compact observation omits
   the map without changing native state.
2. MCP `change_level` enters actual `scene.zone_id == "trollmire"`, `scene.level
   == 2`, changes `level_instance_id`, and releases control. An explicit connect
   permits a subsequent ordinary wait action.
3. Natural combat uses original Stunning Blow and Warshout with native stamina,
   energy and cooldown behavior. Warshout targets a visible actor to orient its
   cone.
4. Naturally received damage is treated with the original Healing and
   Regeneration infusions. Wild is verified as an instant defensive effect;
   cleansing a particular negative effect depends on what natural enemies do.
5. Bounded rest respects `max_turns`, advances the original world when work is
   needed, and an identical command ID cannot repeat the rest. Rest attempted
   with a naturally observed hostile stops at zero turns and returns the
   original native stop message. The policy uses a five-turn cap until that
   exact bound has been exercised, then allows recovery up to 150 turns.
6. The run ends after all five talent paths and real rest have been exercised,
   with no currently observed hostile, full life and stamina, and the required
   talents ready. Visible-hostile inspection returns native detail fields;
   incremental visible-log pages contain real combat messages without cursor
   gaps or duplicate events.

Navigation uses only accumulated MCP-known terrain, actual movement results,
and currently observed actors. It does not inspect hidden save objects, monster
lists, or the game's internal map. A conservative, bounded test policy controls
combat; this is not intended as a general campaign-playing agent.

`input.json` freezes source-save, supporting-addon, engine, driver, MCP-server
and candidate hashes. The stdio server runs from the session's copied Python
source. `campaign-mcp.jsonl` and `decisions.jsonl` record MCP calls and decisions
with control tokens redacted. `visible-log-events.jsonl` records incremental
player-visible log events. `result.json`, `observed.json`, `game.log`, and
`player-visible-combat.log` contain the final checks and evidence. A successful
preflight alone does not count as a passed campaign action suite.
