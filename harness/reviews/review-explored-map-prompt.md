You are a senior reviewer. Review a design proposal for the ToME MCP bridge. This is a REVIEW ONLY task: do not modify any addon files, do not run the game, do not commit. You may read files and run read-only git/grep. Write your review to `/workspace/t-engine4/tmp/mcp-play-support/review-explored-map.md` and reply with a short summary.

> **Historical prompt, non-normative.** The "hard rules" below (reads must **never** run dynamic getters, RNG,
> native combat/target functions; "repeated map reads do not change RNG") encode a **read-purity premise that is
> superseded** by `AGENTS.md` and `docs/tome-mcp-auto-combat-plugin-design.md` §8.3. If reusing this prompt, use
> the current boundaries instead: a read must **not submit a game action** and must **not expose player-unknown
> information**; current live getters (including dynamic target/FOV helpers) may be evaluated and may consume RNG
> or have read-side effects; errors/`nil`/unavailable ⇒ `unknown`. Keep the terrain-knowledge, paging, budget and
> cursor invariants unchanged.

## Repo / context
- Project: `tome-mcp-bridge` 0.9.0, internal protocol v4, branch `feat/0.9.0-reliability`.
- Root: `/workspace/t-engine4/game/addons/tome-mcp-bridge` (addon Lua under `overload/mod/mcp_bridge/`, Python MCP server under `server/src/tome_mcp/`, protocol schemas under `protocol/v4/`).
- Architecture: a Lua bridge inside the ToME 1.7.6 game exposes a read-only observation + single-action write protocol; a Python MCP server wraps it as `tome.observe/act/status/inspect/list/respond/dismiss/stop/abandon/connect`.
- Hard rules: reads must expose only player-visible state; do not submit a game action; live getters (including
  dynamic/FOV helpers) may be evaluated and may consume RNG (see the banner); a frame budget of 256 KiB
  (`protocol/v4/limits.json`), snapshot/view budgets 4 MiB; one writer at a time for
  `Runtime.lua`/`protocol/`/`tools/generate_native_seams.py`.

## The question being reviewed
The user asked: "the player can see the explored terrain of the current level in the game's map UI; does MCP provide a comparable capability?"

## Finding (verify it)
MCP does NOT provide the full explored-level map. It returns a player-centred WINDOW only:
- `observe`/`act`/`status` with `include_map=true` return `map.window`, `rows`, `cells`, `legend`. `cells` carry `visible` (current FOV), `known` (= "observed by this bridge session"), `char`, `name`, `block_status`, `is_exit`, `door`, flags.
- `radius` is capped at 1..12 (`protocol/v4/requests.schema.json`), so at most 25x25 per call.
- `Observer.capture` only iterates the current window; `memories[map]` (a weak table, reset per session) retains observed terrain but outside-window cells are never returned (`merge_scope` says "outside cells are omitted").
- Native map memory is explicitly not imported: server RULES say `known means observed by this bridge session ... Native map memory is not imported. Unseen cells do not reveal names or entrances.` (`server/src/tome_mcp/server.py`, rules section).
- `tome.list` collections: inventory/equipment/actors/talents/effects/ground_items/progression_categories/progression_talents/compatibility. No map/terrain collection.
- Level dimensions (`map.w`/`map.h`) are used internally but not exposed.
Key files: `overload/mod/mcp_bridge/Observer.lua` (capture + memories), `overload/mod/mcp_bridge/ObservationDetails.lua` (`M.terrain`, `M.bounded`), `overload/mod/mcp_bridge/ObservationCollections.lua`, `protocol/v4/requests.schema.json`, `server/src/tome_mcp/server.py`.

## Proposal to review
Add a read-only "explored level map" capability, player-visible only (the native explored memory `map.seens`/`remembers` is exactly what the player's map shows, so it is legitimate). Preferred shape:

1. New MCP tool `tome.map(session_id, layer="explored"|"memory", format="runs"|"cells", page_size, cursor, terrain=false)` OR a `tome.list` collection `level_map`:
   - `layer="memory"` = bridge-session observed cells (today's `known`), `layer="explored"` = native `seens/remembers` (the player's map).
   - Default `format="runs"`: `{level_instance_id, w, h, explored:[{y, x_start, x_end}, ...]}` (run-length rows of explored cells) plus a count.
   - `format="cells"` + `terrain=true`: paged per-cell terrain (reuse the `cells` projection, page_size<=64, `next_cursor`), bounded by MAX_PAGE_DATA_BYTES / view budgets.
   - Always include `w`/`h` (level dimensions) and the `level_instance_id`; never merge across level instances.
2. Alternative minimal change: expose `map.w`/`map.h` in the existing map result and let clients page windows themselves.

## What to review (be concrete and critical)
1. Is the factual finding correct and complete? Any existing capability that already covers it (e.g. worldmap, `tome.list`, `ground_items`, `ObservationViews` paging, `interact`/`target` descriptions)?
2. Legitimacy/boundaries: is reading native `map.seens`/`remembers` acceptable under "only player-visible knowledge"? What exactly can the player's map see vs. what `seens` contains (ESP, blindness, wilderness, light)? Should FOV/ESP/light guards still apply, or is `seens` itself the correct source? Any anti-cheat or leakage concern (e.g. hidden doors, unseen traps, level layout)? (Reading may consume RNG; the relevant boundary is player-unknown information, not purity.)
3. Protocol/schema fit: best op name and args; result shape; how it fits `protocol/v4` (`results.schema.json` ToolReply, `$defs`); whether it should be a `tome.list` collection (frozen view, TTL, cursor) or a new op; versioning.
4. Budgets/performance: worst-case level size, run-length vs bitmap vs paged cells, allocation/encode cost inside the game tick, frame budget, view budget, paging semantics and cursor invalidation, truncation flags.
5. Correctness/edge cases: wilderness/worldmap (huge maps), multiple levels / level_instance_id changes, save/reload, session reset, `memories` weak table, `Observer.reset`, cells with actors/objects, unknown vs unexplored vs explored-but-not-currently-visible, door/trap knowledge.
6. API ergonomics for an LLM agent: is run-length useful, or should it return a rendered `rows` grid of explored/unknown chars? How does it interact with the existing per-window map (merge semantics)? Should it be opt-in to avoid payload blowups?
7. Anything that makes this a bad idea (scope creep, maintenance, compatibility, native seams, generate_native_seams involvement).

## Deliverable
Write `/workspace/t-engine4/tmp/mcp-play-support/review-explored-map.md` with:
- Verdict: is the finding correct? Should the feature be added (yes/no/optional) and why.
- Issues/risks with severity (high/med/low), each tied to a file/line or a concrete scenario.
- A recommended concrete design (op/collection name, request fields, result schema sketch, paging, guards) if you recommend proceeding — or the minimal viable alternative.
- Open questions / things the author must decide.
Then reply with a 5-10 line summary.
