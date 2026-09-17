# Auto-combat movement / repositioning design (0.9.0)

Status: investigation proposal only. Baseline: `main@a4e05d584ff2a9654c90a4729decd8c43c227b39`
(ToME 1.7.6). This document does not authorize execution, change
`allow_auto_combat_execution`, or implement product behavior.

Source citations under `game/...` are relative to `/workspace/t-engine4`; all other
paths are relative to this addon's repository root.

## 1. Recommendation

Add movement in two deliberately small layers:

1. **Plain one-step movement**: a policy chooses a destination objective, not a
   keypad direction. The planner considers the eight adjacent cells, applies the
   movement guard, ranks the survivors deterministically, and only then lowers the
   winner to `{type="move", direction=1..9}`.
2. **Manifest-certified movement talents**: keep `action="use_talent"`; retain the
   existing hostile `target` selector for condition/action binding, and add a
   separate `destination` object for a landing grid. Each talent adapter declares
   its native target-request sequence and every possible landing cell. Start with
   actor-anchored `T_RUSH` and exact-grid `T_SKIRMISHER_CUNNING_ROLL`; do not infer
   support from `is_teleport`, target shape, or talent name.

This is an extension of the existing data-only policy model, not pathfinding and
not a new activity mode. Policies remain JSON-only (§2 principle 1), decisions use
no RNG (§1.1 G7), and all execution still enters through native calls
(`docs/tome-mcp-auto-combat-plugin-design.md` §1.1, §2).

The current implementation does not yet expose either layer: `PolicySchema.ACTIONS`
contains `use_talent`, `attack`, `wait`, `rest`, and `auto_explore`, while its
selectors are only self/hostile actor selectors
(`overload/mod/auto_combat/PolicySchema.lua:9-31`). The Berserker preset therefore
uses a low-priority `wait` when a visible hostile is not adjacent
(`overload/mod/auto_combat/PolicyPresets.lua:160-190`).

### Scope

- Current visible combat only; movement is evaluated only while at least one
  hostile is currently visible. The controller already stops with
  `no_visible_enemies` and does not turn a failed rule into idle waiting
  (`overload/mod/auto_combat/AutoCombat.lua:289-313`).
- Same level instance, current action opportunity, bounded candidate set.
- Plain steps, actor-anchored close-in talents whose complete landing envelope can
  be proven, and exact-grid movement talents whose source has no alternative
  landing behavior.
- Mixed move+attack talents must pass both the movement guard proposed here and
  the existing effect/selffire guard. The existing guard currently handles only
  `attack` and `use_talent` effect components
  (`overload/mod/auto_combat/AutoCombatGuard.lua:167-192`).

### Anti-goals

- Exploration, auto-explore, pathfinding toward unseen cells, chasing a hostile
  after it leaves visibility, and changing level.
- Long-range travel or choosing destinations from remembered-but-not-currently-
  visible terrain.
- A generic "all teleport talents" adapter.
- Default retreat, kiting, or panic movement.
- Random/uncertain landing talents in the first tranche, including ordinary
  `Phase Door`, `Teleport`, and any nominally precise teleport that can fall back
  to another grid.
- Moving allies/enemies, swaps, knockback/pull planning, Probability Travel, or
  arbitrary Lua in policy data.
- P3 assistant import/export work.

## 2. Current native and bridge facts

The general bridge already validates a raw move as an integer direction 1..9
excluding 5 (`overload/mod/mcp_bridge/Actions.lua:84-93`) and executes it as
`player:moveDir(direction)` (`overload/mod/mcp_bridge/Actions.lua:271-274`). The
engine maps a direction to an adjacent coordinate and calls `Actor:move`
(`game/engines/default/engine/Actor.lua:269-309`). The native move remains the
final authority: a successful-looking move that changes neither position nor
energy is reported as `blocked` (`overload/mod/mcp_bridge/Actions.lua:285-293`).

The bridge also accepts a `use_talent` with either one actor `target_id` or one
grid `x/y`, never both (`overload/mod/mcp_bridge/Actions.lua:102-114`). Execution
calls native `useTalent`; for a supplied actor/grid it pre-fills only the **first**
native `getTarget` and restores the real target UI for any later request
(`overload/mod/mcp_bridge/Actions.lua:204-269`). Therefore:

- one actor request (Rush style) is already supported by `Actions`;
- one grid/direction request (Tumble style) is already supported by `Actions`;
- a self/random talent with no target request can already be invoked by `Actions`,
  but is not thereby safe for auto-combat;
