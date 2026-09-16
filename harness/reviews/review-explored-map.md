# Review: explored-level map capability

## Verdict

The factual finding is **correct in substance**: MCP does not currently expose the full explored map of the current level. It exposes only a player-centred window, at most 25x25 cells, and `known` is bridge-session memory rather than native map memory. There is no hidden equivalent in `tome.list`, target interactions, world-map handling, ground items, or the frozen observation views.

The finding is slightly incomplete about surfaces: `connect` also returns a bounded snapshot; `respond` and `dismiss` can return one when `include_map=true`; `stop`/`abandon` return snapshots as well. None changes the conclusion because every such snapshot uses the same `Observer.capture` window.

I recommend **adding the feature as an explicit, opt-in read tool**, but not exactly in the proposed shape. A compact, paged row representation of audited terrain is a useful player-equivalent capability for an LLM and does not belong in every `observe`/`act` snapshot. The initial version should expose the native explored terrain layer only. The bridge-session layer is already reconstructible by merging existing windows and can be added later if there is a demonstrated use case.

The proposal's central premise needs qualification: `map.seens` and `map.remembers` participate in what the native map renders, but they are not interchangeable forms of "explored memory" and they are not authorization to serialize every field at those coordinates. `seens` is transient and is also set by ESP/detection paths; `remembers` is a persistent display bit, not a saved copy of the old terrain. Exact native-map equivalence and the bridge's older conservative knowledge policy are different policies. The author must choose and document which policy this feature adopts.

## Verification of the current capability

- `Observer.capture` clamps radius to 12, computes bounds around `player.x/player.y`, and iterates only those bounds (`overload/mod/mcp_bridge/Observer.lua:96-167`). The result explicitly says outside cells are omitted (`Observer.lua:164-166`).
- The map's `width` and `height` are the **window** dimensions, not level dimensions (`Observer.lua:161-166`). Native `map.w`/`map.h` are used only to clip the window (`Observer.lua:127-128`).
- Bridge memory is the weak-keyed `memories[map]` table, populated only when this observer accepts a currently visible terrain cell (`Observer.lua:9, 30, 129-153`). No code enumerates that memory outside the requested window.
- The request schema caps `observe.radius` at 12 (`protocol/v4/requests.schema.json:34-44`).
- The only collections are inventory, equipment, actors, talents, effects, ground items, progression categories/talents, and compatibility (`overload/mod/mcp_bridge/ObservationCollections.lua:14-24, 41-47`; `protocol/v4/requests.schema.json:59-92`; `server/src/tome_mcp/server.py:153-166`). `ground_items` is still radius-bounded and is not map memory (`ObservationCollections.lua:92-94`).
- `ObservationViews` can page only a collection that has already been projected and handed to it; it does not provide spatial queries or discover map cells (`overload/mod/mcp_bridge/ObservationViews.lua:71-79, 129-159`).
- Target interactions expose an origin, range/radius, visible candidate actor IDs, and the selected coordinate, not an explored terrain view (`overload/mod/mcp_bridge/Interactions.lua:53-61, 338-383`).
- World-map support is a special audited visibility predicate for the same bounded window, not a full world map (`Observer.lua:14-23, 130-143`; `tests/worldmap/README.md:17-39`).
- The Python rules explicitly define `known` as bridge-session observation and state that native memory is not imported (`server/src/tome_mcp/server.py:277-286`).

Therefore there is no existing API combination that returns the native explored level. A client can accumulate windows as the player moves, but it cannot recover native exploration from before the bridge session or request an arbitrary off-centre window.

## Issues and risks

### High: `seens`/`remembers` are display gates, not equivalent knowledge snapshots

`seens` is cleared and recomputed with FOV (`engine/Map.lua:459-465`; `mod/class/Player.lua:550-565`). It is also set for ESP, actor/object/trap detection, Arcane Eye, marked prey, and other non-terrain senses (`Player.lua:563-705`). `Map:applyESP` marks a sensed actor's cell as seen without setting persistent terrain memory (`engine/Map.lua:688-697`). This is exactly why the current observer requires FOV/light guards and tests that ESP does not reveal terrain (`Observer.lua:138-147`; `tests/test_observer.lua:135-143`).

