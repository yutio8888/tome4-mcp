# Ordinary growth and item acceptance

This suite loads an isolated copy of the documented level 3 Cornac Berserker
from `campaign-play-v030-01`. The character is at `(64,36)` in Trollmire 2,
with 162.225 life, 106 stamina, and 9 attribute / 5 class / 4 generic / 1 category
points. The source has no gameplay fixture and `cheat=false`.

## Source protection and preflight

```sh
python game/addons/tome-mcp-bridge/tests/growth/test_sources.py -v
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/growth/test_persistence.py -v

tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/growth/run.py growth-preflight-01 \
  --preflight-only \
  --addon-archive tmp/tome-mcp-validation/sessions/campaign-play-v030-01/runtime/game/addons/tome-mcp-bridge.teaa
```

Use a new session name for every invocation. The `--preflight-only` mode makes
no gameplay requests; it checks the actual loaded character and repeated
read-only observations through the official MCP SDK.

`campaign/runtime.py` binds both historical sessions to their published JSON
evidence. It checks all six save files exactly, freezes both source save sets,
and verifies both again after each run. The original level 1 copy argument
retains its meaning. A relocated level 3 copy additionally needs
`--source-record campaign-play-v030-01`; selecting a record cannot override
hash mismatches or bind an existing historical path to the other report.

The provenance unit tests mutate only synthetic files in temporary directories.
They cover incorrect lineage, conflicting reports, omitted/extra/tampered save
files, and accidental use of a level 3 source under the old level 1 check.

## Growth, natural items, and persistence

```sh
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/growth/run.py growth-source-final-01 \
  --category-mode unlock

tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/growth/run.py growth-package-final-01 \
  --category-mode mastery \
  --addon-archive game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa
```

The suite spends the saved character's existing points through native rules:
STR +5, CON +4; Stunning Blow and Warshout to raw level 3; Rush to 1; Heavy
Armour Training to 2; Vitality to 3. It checks unavailable prerequisites before
spending, all four exhausted pools, unknown IDs, duplicate commands, the native
learning cooldown on Rush, and unchanged cooldowns when upgrading known skills.
The original category point either unlocks `cunning/dirty` or improves
`technique/2hweapon-assault` mastery by 0.2. These two branches use separate
copies because the original character has one category point.

All attribute, skill, category, pickup, equip, and unequip operations must go
through the official MCP SDK. No skills, items, enemies, attributes, damage, or
recovery are injected. Natural items are found through MCP observations and
known terrain on the current level. If natural enemies appear, the existing
combat skills and infusions handle them. `--max-search-actions` bounds this
search (default 300 iterations). Distant pickup is rejected; an actual floor
item is picked up, equipped, removed, and equipped again, with native energy
and duplicate-command checks. Unidentified items retain their unknown fields
until ordinary game behavior identifies them.

The final persistence check may use native Ctrl+S solely to save. It reloads a
copy of that run's own new save, preserves the first saved copy, and compares
the resulting native growth and item state. Neither historical source is
overwritten. Reloading uses no gameplay probe or probe command-line flag. The
new native session rejects the old session ID. Save comparisons omit temporary
session/object IDs and allow only floating serialization roundoff (absolute
1e-9, relative 1e-12); discrete points, skill levels and item states remain
exact. Raw pre-save and reloaded snapshots are retained.

Each session records `input.json`, `result.json`, `campaign-mcp.jsonl`,
`decisions.jsonl`, `observed.json`, visible log events, and native logs. Python
server source, addon inputs, and harness source are frozen in that session.
The growth driver has a separate hash entry from the unchanged historical
campaign driver. `growth-before.json`, `growth-after.json`, `natural-item.json`,
`saved-state.json`, `reloaded-state.json`, and `reload-input.json` preserve the
growth, item transfer, native save and reload evidence.