- a talent needing actor then grid, such as level-5 Phase Door, is not fully
  prefillable by the current action shape and may become `native_pending`/
  player interaction.

The auto-combat production mapper is narrower than general `Actions`: it currently
lowers actor-bound attack/use-talent, sustain, and wait only; it has no `move`
branch and never emits talent `x/y` (`overload/mod/mcp_bridge/Runtime.lua:1148-1177`).
Both plain move and grid-target talent support therefore require production-mapper
work even though general `Actions` already knows the native calls.

Native movement itself may deviate from a requested grid. Confusion can randomize
a normal step and Probability Travel can turn a step into wall travel
(`game/modules/tome/class/Actor.lua:1388-1423`); the player wrapper can slide after
a failed step (`game/modules/tome/class/Player.lua:312-332`); movement callbacks
run after the move (`game/modules/tome/class/Actor.lua:1490-1523`). A movement
adapter must explicitly reject unaudited active movement modifiers/callbacks and
must post-check the actual level and coordinate. Post-checking detects drift; it
does not make an unsafe pre-check acceptable.

## 3. Policy data model

### 3.1 Rule shape

Add `move` to `PolicySchema.ACTIONS`. Add the following fields to `then`:

```json
{
  "action": "move | use_talent",
  "talent": "T_...",
  "target": "nearest_hostile | lowest_hp_hostile | highest_rank_hostile | most_dangerous_hostile",
  "purpose": "engage | reposition | retreat",
  "destination": {
    "selector": "preferred_distance | toward | away | native_landing",
    "anchor": "bound_target",
    "distance": 1
  }
}
```

`target` keeps its existing meaning: select the hostile used by target-relative
`when` predicates and by an actor-target talent. `destination` selects or
constrains a landing grid; it never replaces `target`. This preserves the existing
same-target binding rule (`docs/tome-mcp-auto-combat-plugin-design.md` §5.3) and
avoids overloading actor selectors with map coordinates.

Recommended examples:

```json
{
  "id": "close", "priority": 20,
  "when": {"all": [
    {"enemy_count": {"ge": 1}},
    {"not": {"enemy_in_melee": {}}}
  ]},
  "then": {
    "action": "move", "target": "nearest_hostile", "purpose": "engage",
    "destination": {"selector": "toward", "anchor": "bound_target"}
  }
}
```

```json
{
  "id": "rush", "priority": 60,
  "when": {"all": [
    {"nearest_enemy_distance": {"ge": 2}},
    {"cooldown_ready": {"talent": "T_RUSH"}}
  ]},
  "then": {
    "action": "use_talent", "talent": "T_RUSH",
    "target": "nearest_hostile", "purpose": "engage",
    "destination": {"selector": "native_landing", "anchor": "bound_target"}
  }
}
```

```json
{
  "id": "tumble-spacing", "priority": 40,
  "when": {"enemy_distance": {"lt": 3}},
  "then": {
    "action": "use_talent", "talent": "T_SKIRMISHER_CUNNING_ROLL",
    "target": "nearest_hostile", "purpose": "retreat",
    "destination": {
      "selector": "preferred_distance", "anchor": "bound_target", "distance": 4
    }
  },
  "emergency": true
}
```

The last rule is intentionally an explicit retreat opt-in; it must not appear in
built-in presets by default.

### 3.2 Selector meanings

| Selector | Candidate objective | Allowed action domain |
| --- | --- | --- |
| `toward` | minimize distance to `bound_target` | plain adjacent step; exact-grid talent |
| `preferred_distance` | minimize `abs(distance(candidate, anchor)-distance)` | plain adjacent step; exact-grid talent |
| `away` | maximize distance from `bound_target` | explicit retreat rule only |
| `native_landing` | adapter computes a finite landing/outcome envelope from the actor target | actor-anchored talent only |

`adjacent_to(bound_target)` is represented by
`preferred_distance + distance:1`. It is an objective, not a requirement that one
action reach distance 1; this lets a one-step `move` close a distant visible foe.
`safe_tile_within_sight` is not admitted in this version: without a threat model
it means only “passes basic guards” and otherwise selects an arbitrary grid. A
future threat selector needs its own audited inputs and scoring contract.

### 3.3 Strict validation

Validation remains allowlist-based; current unknown fields are rejected by
`PolicySchema.onlyKeys` (`overload/mod/auto_combat/PolicySchema.lua:76-79`). Apply
these rules:

- `move`: require `target`, `purpose`, and `destination`; reject `talent` and
  `max_turns`.
- movement-capable `use_talent`: require a manifest movement component and
  `purpose`; require `destination` for grid or actor-anchor adapters. A nonmovement
  talent rejects `destination`/`purpose`.
- `anchor` is exactly `bound_target` in this revision; no coordinates, Lua paths,
  expressions, or policy-stored `x/y`.
- `distance` is required only for `preferred_distance`, integer 1..20; it is
  forbidden for the other selectors. The talent's adapter may impose a lower cap.
- `native_landing` is legal only when the manifest declares
  `target_request="actor"` and a finite, deterministic landing envelope.
- `purpose="engage"` requires every possible landing to strictly reduce distance
  to the anchor; `reposition` may preserve or reduce distance but never increase
  it; `retreat` requires every possible landing to increase it.
- `retreat` requires `emergency:true`. Conversely, an emergency `move` must be
  `retreat`; close-in movement is not self-preservation.
- Existing hostile selector validation remains unchanged. `self` is invalid as a
  movement anchor in this revision.
- Random/alternative landing metadata is not a policy escape hatch. If an adapter
  declares an unbounded, random, source-dependent, or unknown outcome set,
  validation fails `unsupported_movement_outcome`.

Do not add a generic `allow_random` boolean now. A flag cannot prove an unknown
destination safe, and policy permissions cannot override the guard.

## 4. Deterministic destination selection

The algorithm is pure over one bounded snapshot:

1. Bind the hostile with the existing selector algorithm. Current hostile binding
   already orders candidates by distance, then `y`, `x`, and id
   (`overload/mod/auto_combat/PolicySnapshot.lua:13-60`).
2. Freeze `{level_instance_id, revision, origin, bound_target}` and construct the
   **visible-fight envelope**: cells that are currently safe-visible through
   `Observer.terrainVisible`, on the same level, and in the bounded adapter scan.
   `terrainVisible` requires native `seens`, no blindness, FOV, and its light/
   actor guard (`overload/mod/mcp_bridge/Observer.lua:33-44`). Remembered-only
   cells are deliberately excluded even though the level-map API may disclose
   remembered terrain (`overload/mod/mcp_bridge/LevelMap.lua:45-57`).
3. Generate candidates without RNG:
   - plain `move`: the eight adjacent coordinates in fixed keypad order
     `[7,8,9,4,6,1,2,3]`;
   - grid talent: scan the manifest-bounded native target domain in increasing
     `y`, then `x`, using the audited live target builder for range/shape;
   - actor talent: the adapter returns its complete possible landing envelope.
4. Filter every candidate and, for line/leap movement, every traversed or possible
   landing cell through §6. Any unknown safety result removes the candidate and is
   recorded as unknown; no unsafe/unknown cell may be used as a tie-break input.
5. Rank the survivors by the tuple
   `(selector_score, distance_from_origin, y, x, native_stable_id)`, ascending.
   Scores are destination distance (`toward`), absolute error from the requested
   distance (`preferred_distance`), or negative destination distance (`away`).
   No table iteration order or RNG participates.
6. Recheck the frozen level/revision, actor binding, target builder/manifest pin,
   complete landing envelope, and chosen coordinate immediately before commit.

Candidate enumeration must examine the whole adapter-bounded domain while retaining
at most the best `limits.max_candidates` entries. If the domain cannot be fully
scanned within a compile-time cap, return `destination_domain_unbounded`; never
truncate and pretend the chosen tile was globally best. The existing hard candidate
limit is 32 (`overload/mod/auto_combat/PolicySchema.lua:68-70`).

## 5. Movement manifest and execution mapping

Extend each canonical effect-manifest entry with an optional movement component;
do not maintain a second, drifting whitelist. The current catalog is derived from
the manifest (`overload/mod/auto_combat/AutoCombatCatalog.lua:1-33`), and current
effect source drift is already a hard guard input
(`overload/mod/auto_combat/AutoCombatGuard.lua:177-215`).

Recommended component fields:

```lua
movement = {
  target_request = "none" | "actor" | "grid" | "actor_then_grid",
  delivery = "step" | "line_move" | "leap" | "teleport",
  landing = "adjacent_before_actor" | "exact_grid" | "random_radius" | "source_defined",
  traverses = true | false,
  relocates_other = false,
  alternate_radius = 0,
  source = {path=..., definition_line=..., action_digest=..., target_digest=...},
}
```