`remembers`, by contrast, is the native renderer's persistent remembered-display bit. It may be set by ordinary lit sight, `always_remember`, detection, map scripts, or `all_remembered` levels (`engine/Map.lua:647-685, 825-830`; `engine/Zone.lua:1069`). It stores no historical terrain projection. If terrain changes while out of sight, reading `map.map[index][TERRAIN]` returns the current backend terrain, not the terrain as last seen.

The native full-map dialog renders the minimap (`mod/dialogs/ShowMap.lua:34-55, 102-109`). The C minimap draws each map object according to its own `on_seen`/`on_remember` flags and the current `seens`/`remembers` gates (`src/map.c:2031-2062`). Terrain is configured for seen and remembered display, while actors are not remembered and traps are filtered for `knownBy` when map objects are updated (`engine/Grid.lua:30-45`; `engine/Actor.lua:30-34`; `engine/Map.lua:493-517`). Thus the native UI is layer-aware; a Boolean union is not blanket permission to return terrain, actors, objects, traps, effects, or arbitrary attributes.

Recommendation: use raw table indexing only, and define separate audited predicates:

- `remembered = active(map.remembers[index])` for persistent native terrain display;
- `visible =` the existing safe terrain predicate, including wilderness compatibility checks, blindness, FOV and light/actor guards;
- optionally `native_seen = active(map.seens[index])` only as a mask matching the renderer, never as permission for terrain detail by itself.

Do not use `has_seens` for this feature. It is an ever-seen/pathfinding history bit, but the native minimap does not use it as its display gate (`engine/Map.lua:647-685`; `src/map.c:2041`).

### High: adopting native memory changes an explicit security/knowledge policy

The current contract deliberately does **not** import `remembers` and deliberately preserves the last bridge-observed terrain instead of reading later hidden changes (`README.md:33, 275`; `docs/tome-mcp-worldmap-0.6.1.md:13`; `docs/tome-mcp-architecture.md:152-159`). Tests inject a remembered but bridge-unseen wilderness entrance and require it to remain undisclosed (`tests/test_observer.lua:148-167`).

The proposed native layer would intentionally reverse that rule. That can be legitimate if the product definition is "anything the native map UI can display": native remembered terrain, `all_remembered` towns, and current terrain changes rendered under a remembered cell are player-visible. It is not legitimate to call this merely an implementation of today's `known` semantics. The new result must use a distinct term such as `source="native_map"`; existing `known` must keep its meaning.

Before implementation, add native acceptance cases that compare the bridge projection with the actual map-display gates for: normal dungeon sight, ESP-only actor cells, blindness with old memory, detected traps, `all_remembered` towns, wilderness, and terrain that changes out of sight. The test author must decide whether an ESP-only `seens` cell yields only a perceived-cell mask or terrain detail.

### High: per-cell frozen enumeration does not fit the existing collection limits

Stock maps already exceed `MAX_VIEW_ITEMS=4096`: the wilderness is 170x100 (17,000 cells), towns reach 196x80 (15,680), Illusory Castle is 120x120 (14,400), and Charred Scar is 12x500 (`data/zones/wilderness/zone.lua:20-33` and the corresponding zone definitions). Fully remembered towns are a normal case, not an adversarial mod.

`ObservationViews` rejects more than 4096 items or more than 1 MiB per view and stores at most 4 MiB across views (`ObservationViews.lua:13-17, 137-159`; `protocol/v4/limits.json:18-24`). One terrain object per cell will exceed the item cap immediately and is likely to exceed the view-byte cap. Creating and JSON-sizing every cell also causes a large allocation/encode burst on the game thread even if only 64 cells are returned.

Do not model the frozen source as one item per map cell. Freeze compact row strings or row chunks. If detailed cells are needed, make them a bounded coordinate-region query (for example, at most 64 cells per call) rather than pre-materializing the whole level into `ObservationViews`.

### High: the proposed "minimal alternative" does not provide paging

Exposing level `w`/`h` is useful metadata, but clients cannot page the existing windows themselves: `observe` has no centre/origin arguments, and `Observer.capture` always centres on the player (`Observer.lua:127-128`; `server.py:402-415`). The only way to move the window is to move the character, which changes game state and cannot recover pre-bridge native memory.

