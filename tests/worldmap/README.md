# Native world-map observation acceptance

Run from the repository root with the installed MCP environment:

```sh
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/worldmap/run.py worldmap-new-name
```

Existing session names are rejected. The driver loads the current official
`dist/tome-mcp-bridge.teaa`, freezes Python source, and uses protocol 2 through
official MCP stdio. `runtime.py` extends the campaign source registry with the
published 0.5.0 and 0.6.0 continuations, checking their parent records, report
references, engine/supporting addons, and complete save hashes. The direct source
is **campaign-play-v060-02**, level 5 at World of Eyal `(28,13)`; its seven save
files include the archived Trollmire zone. This is not the original Lv3 save.

The game runs in a new home and runtime, without a gameplay probe or fixture,
cheats, injected talents/items, or hidden-map queries. It checks the initial
character and items against the published report. All navigation uses current
MCP observations: a visible passable adjacent step and return, a route to another
visible entrance, and a return to the previously visited Trollmire entrance.
Native `change_level` enters Trollmire and returns to the world. Unknown cells
must omit terrain names, blocking and exit information. Repeated reads must leave
the map, player and game turn unchanged. Closing and reopening the MCP process
exercises actual TCP disconnect/reconnect. Native Ctrl+S then saves this run;
a second home copies and reloads that save to verify state and world visibility.

The first attempt also entered Kor'Pul, which naturally triggered an unsupported
escort chat. It correctly retained `needs_input / scene_changed` with the new
scene already entered. That attempt remains as `worldmap-v061-01`; it was not
replayed or manually bypassed. The passing route uses the previously visited
Trollmire for the entry/exit FOV check. This suite does not claim support for
arbitrary native chats or completion of a campaign.

Separate **test fixtures** in `MCPVisibilityProbe.lua` exercise real native
`playerFOV`, `computeFOV`, `applyLite` and `applyESP`: exact wilderness visibility,
an unseen entrance, repeated read purity, modified-method refusal, and blindness
in both world and dungeon projections. These nine checks run with the v1 and v2
native suites. They are excluded from this ordinary campaign and the production
archive. Early fixture failures (ESP not enabled, then incorrectly restoring an
inherited function as a serialized player field) remain in their failed sessions;
both were corrected in test setup, without production changes.

Results, input manifests, frozen sources, MCP transcripts, game logs and both
saved homes remain under `tmp/tome-mcp-validation/sessions/<name>/`. Preserve
these and all original campaign sources. Start isolated native runtimes
sequentially: their Xvfb display selection is not reserved until startup creates
the socket, so simultaneous constructors can choose the same display.