The generated source pins must cover the action, target builder, and engine helpers
that determine landing (`moveDir`, `move`, `teleportRandom`, `findFreeGrid`, line
geometry). A source-defined movement component is unsupported until its finite
outcome-envelope function is reviewed and tested.

| Case | Policy lowering | Native entry | Current `Actions` support | Required movement guard |
| --- | --- | --- | --- | --- |
| Plain step | chosen adjacent `(dx,dy)` → keypad `direction` | `Actions.execute` → `player:moveDir(direction)` | yes (`overload/mod/mcp_bridge/Actions.lua:89-92,271`) | exact adjacent endpoint; reject movement modifiers; visible-fight/passability/hazard/intent checks |
| Actor-target Rush style | `use_talent`, `target_id=bound_target` | tracked native `player:useTalent`; first `getTarget` receives actor | yes (`overload/mod/mcp_bridge/Actions.lua:163-180,204-269`) | source-pinned line and complete possible landing prefix; hostile still visible; mixed attack footprint guard |
| Exact grid/beam/direction style | `use_talent`, `x/y=chosen_destination` | tracked native `player:useTalent`; first `getTarget` receives grid | yes in general `Actions`; not in auto-combat mapper (`overload/mod/mcp_bridge/Actions.lua:102-114`; `overload/mod/mcp_bridge/Runtime.lua:1169-1172`) | live builder range + `canProject`; exact endpoint, path/envelope, hazard and intent checks |
| Actor then grid | typed target plan with two ordered responses | two native `getTarget` calls | **no**: current prefill is consumed once (`overload/mod/mcp_bridge/Actions.lua:216-260`) | unsupported until `Actions` accepts and validates an adapter-pinned ordered target plan |
| Random/self teleport | no target or a center grid | native talent → `teleportRandom` | callable, but not auto-combat-safe | reject in this revision; a future opt-in must prove every possible endpoint and still preserve player-visible reads |

Extend the auto-combat attempt with `destination={x,y}`, `direction`, and
`movement_envelope`; have the production mapper emit either raw move or talent
`x/y`. Extend the `Actions.execute` result/log with `from`, `to`, and
`level_instance_id` for postcondition audit. Do not call `player:move` or
`teleportRandom` directly from auto-combat.

## 6. Safety invariants

All invariants are conjunctive. A mixed talent is admissible only if both its
effect components and movement component pass.

### 6.1 Visible-fight envelope

At selection and again immediately before native commit:

1. At least one hostile is currently visible and the bound hostile is still the
   same visible actor. The controller already treats the visible-hostile set as an
   execution boundary (`overload/mod/auto_combat/AutoCombat.lua:233-239`).
2. Origin, every possible endpoint, and every traversed cell are on the same
   `level_instance_id` and currently pass `Observer.terrainVisible`.
3. No endpoint is an exit/change-level cell. The player wrapper merely reports a
   level-change tile after moving onto it (`game/modules/tome/class/Player.lua:285-293`),
   but excluding exits makes “no change-level” structural rather than relying on
   a later command not being issued.
4. No endpoint or traversal cell is unknown/unexplored. Remembered but not current
   FOV is insufficient.
5. The action's intent monotonicity from §3.3 holds for **all** possible endpoints,
   not only the expected endpoint.

This definition permits tactical movement inside the snapshot's current visible
fight but cannot turn into exploration: the envelope is rebuilt every opportunity
and never expands from remembered map data.

### 6.2 Passability without information leaks

“Passable” must mean **known passable from player-visible state, followed by native
revalidation**. The planner must not call `canMove`/`checkAllEntities` merely to
discover a hidden actor, because that would feed non-player-known occupancy into
planning. The engine's `canMove` checks all blocking entities
(`game/engines/default/engine/Actor.lua:297-308`), whereas the existing map view
intentionally exposes terrain and known overlays but not out-of-sight actors
(`overload/mod/mcp_bridge/LevelMap.lua:43-57,131-166`).

For each candidate require:

- player-visible terrain passability is known true through a version-pinned
  terrain predicate; dynamic/overridden/errored terrain checks are unknown;
- no player-visible blocking actor occupies the endpoint;
- an actor-anchor adapter proves that any blocker-dependent earlier landing also
  stays inside the safe envelope;
- native execution performs the final actual collision/passability check.