Add `level_width`/`level_height` to existing window results if desired, but do not present that as a comparable explored-map capability. Avoid `w`/`h` or reusing `width`/`height`, because those names currently mean the response window.

### Medium: one global RLE array has a bad worst case and unclear paging semantics

RLE is compact for dense explored rectangles, but a checkerboard-like explored mask can require roughly half the cells as runs. At 17,000 cells that is about 8,500 JSON objects; verbose `{y,x_start,x_end}` objects can exceed the 256 KiB transport frame (`protocol/v4/limits.json:3`) even before envelope overhead. The proposal also does not say whether `page_size` counts runs, cells, or rows, or whether `count` is captured atomically with later pages.

Page by bounded row chunks, not by one global span list. A fixed one-byte-per-cell ASCII row for the largest stock map is only about 17 KiB before JSON overhead and has a much better worst case than object-form RLE. RLE may remain an optional machine format using arrays such as `[x_start,x_end]` inside each row item.

### Medium: `layer="memory"` is ambiguous and the bridge memory has a level-scope trap

Calling bridge-session memory `memory` while native remembered terrain is called `explored` invites clients to confuse the two. Prefer `source="native_map"|"bridge_observed"` or explicit layer names `native_remembered` and `bridge_observed`.

Also, bridge memory is currently keyed only by the Lua map object (`Observer.lua:9, 129`). `level_instance_id` changes whenever `game.level` changes (`Runtime.lua:346-357`), but a persistent level/map object can survive leaving and returning. Enumerating `memories[map]` after a return could therefore surface observations captured under a previous level-instance ID, contrary to a strict "never merge across level instances" claim. If `bridge_observed` is added, either key it by both map and current level-instance ID or explicitly define revisited persistent maps as carrying bridge memory forward.

Native memory legitimately survives a persistent-level revisit, but every response and cursor must still be labelled with the **current** `level_instance_id`; clients must never merge it into the old ID.

### Medium: a new operation fits better than `tome.list`

`tome.list` has a uniform `ObservationPage` result whose metadata is collection-oriented (`items`, counts, cursor) and currently has no place for map dimensions, origin, projection semantics, or explored count (`protocol/v4/results.schema.json:78-98`). A `level_map` collection could be made to work only by adding collection metadata and representing rows/chunks as items. Treating cells as items runs into the limits above.

A dedicated `tome.map` tool/internal `level_map` operation gives the result an honest schema and leaves list semantics intact. It should still reuse the proven frozen-view TTL/context rules where practical. If the team strongly prefers fewer tools, `tome.list(collection="level_map")` is acceptable only with row/chunk items plus a typed `collection_meta` field in `ObservationPage`; it should not be a special per-cell exception hidden behind the generic collection API.

### Medium: schemas must describe more than a generic `ToolReply`

The internal request requires a new op enum member and a distinct `$defs/MapArgs` branch (`protocol/v4/requests.schema.json:12-26`). Runtime validation, Python/Pydantic input types, rules text, capabilities, docs, vectors, and tests must change together.

`ToolReply.result` currently accepts any object (`protocol/v4/results.schema.json:7-19`). Adding an unused `$defs/MapPage` would document the shape but would not validate tool replies by itself. Add explicit schema/vector tests for `MapPage`, or introduce an op-specific result mapping if that is the desired contract rigor.

This is an additive read capability and can remain protocol v4 during a prerelease if `connect.capabilities` advertises it and old game/new server combinations fail clearly. If v4 is treated as frozen, it requires v5. That versioning policy needs an explicit decision.

### Medium: truncation must never masquerade as a complete map

`Details.bounded` protects ordinary snapshots at 192 KiB, but it does not apply automatically to a new result (`ObservationDetails.lua:478-523`). A map operation must use the page-data and frame budgets directly. If a dimension/scan/view limit is exceeded, return a clear `map_limit_exceeded` or a page with `capture_complete=false`, `truncated=true`, `truncation_reason`, and exact covered bounds. For a claimed full explored map, rejecting the capture is safer than silently dropping rows.

Validate `map.w`/`map.h` as finite positive integers and enforce an explicit maximum scan area before multiplying or looping. Stock ToME fits comfortably below 20,000 cells, but addons are not bounded by the stock zone files.

