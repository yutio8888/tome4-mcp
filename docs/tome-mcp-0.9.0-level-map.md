# `tome.map` — explored level map (0.9.0)

Status: implemented on `feat/0.9.0-reliability` (internal protocol v4, additive
capability-gated operation `level_map`).

## Why

The player can open the level map and see every explored cell, but MCP only
exposed a player-centred window (`observe.radius` 1..12, `known` = bridge-session
memory). `tome.map` adds the missing player-visible capability.

## Semantics (native_map, mirrors the map UI)

Source of truth is the game's own map memory:

- `remembered = map.remembers[index]` (persistent display gate),
- plus the existing safe visibility predicate (`Observer.terrainVisible`: FOV +
  light/actor guard + audited wilderness branch).

Terrain under a remembered cell is the **current** native terrain: opening a
door changes the cell immediately (`Map:call` → `updateMap`), and the map draws
the new terrain even if the player did not witness it. `seens` is transient and
is set by ESP/detection, so it never authorizes terrain by itself.

Overlays follow the native renderer:

- identified traps (`trap.all_know or trap.known_by[player]`) are drawn;
- items (`Object.display_on_remember=true`, blue on the minimap) are drawn;
- out-of-sight actors are **not** drawn (`Actor.display_on_remember=false`).

Persistence is free: `Map:save` serializes `remembers` (only `_map`, `_fovcache`,
… are excluded), so the explored map survives save/reload without bridge-side
files. `bridge_observed` (bridge session memory) is intentionally not part of the
MVP; the game save already provides file-level persistence for `native_map`.

## Alphabet (normalized; priority exit > door > trap > item > blocked/passable/unknown)

| Char | Meaning |
| --- | --- |
| `?` | unknown or not authorized (not remembered and not safely visible) |
| `.` | passable terrain |
| `#` | blocked terrain |
| `+` | known door |
| `>` | known exit (visible change level/zone label) |
| `:` | terrain whose static block status is unknown |
| `%` | item on the cell |
| `!` | identified trap |

## API

`tome.map(session_id, source="native_map", format="rows"|"region", region={x,y,width,height})`

- `format=rows` (default): `{w,h,origin,player,explored_count,legend,rows:[{y,x_start,text}],coverage,capture_complete,truncated?,truncation_reason?,omitted_rows?}`.
- `format=region`: at most 64 cells with the existing `Details.terrain`
  projection plus `remembered`/`visible`/`known_trap`/`item`.

Limits: vanilla maximum is sandworm-lair 350×50 = 17,500 cells (wilderness
170×100 = 17,000; towns 196×80 = 15,680). A larger (modded) map is returned as a
player-centred band and marked `truncated=true` with `truncation_reason` and
`coverage` (option B), never silently dropped.

## Decisions

1. Player-visible = native map rendering (`native_map`), with terrain detail
   gated by `remembered OR safe-visible`.
2. Include terrain + identified traps + items; exclude out-of-sight actors.
3. File-level persistence: provided by the game save for `native_map`
   (`bridge_observed` deferred).
4. Internal self-test phase: v4 accepts the additive capability-gated op.
5. Cap = vanilla maximum; over-cap returns a truncated band (option B).
6. Detailed terrain = bounded rectangle (≤64 cells).
7. Normalized alphabet + this legend table.

## Tests

`tests/test_level_map.lua` (22 checks): remembered vs unknown, ESP-only `seens`
guard, safe visibility, known/unknown trap, item, actor exclusion, alphabet
priority, cap/truncation, region bounds. Server test covers `tome.map` over the
SDK. See also the reviewer report `tmp/mcp-play-support/review-explored-map.md`.