A hidden blocker may cause native rejection or a native bump interaction; it must
never be queried to improve candidate ranking. This is an unavoidable epistemic
limit, so logs should say `known_passable=true`, not claim omniscient passability.

### 6.3 Hazards

Introduce a version-pinned `MovementHazard` classifier over player-visible data.
A candidate is legal only when every endpoint/traversed cell is `safe`; `unsafe`
is rejected and `unknown` fails closed.

Minimum first-tranche checks:

- reject a trap only when it is known to the player. The existing safe projection
  obtains knowledge from `all_know`/`known_by[player]`
  (`overload/mod/mcp_bridge/LevelMap.lua:33-41,53`);
- reject exit/change-level terrain;
- reject a curated visible hazardous-terrain or visible ground-effect component;
- reject terrain with an unaudited movement callback, unknown air/breathability
  consequence, or unknown damage-on-enter behavior;
- never inspect an unknown trap/effect to decide; hidden hazards remain hidden and
  are left to native resolution.

The first implementation may conservatively support only source-pinned vanilla
floor/door states plus a curated hazard registry. “No known trap” alone is not a
proof that an arbitrary modded terrain callback is safe.

### 6.4 Projection and talent effects

- Grid/actor target talents must pass the audited live target builder, native
  range, and `canProject` when their source uses projection. The current effect
  guard already treats failed/missing `canProject` as fail-closed
  (`overload/mod/auto_combat/AutoCombatGuard.lua:216-238`).
- `max_selffire_risk` continues to govern damage/self/friendly footprints exactly
  as today: zero rejects, positive values pause
  (`overload/mod/auto_combat/AutoCombatGuard.lua:167-182,309-320`). It never
  authorizes an unsafe destination, retreat, unknown hazard, or unknown landing.
- A Rush/Vault/Giant-Leap-style attack must pass damage geometry and movement
  geometry independently. An effect-safe attack with an unsafe landing is denied;
  a safe landing with unknown friendly fire is denied/paused by the existing rule.
- Any active confusion, Probability Travel, player-slide branch not covered by the
  envelope, movement callback, or mod override that can alter landing is
  `movement_outcome_unknown`.

### 6.5 Retreat

There is no built-in retreat rule. `purpose="retreat"` is the explicit opt-in and
is allowed only on `emergency:true`; all possible endpoints must increase distance
from the bound hostile and pass the same destination tests. `reposition` cannot
silently increase distance and therefore cannot smuggle in retreat.

The present controller pauses immediately below `flee_below_hp_pct` before it
evaluates emergency rules (`overload/mod/auto_combat/AutoCombat.lua:249-259`), and
Wave 1 explicitly defines that threshold as pause-only
(`docs/tome-mcp-0.9.0-wave1-execution-safety.md` §D6). Supporting explicit retreat
therefore needs the narrow normative clarification in §7; absent an explicit
retreat rule, behavior remains byte-for-byte equivalent: pause and return control.

## 7. Contract interaction and exact amendment

Movement inside the envelope does not widen §0.1: the frozen contract already says
current visible fight only, stop when no visible enemy remains, no exploration,
no chase into unknown, and no change-level
(`docs/tome-mcp-auto-combat-plugin-design.md` §0.1). It also already names `move`
and says retreat is not default and requires an explicit preset plus destination
test (`docs/tome-mcp-auto-combat-plugin-design.md` §5.3-§5.4).

However, implementation needs a normative definition of “visible fight” for a
destination, and Wave 1's unconditional flee-threshold pause must be reconciled
with explicit emergency retreat. Add the following text under §5.4; this is a
**clarifying amendment, not a scope expansion**:

> **Movement destination and visible-fight boundary (v1.5).** A movement or
> repositioning rule may commit only while a hostile is currently visible. At
> selection and immediately before commit, every possible landing grid and every
> traversed grid MUST be on the current level instance, currently player-visible
> (remembered-only is insufficient), known passable from player-visible state,
> free of known hazards, and within the adapter's version-pinned native range/
> projection rules. Unknown, unexplored, exit/change-level, source-drifted, or
> unbounded/random destinations fail closed. Native movement/collision remains the
> final authority and MUST NOT be pre-read in a way that reveals hidden entities.
> The decision and tie-break order MUST be deterministic.
>
> **Retreat opt-in (v1.5).** No built-in preset contains retreat. A destination
> that increases distance from its bound hostile is retreat and is legal only in
> a rule explicitly marked `emergency:true` and `purpose:"retreat"`; it must pass
> the same destination guard. If `hp_pct < flee_below_hp_pct`, the controller MAY
> evaluate only such explicit emergency retreat/self-preservation rules; if none
> exists, none is legal, or safety is unknown, it pauses with
> `flee_below_hp_pct`/`no_emergency_action` and returns control. It MUST NOT fall
> through to normal output.