### Low: stale dynamic overlays should not be mixed into the terrain view

Actors, objects, projectiles, effects, and traps have different native display/knowledge rules. They also make a frozen page stale almost immediately. The first version should be terrain-only, with `player={x,y}` as separate metadata if useful. Do not overlay `A` or serialize remembered objects/traps merely because the full-map UI can draw some of them. Existing visible actor and ground-item APIs remain authoritative.

Doors/exits may be included only through the audited static terrain projection (`ObservationDetails.lua:373-409`). Never expose `change_zone`, destination IDs, map attributes, trap fields, or callbacks. Unknown/hidden doors remain whatever terrain entity the native map currently displays under the accepted knowledge gate.

### Low: no native seam or generated superload is needed

This can be implemented by raw scalar/table reads in a normal bridge module plus Runtime dispatch. It should not call `ShowMap`, `minimapDisplay`, tooltip methods, `checkEntity`, `canSee`, FOV functions, or any display callback: those paths can execute dynamic logic, and terrain tooltips can load zone files (`mod/class/Grid.lua:164-200`). No generated native seam or `tools/generate_native_seams.py` change is warranted. Keep the single-writer sequencing for `Runtime.lua`, `protocol/`, and generator-owned files.

## Recommended concrete design

### Tool and request

Add an opt-in read-only MCP tool `tome.map`, backed by an internal v4 operation named `level_map` (or bump the protocol if v4 is frozen). Do not add it to automatic snapshots.

Use the same discriminated first/next pattern as frozen collections:

```json
{
  "session_id": "...",
  "request": {
    "type": "first",
    "source": "native_map",
    "format": "rows",
    "page_size": 32
  }
}
```

```json
{
  "session_id": "...",
  "request": {"type": "next", "cursor": "..."}
}
```

For the MVP:

- `source` has only `native_map`. Reserve `bridge_observed` for a later addition after its revisit/level-instance semantics are fixed.
- `format` defaults to `rows`. Optional `runs` may use row-local arrays, not a global array of verbose objects.
- `page_size` counts row chunks, is 1..64, and is fixed in the frozen view. A row chunk should contain at most a fixed number of columns (for example 256), so modded very wide maps remain bounded.
- No `terrain=false` switch is needed for `rows`; the format itself defines the compact terrain projection. If a pure explored mask is wanted, name it `format="mask_rows"` rather than overloading an unrelated Boolean.

### Result sketch

```json
{
  "session_id": "...",
  "level_instance_id": "level-3",
  "captured_revision": 42,
  "current_revision": 42,
  "historical": false,
  "source": "native_map",
  "format": "rows",
  "w": 170,
  "h": 100,
  "origin": {"x": 0, "y": 0},
  "player": {"x": 28, "y": 13},
  "explored_count": 317,
  "terrain_scope": "remembered or safely visible terrain only; no actors, objects, traps, effects, destinations, attributes, or callbacks",
  "rows": [
    {"y": 12, "x_start": 0, "text": "????????....##..."}
  ],
  "returned_count": 1,
  "capture_complete": true,
  "has_more": true,
  "next_cursor": "...",
  "expires_in_ms": 120000
}
```

Use a normalized, documented ASCII alphabet rather than raw display glyphs:

- `?` unknown/not authorized;
- `.` statically passable terrain;
- `#` statically blocked terrain;
- `+` known door;
- `>` known exit;
- `:` remembered terrain whose static block status is unknown.

Priority should be exit, door, blocked/passable/unknown. This makes the overview directly useful to an LLM and keeps every known cell to one byte. Return player coordinates separately rather than overwriting terrain with `@`. If preserving native glyphs is important, add `native_char_rows` as an explicitly secondary field; do not let glyph collisions define passability.

The knowledge gate for terrain should initially be:

```text
terrain_allowed = map.remembers[index] is active OR existing_safe_visible(g, player, map, x, y)
```

Blindness does not erase already remembered terrain. ESP-only `seens` does not authorize terrain fields. Wilderness current visibility must retain the existing `NativeCompatibility` audit. If product policy instead demands exact C-minimap `seens || remembers`, expose the extra current cells as a separate mask and keep terrain fields suppressed until their layer/field equivalence is audited.