Also replace the stale §5.3 prose-only action list with the generated implemented
catalog when this feature lands; today that paragraph lists actions not admitted
by `PolicySchema`, while the implementation catalog is authoritative
(`overload/mod/auto_combat/EffectManifest.lua:333-365`). No amendment to
`allow_auto_combat_execution=false` is needed or permitted.

## 8. Failure, stall, and budget semantics

| Situation | Result | Budget/state |
| --- | --- | --- |
| no candidate survives deterministic destination filtering | rule unavailable: `no_legal_destination`; try next eligible rule | no native-call attempt; counts against bounded rule/candidate evaluation only |
| safety input unknown for the only normal movement rule | deny that action; if no other rule, stop `no_available_action` | no implicit wait |
| safety input unknown for the only emergency/retreat rule | pause `movement_safety_unknown` / `no_emergency_action` | never fall through to output |
| final recheck sees stale level/revision/target/destination | guard reject; deny same rule for this opportunity | follow existing guard-rejection attempt accounting |
| native plain move is blocked or talent rejects without energy | deny same rule; may try another rule in the same opportunity | one attempt; never retry unchanged action |
| talent yields `native_pending` | enter `waiting_native`; submit nothing else | one attempt; re-evaluate at safe ready boundary |
| native asks for an undeclared additional target/input | pause `unexpected_target_request`; adapter/source-drift fault | no automated response |
| result uncertain, energy spent, level changed, or actual endpoint outside certified envelope | pause/stop `movement_postcondition_failed`; do not retry | audit from/to and hand control back |
| successful energy-spending move | next native action opportunity gets a fresh snapshot | normal action accounting |
| successful `no_energy` movement talent | fresh snapshot in same opportunity, subject to instant cap | existing instant semantics |

The existing controller already treats `native_pending` as an internal wait and
re-evaluates after it settles (`overload/mod/auto_combat/AutoCombat.lua:352-405`),
and stops rather than waits when no rule is available
(`overload/mod/auto_combat/AutoCombat.lua:306-313`). Keep those semantics.

The distinction between destination selection and a real attempt is intentional.
The frozen execution contract counts real submissions and guard rejections, while
pure candidate enumeration is a bounded read. A stale candidate caught by the
final guard is an attempt; an empty candidate set discovered before constructing
an action is not.

## 9. Source-verified talent classification

| Talent | Native target / landing | Classification | First-tranche recommendation |
| --- | --- | --- | --- |
| Berserker `T_RUSH` | one actor target; source walks a terrain-blocked line and lands on the last passable grid adjacent to the target before attacking (`game/modules/tome/data/talents/techniques/combat-techniques.lua:23-85`) | actor-anchored line move + attack | **support**, after adapter proves the complete earlier-landing prefix and effect guard covers the attack |
| Archmage `T_PHASE_DOOR` | random self teleport at low level; at level 4 can choose the creature; at level 5 adds a second target-area prompt; final call is `teleportRandom(center, radius)` (`game/modules/tome/data/talents/spells/conveyance.lua:65-168`) | self/actor then optional grid; random landing | **unsupported** first tranche; multi-prompt and random outcome |
| Archmage `T_TELEPORT` | actor selection at level 4, area selection at level 5, large random teleport with a minimum range (`game/modules/tome/data/talents/spells/conveyance.lua:170-284`) | long-range random teleport | **unsupported**: travel-scale, random, normally impossible to prove wholly inside visible fight |
| Archmage `T_DISPLACEMENT_SHIELD` | one actor target; applies a shield effect linked to that target and does not move the player (`game/modules/tome/data/talents/spells/conveyance.lua:286-321`) | **not movement** | normal actor-target effect adapter work, not part of this feature |
| Skirmisher `T_SKIRMISHER_CUNNING_ROLL` (Tumble) | one beam/grid target, rejects blocked/nonprojectable grid, then force-moves to that exact grid (`game/modules/tome/data/talents/techniques/acrobatics.lua:127-187`) | exact grid move, instant | **support** after grid mapper + movement modifier/callback audit |
| Skirmisher `T_SKIRMISHER_VAULT` | one beam/grid landing target; requires a visible adjacent launch actor, rejects blocked/nonprojectable landing, then force-moves exactly there (`game/modules/tome/data/talents/techniques/acrobatics.lua:27-125`) | exact grid move with actor prerequisite | safe candidate for a later adapter; more complex than Tumble |
| Paradox Mage `T_DIMENSIONAL_STEP` | one visible grid; level 5 may swap an actor; otherwise calls `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:22-90`) | intended precise grid teleport, conditional swap/alternate landing | **unsupported** until actor-occupied swap is excluded and the radius-5 fallback envelope is proven |
| Blink rune | one visible grid then `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/misc/inscriptions.lua:646-686`) | intended precise grid teleport with alternate landing | same restriction as Dimensional Step |
| Shadowstep | actor target then `teleportRandom(target.x,target.y,0)` before attacking (`game/modules/tome/data/talents/cunning/shadow-magic.lua:109-159`) | actor-anchored teleport with alternate landing | **unsupported** until every possible landing near the occupied target is certified |
| Movement Infusion | no displacement; schedules a one-turn movement-speed effect (`game/modules/tome/data/talents/misc/inscriptions.lua:203-225`) | self buff, not a move | existing self-talent model; useful only in combination with later plain steps |
| Giant Leap | grid target, may replace an occupied destination via `findFreeGrid(radius=1)`, force-moves, then attacks radius 1 (`game/modules/tome/data/talents/uber/str.lua:20-79`) | grid move + AoE + alternative landing | later only: movement and effect envelopes must both be proven |

The key source fact behind the conservative teleport classification is that ToME's
`teleportRandom(..., 0)` first calls `findFreeGrid` with radius 5
(`game/modules/tome/class/Actor.lua:1631-1647`), and `findFreeGrid` assigns random
tie-break values among equally distant free cells
(`game/engines/default/engine/utils.lua:2943-2981`). It is exact only when the
requested cell remains the unique closest legal grid; hidden occupancy cannot be
read by the planner to prove that. Ordinary random teleport then explicitly picks
one candidate with RNG (`game/modules/tome/class/Actor.lua:1652-1687`).

## 10. Test and verification plan

### 10.1 Pure Lua fixtures

1. Schema accepts the three recommended shapes and rejects missing/extra fields,
   literal coordinates, invalid distance, self anchor, nonmovement talent with a
   destination, actor talent with a grid-only selector, and unmanifested talent.
2. Symmetric adjacent candidates select by objective, path length, `y`, `x`, then
   stable id; repeat the fixture with tables inserted in different orders and
   assert identical output.
3. `toward`, `preferred_distance(1|k)`, `away`, and `native_landing` fixtures,
   including a Rush landing prefix.
4. Visible passable floor succeeds; remembered-only, blind, unexplored, blocked,
   exit, known trap, unknown terrain callback, and visible hazardous ground fail
   closed.
5. Negative required case: the geometrically best destination is unknown/unsafe;
   it is removed and never submitted. If no survivor remains, normal combat stops
   `no_available_action` rather than waiting.
6. Fight-scope required case: a candidate endpoint is visible but its declared
   traversal crosses an unknown cell, or a teleport endpoint is remembered but not
   currently visible; reject `outside_visible_fight`.
7. Purpose checks: engage cannot increase distance, reposition cannot increase,
   retreat requires `emergency:true`, and all possible endpoints—not just the
   expected one—must satisfy the purpose.
8. Mixed talent matrix: movement safe/effect unsafe, movement unsafe/effect safe,
   both safe, and either side unknown. Assert `max_selffire_risk` never changes a
   movement verdict.
9. Failure-state tests for no destination, final-recheck drift, native blocked,
   `native_pending`, undeclared second prompt, instant movement cap, and endpoint
   postcondition failure.
10. Permission regression: `allow_auto_combat_execution` remains false by default;
    dry-run may report a proposed destination but never call `Actions.execute`.

### 10.2 Native source and dist probes

Run only in the implementation phase, under the existing source/dist evidence
discipline:

- **Plain step parity**: on a fixed visible room, compare planner `(x,y)→direction`
  with real `Actions.execute({type="move"})`; cover all eight directions, wall,
  corner, known trap rejection, and no position change. Record before/after
  coordinate, energy, level id, and action result.
- **Rush parity**: force-learn Rush; for open line, terrain blocker, actor blocker,
  adjacent target, and range edge, compare the adapter's full allowed landing
  envelope with the actual native landing and assert the actual grid is a member.
  Also assert the native actor target passed through the production mapper.