### Detailed terrain

Do not freeze every detailed cell. If agents need names and the full existing terrain projection, add a second mode to `tome.map` with an explicit rectangle:

```json
{
  "type": "region",
  "level_instance_id": "level-3",
  "x": 20,
  "y": 10,
  "width": 8,
  "height": 8
}
```

Require `width*height <= 64`; return row-major cells using the existing `Details.terrain` whitelist and the same native-memory/safe-visible gate. Unknown cells contain only coordinates and knowledge flags. This is more useful and cheaper than 266 cursor round trips to enumerate a fully remembered wilderness map, and it avoids storing 17,000 cell objects. Requiring the expected `level_instance_id` prevents a request composed for the previous scene from accidentally querying the new one.

If the team insists on cursor-based detailed cells, generate pages lazily from a compact frozen row/mask view and reject a cursor after any context change. Do not build a full array of projected cell objects first.

### Paging, guards, and lifecycle

- Capture row strings atomically in one read operation, then use the existing 120-second TTL, four-view/4 MiB aggregate budget, current-level/session/connection invalidation, and `historical` revision flag (`ObservationViews.lua:37-68, 91-126, 175-190`).
- Apply `MAX_PAGE_DATA_BYTES=131072` as well as `MAX_FRAME_BYTES=262144`; include envelope overhead in tests.
- Set and test a hard `MAX_MAP_SCAN_CELLS` comfortably above all stock maps. Reject invalid/oversized maps explicitly rather than looping an unbounded addon-defined dimension.
- Invalidate immediately on session, `level_instance_id`, or connection-generation change. Frozen pages may remain historical across ordinary revision changes because their content does not change.
- A save/reload creates a new bridge session and therefore invalidates all cursors. A persistent level revisit gets a new current `level_instance_id`, even if native remembered terrain survives.
- Expose `level_map_read={sources:["native_map"],formats:["rows"],terrain_scope:"terrain_only"}` in connect capabilities. Update rules to state that this native-map layer is distinct from window-cell `known`.
- Add `level_width` and `level_height` to the existing bounded map response as useful metadata, but keep the dedicated tool as the way to obtain explored terrain.

## Required tests

At minimum:

1. Dungeon remembered terrain outside radius 12 appears without moving the player; an unremembered cell does not.
2. ESP-only actor cell does not disclose terrain detail; the actor remains available through the actor API.
3. Blindness preserves old remembered rows but does not add new visually unknown terrain.
4. Wilderness and an `all_remembered` town match the chosen native-map policy.
5. A hidden/unknown trap and an unseen actor/object never appear in terrain output.
6. Known door/exit appears; destination identifiers and arbitrary map attributes never do.
7. Terrain change outside sight exercises the explicit policy decision: mirror the native map's current remembered display, or retain last-known terrain. The expected behavior must be documented.
8. 170x100, 196x80, 120x120, and 12x500 shapes stay within frame/view budgets; alternating known/unknown patterns do not blow up RLE.
9. Cursor expires on level change, reconnect/context change, session reset, TTL, and eviction; ordinary revision change yields a consistent historical frozen page.
10. Repeated map reads do not change RNG, turn, revision, FOV tables, map memory, dialogs, or player state.

## Open questions the author must decide

1. Does "player-visible" mean exact current native map rendering, including current backend changes under remembered cells and ESP-driven `seens`, or the bridge's stricter last-observed knowledge model? This cannot remain implicit.
2. Is the requested capability terrain-only, or must it reproduce remembered objects/traps and current actors? I recommend terrain-only.
3. Is `bridge_observed` actually needed? If yes, should memory survive leaving and returning to the same persistent Lua map under a new level-instance ID?
4. Is internal protocol v4 still open to additive capability-gated operations, or is it frozen and therefore v5 work?
5. What hard scan-area limit is supported for third-party zones, and is exceeding it an error or an explicitly partial result?
6. Should detailed terrain be a bounded rectangle (recommended) or a cursor enumeration? The latter requires a separate storage/performance design.
7. Does normalized LLM-oriented terrain (`. # + > : ?`) meet the product need, or is exact native glyph rendering required as an additional representation?