- **Tumble parity**: compare candidate reachability with the live target builder,
  `canProject`, and actual native landing for open, blocked, corner, and out-of-
  range grids. Verify the auto-combat mapper emitted `x/y`, not an actor id.
- **Random negative**: attempt policy validation/dry-run for Phase Door,
  Dimensional Step, and Blink and assert `unsupported_movement_outcome`; prove no
  native action was submitted. Do not make RNG outcome sampling the safety proof.
- Run all cases from source and packaged `dist`, pin package SHA-256, and include a
  source/dist manifest/source-digest comparison as required for runtime changes.

### 10.3 Per-talent source-review checklist

Before admitting any movement talent, record:

- stable talent id, source path/definition line, game version, action digest,
  target-builder digest, and relevant engine-helper digests;
- mode, resource/cooldown, `no_energy`, `requires_target`, pre-use gates, and every
  active-state variant by effective talent level/attributes;
- exact number and order of native target requests (self/actor/grid/direction),
  including conditional second prompts;
- live range/shape/LOS/`canProject` rules and whether target coordinates are
  transformed;
- every movement call (`move`, `moveDir`, `teleportRandom`, `findFreeGrid`, line
  walk, swap, knockback/pull), force flag, blockers, no-teleport/vault rules, and
  the complete alternate/random landing envelope;
- whether intermediate cells are traversed or skipped;
- whether any other actor is moved, removed, swapped, or targeted by a save/hit
  roll;
- every damage, ground, secondary, self/friendly-fire, and on-land component;
- active effects, callbacks, hooks, confusion, slide, Probability Travel, or mod
  overrides that can alter landing;
- player-visible inputs used by the planner and an explicit proof that no hidden
  entity/map property enters selection;
- exact current `Actions` lowering and whether the declared prompt count is fully
  prefilled;
- native rejection/pending/energy/postcondition behavior and one negative
  source-drift test.

## 11. Unsupported list and reasons

- **Random Phase Door/Teleport and random self teleports**: destination cannot be
  certified before commit, and reproducing the native candidate set would consult
  actual occupancy that the planner is forbidden to learn.
- **Nominally precise `teleportRandom(...,0)` talents** without a full fallback
  envelope: occupied destinations invoke `findFreeGrid` and may land elsewhere.
- **Actor-then-grid multi-prompt talents**: current `Actions` pre-fills one target
  request only.
- **Swaps or movement of other actors**: they require a separate hostile/ally
  displacement contract, save/resistance modeling, and destination safety for
  both actors.
- **Probability Travel and wall-crossing movement**: they leave the current visible
  connected fight envelope and can convert a plain direction into longer travel.
- **Long-range travel and auto-explore/pathfinding**: contrary to §0.1; movement
  re-evaluates one current-fight action at a time and never selects unknown tiles.
- **Retreat by default**: remains opt-in through an explicit emergency retreat rule;
  without one, `flee_below_hp_pct` remains a pause.
- **A generic `safe_tile` selector**: no audited threat model exists, so the name
  would overstate what the guard proves.
- **Unknown/modded movement talents or terrain callbacks**: no version-pinned
  adapter/outcome envelope; fail closed.

## 12. Open uncertainties for implementation review

1. **Epistemic passability wording**: an absolute guarantee of actual passability
   conflicts with the player-visible-only rule because hidden actors can block a
   visible floor. This design guarantees known terrain passability and delegates
   hidden collision to native execution. The exact amendment in §7 makes that
   distinction explicit.
2. **Hazard coverage**: the repository has a safe known-trap projection but no
   canonical movement-hazard manifest. The first implementation must enumerate
   which vanilla terrain and visible map-effect families it can prove safe; until
   then they remain unknown (`overload/mod/mcp_bridge/LevelMap.lua:33-57`;
   `overload/mod/auto_combat/AutoCombatGuard.lua:1-21`).
3. **Movement callbacks/modifiers**: vanilla `Actor:move` fires talent callbacks and
   hooks. The compatibility audit must identify every active modifier that can
   relocate the player; unknown callbacks must disable movement rather than rely
   only on post-checking.
4. **Future random opt-in**: if product owners later want random teleports, use a
   separate contract amendment and a double opt-in (policy intent plus explicit
   safety permission). Admission must prove *all* possible outcomes visible/safe/
   in-scope without reading hidden occupancy. No current vanilla Phase Door adapter
   has that proof.
