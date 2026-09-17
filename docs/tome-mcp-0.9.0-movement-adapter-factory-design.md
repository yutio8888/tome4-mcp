# Movement adapter factory / templates (0.9.0 investigation)

Status: **proposal only**. Baseline: `main` at
`ba48e7e65d9a9b74f4172d39405ae94647e556da` (2026-09-17). This document does
not change product code, game state, `allow_auto_combat_execution`, or the
strategy/capability boundary.

## 1. Recommendation

Add a closed, source-reviewed `MovementAdapterFactory` that expands a small
template plus talent-specific parameters into the existing `movement` leaf
descriptor. Keep an explicit manifest entry for every admitted talent. Do **not**
try to discover and admit movement talents by inspecting `is_teleport`, target
shape, or talent name.

**Use the game's live getters/builders as normal entrypoints, with no strict
audit.** Planning calls the actual `t.target`/`getTalentTarget`/`getTalentRange`/
`getTalentLevel`/... functions to obtain geometry. Because Lua is dynamic any
function may be replaced by another addon; the project cannot and does not
guarantee that a runtime entry is the pristine native implementation, and is
**not responsible for other plugins' broken implementations**. So there is **no
identity/digest/closure gate**: a getter that errors, is missing or returns `nil`
simply means the value is not obtainable (`movement_derivation_unknown`/
`unknown`) and the action is unavailable. The live builder still cannot establish
actor-versus-grid semantics or the order of prompts built inside `action`, so
those stay **curated**; the source review of the action and its branches remains
the largest manual step for each new talent.

This preserves the anti-goal “no generic all-teleport adapter”: the current
contract requires every prompt to be represented by a source-reviewed, curated
target plan, and current execution rejects multi-prompt plans rather than guessing
(`docs/tome-mcp-0.9.0-movement-skills-design.md:186-212`;
`overload/mod/auto_combat/MovementPlanner.lua:390-415`).

## 2. Verified current state

- The three admitted movement leaves are hand-written entries for Rush, Tumble,
  and Phase Door; each records `target_requests`, `delivery`, `landing`, `center`,
  `traverses`, and `relocates_other`. Phase Door also has a coarse TL4+
  unsupported variant (`overload/mod/auto_combat/EffectManifest.lua:233-256`).
- The structured gap list names Blink Rune, Vault, Dimensional Step, Shadowstep,
  Giant Leap, Displacement Shield, and moving/swapping another actor as adapter
  or execution-capability gaps, not tactical refusals
  (`overload/mod/auto_combat/EffectManifest.lua:264-287`).
- Plain policy `move` is already talent-independent: selectors are generic and
  deterministic, while talent selectors reuse the same data vocabulary
  (`overload/mod/auto_combat/MovementPlanner.lua:29-52`). No factory entry is
  needed for an ordinary step.
- Policy schema accepts an ordered target plan, but the planner currently drives
  exactly one request and returns typed `unsupported_target_plan` for a longer
  plan (`overload/mod/auto_combat/PolicySchema.lua:267-310`;
  `overload/mod/auto_combat/MovementPlanner.lua:302-361,396-404`).
- Runtime lowers a grid plan to native `force_grid` and an actor plan to native
  `force_actor` (`overload/mod/mcp_bridge/Runtime.lua:1294-1313`). Engine
  `force_target` replaces `getTarget` for the whole talent action, returning
  either coordinates plus the actor or coordinates with no entity
  (`game/engines/default/engine/interface/ActorTalents.lua:152-165,179-202`).
  The alternate bridge prefill seam answers only the first `getTarget` and then
  restores native targeting (`overload/mod/mcp_bridge/Actions.lua:217-280`).
- Source files are MD5-pinned, builder source/definition lines are generated,
  and live builder objects are checked by source line plus `rawequal`; the
  recorded result is emitted as `adapter_source_drift` telemetry
  (`tools/generate_effect_manifest.py:27-84,110-145`;
  `overload/mod/auto_combat/EffectManifestDrift.lua:1-13,32-59,61-115`). **Under
  the §1/§3.1 live-getter boundary this signal is advisory telemetry only**: a
  replaced-but-working object must not disable the action, and only a
  missing/throwing/`nil`/invalid return may.
- The current guard records drift telemetry and then skips every movement entry
  because the first tranche has no movement/effect composition path
  (`overload/mod/auto_combat/AutoCombatGuard.lua:181-192`). Consequently, adding
  damage components to Shadowstep or Giant Leap without changing that branch
  would silently leave those effects unguarded.

## 3. What runtime derivation can and cannot prove

### 3.1 Live-getter boundary (v1.6): no strict audit

Planning calls the game's actual builder/getter functions directly
(`t.target`/`getTalentTarget`, `getTalentRange`, `getTalentLevel`, `getStat`,
spell-power helpers, ...) to obtain geometry and scalar parameters. There is **no
identity/digest/closure gate** on them.

- Lua is dynamic: any function may be replaced by another addon at runtime. The
  project **cannot and does not guarantee** that a runtime entry is the pristine
  native implementation, and is **not responsible for other plugins' broken
  implementations**. Requiring proof of an unbounded transitive closure is both
  impossible and out of scope.
- A getter that **errors, is missing, or returns `nil`** means the value is not
  obtainable → `movement_derivation_unknown`/`unknown` and the action is
  unavailable. This is a real "value not obtainable" condition, **not** a purity
  or identity claim.
- Source digests/identity may be retained as an **advisory re-review hint or
  optional telemetry**, but they are **never a runtime gate**.
- It must not call `useTalent` or `t.action` as a discovery probe.
### 3.2 Feasibility by class

| Class | What the builder reveals | What it does not reveal | Conclusion |
| --- | --- | --- | --- |
| No-prompt self teleport | Phase Door has no `t.target`, but its action conditionally creates an actor prompt at effective TL4 and a grid prompt at TL5 or when `phase_door_force_precise` is set (`game/modules/tome/data/talents/spells/conveyance.lua:65-84,104-147`). | Builder absence does not prove prompt absence, request order, mover, or landing envelope. | `{"none"}` must remain a curated, state-scoped request program. |
| Actor charge | Rush's builder returns a `bolt` cursor, while the action separately requires the returned entity to be a creature and computes a line landing before it (`game/modules/tome/data/talents/techniques/combat-techniques.lua:35-67`). | `type="bolt"` does not mean “actor request”; that semantic comes from the action's entity check. | Derive live geometry only; curate `actor` and `actor_charge`. |
| Grid blink | Blink's builder returns `type="hit"`; the action consumes the coordinates, ignores the returned entity, checks LOS/terrain/projection, and calls `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/misc/inscriptions.lua:646-680`). | `type="hit"` alone cannot distinguish grid from actor semantics. | Derive range/flags; curate `grid` and its landing helper. |
| Exact grid move | Tumble's builder is a `beam`, but the action treats its result as a landing coordinate and moves exactly there after native checks (`game/modules/tome/data/talents/techniques/acrobatics.lua:127-173`). | Cursor shape is not the movement request kind or landing classification. | Curate `grid_move_exact`; use the builder for conformance. |
| Grid-or-actor variant | Dimensional Step also uses `type="hit"`; an empty grid takes the self-teleport branch, while a TL5 actor may take a two-actor swap branch (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:22-81`). | The builder does not encode the TL5 occupancy-dependent semantic branch. | Curate variants; an unknown occupant cannot be resolved through hidden-state reads. |
| Actor-anchored teleport | Shadowstep uses `type="hit"`, requires an entity in the action, teleports around its coordinates, and attacks only if the final position is adjacent (`game/modules/tome/data/talents/cunning/shadow-magic.lua:109-152`). | The builder does not encode the entity requirement, fallback radius, or conditional attack. | Curate request, landing envelope, and effect components. |
| Request then landing | Phase Door builds its actor target table and later its landing target table locally inside `action`, in that order (`game/modules/tome/data/talents/spells/conveyance.lua:78-114,132-147`). | A call to `getTalentTarget` observes neither prompt and cannot discover their order. | The complete variant-specific sequence stays manual. |

There is therefore no sound automatic classifier even for the listed classes.
The builder probe is a **conformance/value provider for a curated request**, not
the source of `target_requests`.

## 4. Proposed factory and resolved-leaf model

### 4.1 Closed declarations

Proposed manifest source shape (illustrative Lua, not product code):

```lua
T_BLINK_RUNE = movementAdapter("grid_move_bounded", {
  delivery = "teleport",
  radius = {helper="teleportRandom_precise_fallback", value=5},
  traverses = false,
  builder = {required=true, request="grid"},
  components = { -- manually reviewed; not supplied by the template
    {id="out_of_phase", phase="secondary", target="self"},
  },
})
```

`MovementAdapterFactory.expand(template, params)` should be pure, reject unknown
keys, require a source record, and return either a static `movement` leaf or a
set of declarative variants. It must never scan learned talents or infer a
template from live flags. The static manifest remains the whitelist; the
existing catalog remains derived from it
(`overload/mod/auto_combat/EffectManifest.lua:289-335`).

A non-variant template expands directly to today's descriptor. A variant
template expands to:

```lua
movement = {
  variants = {
    {when={...audited scalar conditions...}, descriptor={
      target_requests={...}, delivery=..., landing=..., center=...,
      radius=..., min_radius=..., traverses=..., relocates_other=...,
    }},
  },
}
```

Immediately before planning, a `MovementVariantResolver` evaluates the allowed
conditions and returns exactly one descriptor in the **current** shape. Zero,
multiple, or indeterminate matches return a typed unknown; no ordering fallback
is allowed. This generalizes the current effective-level-only unsupported check,
which already fails closed when the level is unavailable
(`overload/mod/auto_combat/MovementPlanner.lua:282-299`).

### 4.2 Template taxonomy

All defaults below are mechanical, not strategic. Curated semantic source
coverage, builder mode, helper dependencies, variants, and non-movement
components are always explicit per talent (recorded identity/digest is
advisory metadata, not a gate).

| Template | Required parameters | Mechanical defaults | Resolved current `movement` mapping |
| --- | --- | --- | --- |
| `actor_charge` | `landing_proof`; optional effect components | `target_requests={'actor'}`; `delivery='line_move'`; `landing='bounded_alternatives'`; `center='actor'`; `traverses=true`; `relocates_other=false` | Direct mapping. Rush is the reference class; the source action computes the last legal line cell before the actor (`game/modules/tome/data/talents/techniques/combat-techniques.lua:48-83`). |
| `grid_move_exact` | `delivery`; explicit `traverses`; native rejection/postcondition notes | `target_requests={'grid'}`; `landing='exact'`; `center='requested_grid'`; `relocates_other=false` | Direct mapping. Tumble and Vault differ in delivery/prerequisites, not descriptor shape (`game/modules/tome/data/talents/techniques/acrobatics.lua:61-117,160-182`). |
| `grid_move_bounded` | `delivery`; finite `radius` or audited radius getter; alternate-selection helper; explicit `traverses` | `target_requests={'grid'}`; `landing='bounded_alternatives'`; `center='requested_grid'`; `relocates_other=false` | Direct mapping. Use for `teleportRandom(...,0)` and occupied-cell leap fallback; annotate native random tie-break separately. |
| `self_random_teleport` | finite radius getter/value and its helper proof; optional minimum | `target_requests={'none'}`; `delivery='teleport'`; `landing='random'`; `center='self'`; `min_radius=0` only when the reviewed native call omits it; `traverses=false`; `relocates_other=false` | Direct mapping after dynamic values resolve. Phase Door's radius comes from `t.getRange`, not from the cursor range (`game/modules/tome/data/talents/spells/conveyance.lua:74-76,104-107,146-148`). |
| `actor_anchor_teleport` | finite radius/getter; post-landing relation; effect components | `target_requests={'actor'}`; `delivery='teleport'`; `landing='bounded_alternatives'`; `center='actor'`; `traverses=false`; `relocates_other=false` | Direct mapping for self movement around an actor. Shadowstep is the reference class (`game/modules/tome/data/talents/cunning/shadow-magic.lua:127-149`). |
| `request_then_landing` | complete ordered request list per variant; subject request; every landing branch/envelope; explicit `relocates_other`; prompt-response validation | No request order, center, bounds, or subject defaults | Each resolved variant becomes the current leaf. Execution remains unavailable until an ordered prompt-response queue exists. Phase Door TL5 is the reference class (`game/modules/tome/data/talents/spells/conveyance.lua:82-147`). |
| `swap` | request kind; both actor identities; hit/resist/fizzle branches; two-actor destination relation; postconditions | `delivery='teleport'`; `relocates_other=true`; no landing or request defaults | **Cannot map losslessly to today's single-subject descriptor.** Keep typed unsupported until the descriptor and executor model two subjects. Dimensional Step TL5 is the reference class (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:48-79`). |

`grid_move_bounded` deliberately covers both leap and teleport delivery; a new
template is justified only when it adds a reusable invariant, not merely a new
talent name. Conversely, `request_then_landing` is not a generic escape hatch:
it requires the entire prompt program and all branches to be curated.

### 4.3 Manual fields that do not belong in templates

The following remain per-talent review output:

- exact request semantics and order for every effective-level/attribute/occupancy
  variant; native cursor `type` is insufficient (§3.2);
- the mover/subject and whether another actor can be moved, removed, swapped, or
  restored on failure;
- landing cardinality and a finite envelope, including center, radius,
  `min_radius`, fallback centers, LOS-dependent fallback, and helper selection;
- whether movement traverses intervening cells or relocates directly;
- ground, instant, projectile, attack, secondary, and delayed components,
  including their center relative to the **actual** landing;
- every state condition that changes prompts or outcomes (effective talent level,
  attributes, target occupancy, inscriptions/modifiers, and helper overrides);
- semantic source coverage for the definition, action, builder, dynamic getters,
  and transitively relied-on helpers; recorded file digests, definition lines,
  and live-object identities are **advisory re-review/telemetry metadata**, not
  runtime gates (see §3.1); and
- native rejection, energy/pending semantics, and final postconditions.

These are execution semantics, not policy preferences. Templates may provide
field defaults only where the category itself proves them.

## 5. Landing envelopes and mixed effects

ToME's module override for `teleportRandom(x,y,0)` first calls
`findFreeGrid(x,y,5,...)` (`game/modules/tome/class/Actor.lua:1631-1647`).
`findFreeGrid` chooses a closest candidate and uses RNG among equal-distance
candidates (`game/engines/default/engine/utils.lua:2943-2981`), after which
`teleportRandom` again makes a native random choice from its candidate set
(`game/modules/tome/class/Actor.lua:1652-1687`). The factory should therefore
classify these calls as `bounded_alternatives`, radius 5, with a
`native_random_tie_break` annotation—not as exact merely because the call's
`dist` argument is zero.

The envelope must be conservative and finite. Uncertain occupancy, hazard, or
which point inside a proven envelope native code chooses is policy information;
it remains annotated and is evaluated by `destination.accept`. An unresolvable
envelope is different: the executor cannot check the final postcondition, so the
adapter is unavailable before commit.

Mixed movement/effect talents need two production changes before their templates
can be executable:

1. `AutoCombatGuard` must skip only component-free movement, or introduce an
   explicit `movement_effect` composition path; the current unconditional skip is
   at `overload/mod/auto_combat/AutoCombatGuard.lua:188-192`.
2. Effect component centers must be able to name `actual_landing`, and the guard
   must conservatively union footprints over every possible pre-commit landing.
   Giant Leap moves first and projects its radius-one effect around the resulting
   player position (`game/modules/tome/data/talents/uber/str.lua:41-71`).

If that union or its player-known friendly occupancy cannot be evaluated, the
effect side fails closed. Known risk is still compared with the policy threshold;
it is not a global tactical veto
(`docs/tome-mcp-auto-combat-plugin-design.md:268-283,407-415`).

## 6. Fail-closed and policy-annotation rules

### 6.1 Typed outcomes

| Condition | Proposed typed result | Scope |
| --- | --- | --- |
| Unknown template, missing required parameter, or malformed expansion | `movement_adapter_invalid` | Build/test failure; never publish the adapter. |
| Builder/action/getter/helper missing, throwing, returning `nil`, or wrong type | `movement_derivation_unknown` with `dependency` detail (a replaced live object is only telemetry; its usable return value decides) | Disable this action before commit. |
| Builder is valid but request kind is not curated | `movement_request_kind_unknown` | Disable this action; never infer actor/grid from cursor shape. |
| No variant, multiple variants, or a level/attribute read that errors or returns `nil` | `movement_variant_unknown` with the unresolved condition | Disable this action before commit. |
| Policy target plan differs in length/order/kind | existing `target_plan_mismatch` / `target_plan_selector_mismatch` | Policy validation error or action denial. Existing exact comparison is at `overload/mod/auto_combat/EffectManifest.lua:427-456`. |
| Adapter declares a valid multi-prompt plan but executor lacks the queue | existing `unsupported_target_plan`, `scope='multi_prompt'` | Capability pause/denial before commit (`overload/mod/auto_combat/MovementPlanner.lua:396-400`). |
| Native asks for an extra, missing, reordered, or wrong-kind prompt after commit starts | `unexpected_target_request` with expected/observed index | Pause the executor, do not resubmit, and hand the live interaction back if safely possible. |
| Landing kind/center/bounds cannot be proved | `movement_landing_envelope_unknown` | Disable this action before commit. |
| Actual mover or endpoint falls outside the resolved descriptor after commit | `movement_postcondition_mismatch`, `uncertain=true` | Pause the executor; this is a real postcondition failure, not normal randomness. |
| Template needs to move/swap another actor but the typed capability is absent | `moving_or_swapping_another_actor` | Publish as unsupported capability. |
| Mixed effect footprint cannot be computed | existing effect-footprint unknown/rejection with component detail | Disable this action only. |

Once request program, semantic coverage, and landing envelope are established,
`visible=false`, `passable='unknown'`, `hazard='unknown'`, and a native-random
choice are annotations. `MovementPlanner.accepts` already treats visibility,
passability, hazard, and deterministic-vs-nondeterministic landing as explicit
policy filters (`overload/mod/auto_combat/MovementPlanner.lua:80-107`). A strict
policy may reject the same report that a permissive policy accepts; neither
outcome changes adapter capability.

### 6.2 Pre-commit versus post-commit

All static/derivation faults are resolved before `Actions.execute`. If the exact
native prompt sequence can be preflighted, a mismatch never starts the action.
If an adapted action has already yielded and then produces an undeclared prompt,
the controller enters waiting/pause and never submits the talent again. This
preserves the existing rule that `native_pending` is tracked without resubmission
(`overload/mod/mcp_bridge/Actions.lua:294-300`;
`docs/tome-mcp-auto-combat-plugin-design.md:256-263`).

## 7. Source records and advisory drift telemetry

### 7.1 Pin set

Extend the generated source record for each movement adapter with:

- whole-file MD5 plus talent definition line (already generated) — kept as an
  **advisory re-review hint/telemetry**, never a runtime gate;
- live `t.action`/`t.target` source/line (advisory);
- the live getters used by a parameter (`getRange`, `getRadius`,
  effective-level/state getters) are called directly at planning time with **no
  identity gate**; a missing/erroring getter yields `movement_derivation_unknown`;
- engine/module helpers invoked by the action (`canProject`, `teleportRandom`,
  `findFreeGrid`, ...) are ordinary calls; and
- the action-commit/targeting seams already recorded by `NativeCompatibility`
  (as advisory metadata; the project calls the live seam, it does not gate on it).

The present generator records semantic source coverage for complete engine
semantics files and selected talent builders
(`tools/generate_effect_manifest.py:63-84,125-143`); the drift checker may recheck
live builder identity as **telemetry** before a guarded action
(`overload/mod/auto_combat/EffectManifestDrift.lua:117-148`), but a mismatch is
reported, never used to deny an action. The proposed change extends the same
**review-metadata** mechanism to action/getter/helper records; it does not create
a separate trust system, and it introduces no runtime gate.

### 7.2 Runtime probe rules

The runtime probe calls the game's actual live getter/builder objects directly,
under `pcall`, and copies only allowlisted scalar/table fields. An error,
non-table builder result, non-finite bound, or `nil` value becomes typed unknown
and disables the one action. A replacement object, changed helper closure, or
source digest mismatch is **not** itself a denial: the probe simply uses the live
object and judges its usable return value. Recorded identity/digest information
is advisory re-review telemetry (§3.1).

No “purity” or RNG tripwire is added. Deterministic policy choice still uses
stable ranking, while the live native getters/builders may consume RNG under the
frozen read policy (`docs/tome-mcp-auto-combat-plugin-design.md:365-373,424-443`).

## 8. Candidate disposition

| Candidate / variant | Template and derived fields | Fields still curated | Disposition |
| --- | --- | --- | --- |
| `T_BLINK_RUNE` | `grid_move_bounded`; live builder supplies `range` and cursor flags. Resolved leaf: `{'grid'}`, `teleport`, `bounded_alternatives`, `requested_grid`, radius 5, `traverses=false`, `relocates_other=false`. The action calls `teleportRandom(x,y,0)` and then grants Out of Phase (`game/modules/tome/data/talents/misc/inscriptions.lua:646-680`); radius-5 fallback comes from `game/modules/tome/class/Actor.lua:1642-1647`. | Grid semantics; LOS/terrain/projection path; helper coverage; inscription-data-dependent secondary buff and its postcondition. | **Supportable with the factory** after source review and helper coverage. Native uncertainty is annotated, not refused. |
| `T_SKIRMISHER_VAULT` | `grid_move_exact` with `delivery='leap'`, `traverses=false`; builder supplies live beam/range. The action adds a launch-target check, rejects blocked/unprojectable landing, and moves exactly to the requested grid (`game/modules/tome/data/talents/techniques/acrobatics.lua:27-56,61-117`). | The adjacent visible launch-actor prerequisite is action-local; exact native rejection behavior and the post-move Directed Speed effect stay manual. | **Supportable with the factory**. Native prerequisite failure is a normal rejection, not a new strategy gate. |
| `T_DIMENSIONAL_STEP`, effective TL below 5 | `grid_move_bounded` with `delivery='teleport'`, radius 5 and live builder range. The non-swap branch calls `teleportRandom(x,y,0)` (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:22-46,73-84`). | Effective-level variant, requested-grid occupancy semantics, helper coverage, teleport callbacks/postcondition. | **Supportable for a source-proven non-swap variant**. If occupant status needed to choose the branch is player-unknown, return `movement_variant_unknown`; do not inspect a hidden actor. |
| `T_DIMENSIONAL_STEP`, TL5 actor target | `swap` candidate. The action may remove the target, teleport the caster, move the target to the old caster cell, or restore it on failure after resistance/hit checks (`game/modules/tome/data/talents/chronomancy/spacetime-weaving.lua:48-72`). | Both actor identities, probability/resistance branch, removal/restoration atomicity, two endpoints, effects, and postconditions. | **Remain unsupported** as `moving_or_swapping_another_actor` until typed two-actor execution and verification exist. |
| `T_SHADOWSTEP` | `actor_anchor_teleport`; builder supplies range/cursor. Leaf: `{'actor'}`, `teleport`, `bounded_alternatives`, `actor`, radius 5, no traversal/other relocation. The action requires a visible actor, uses precise teleport fallback, and attacks only when final adjacency is one (`game/modules/tome/data/talents/cunning/shadow-magic.lua:109-149`). | Radius-helper proof; attack/damage/daze components; conditional final-adjacency branch; component footprint from actual landing. | **Remain unsupported until movement/effect composition is implemented**; then it becomes a compact template declaration. |
| `T_GIANT_LEAP` | `grid_move_bounded` with `delivery='leap'`, radius 1, `traverses=false`. It uses the requested grid when empty and `findFreeGrid(...,1)` when occupied, then moves (`game/modules/tome/data/talents/uber/str.lua:20-59`). | Occupancy branch, `findFreeGrid` helper pin, radius-one weapon/daze effect centered on actual landing, and unioned pre-commit footprint (`game/modules/tome/data/talents/uber/str.lua:61-71`). | **Remain unsupported until movement/effect composition and `actual_landing` footprint unions exist**. |
| `T_DISPLACEMENT_SHIELD` | No movement template. It selects an actor and installs a damage-transfer shield; it does not relocate the player when activated (`game/modules/tome/data/talents/spells/conveyance.lua:286-321`). | Delayed damage redirection, target lifecycle, chance, capacity, duration, and effect semantics. | **Remain a source-reviewed effect-adapter task**, outside this factory. |
| Phase Door, effective TL below 4 and no precise attribute | `self_random_teleport`; `{'none'}`, `teleport`, `random`, `self`, radius from live `t.getRange`, default native minimum 0, no traversal/other relocation. The native call uses `target:teleportRandom(x,y,range)` (`game/modules/tome/data/talents/spells/conveyance.lua:74-78,104-107,146-148`). | Exact variant condition, dynamic range getter, helper coverage, final envelope/postcondition. | **Already conceptually supported, but the current fixed `radius=6,min_radius=1` should be replaced or proven for every admitted state** (`overload/mod/auto_combat/EffectManifest.lua:246-255`). |
| Phase Door, precise attribute below TL4 | `request_then_landing` resolved to `{'grid'}` with subject self; landing is random around the requested grid with radius `getRadius`, with the source's LOS-dependent broad fallback (`game/modules/tome/data/talents/spells/conveyance.lua:71-72,104-147`). | Attribute predicate, both envelopes, LOS/fizzle branch, prompt table. | **Supportable after this state variant is declared**. Current level-only unsupported gating does not cover it. |
| Phase Door, TL4 only, subject self | `request_then_landing` resolved to `{'actor'}` and a random landing; the actor response is self. The actor prompt begins at TL4, while the grid prompt begins at TL5 or under the precise attribute (`game/modules/tome/data/talents/spells/conveyance.lua:82-108`). | Subject binding, random center/range, effective-level and attribute matrix. | **Supportable as a single-prompt self-subject variant** after explicit source review. Selecting another actor remains the multi-actor gap. |
| Phase Door, TL5+, subject self | `request_then_landing` with ordered `{'actor','grid'}`. Controlled landing uses the requested center and `getRadius`; an out-of-LOS fizzle can switch to a broad random envelope centered on the caster (`game/modules/tome/data/talents/spells/conveyance.lua:82-147`). | Exact request order, subject, two landing envelopes, fizzle condition/probability, dynamic getters. | **Supportable only after ordered prompt-response execution exists**. Randomness is policy-annotated; it is not the blocker. |
| Phase Door, TL4/TL5 subject other than self | Same request variants, but the selected target is relocated and receives continuum destabilization (`game/modules/tome/data/talents/spells/conveyance.lua:95-103,146-153`). | Mover identity, resistance/fizzle, target effect, and other-actor postcondition. | **Remain unsupported** as `moving_or_swapping_another_actor`. |

The Phase Door source requires a two-dimensional variant matrix: effective level
and `phase_door_force_precise`. The current single `at_least=4` rule is not enough
because the attribute forces the grid prompt at lower levels
(`game/modules/tome/data/talents/spells/conveyance.lua:71-72,82-108`). An unknown
level or unknown attribute must produce `movement_variant_unknown`; selecting the
no-prompt leaf would be unsafe.

## 9. Verification plan

### 9.1 Pure fixtures

1. Expand every template twice and deep-compare canonical output. Vary map/table
   insertion order and assert byte-equivalent normalized descriptors.
2. For every template, reject unknown keys, missing required parameters,
   non-finite/negative envelopes, invalid request kinds, and forbidden defaults.
3. Feed the same `type="hit"` builder fixture to actor-required, grid-only, and
   grid-or-actor curated declarations. Assert the builder never changes the
   declared semantic request kind.
4. Test builder table/function success plus missing, throwing, non-table, `nil`,
   NaN, and out-of-range results. Each fault must have the expected typed outcome;
   a replaced-but-working object still yields a usable value.
5. Resolve the full Phase Door level/attribute matrix, including unknown level,
   unknown attribute, zero matches, and overlapping matches. Only one descriptor
   may emerge.
6. Verify policy plans against every resolved request sequence, including
   actor/grid reversal, missing response, extra response, selector contradiction,
   and the current `unsupported_target_plan` capability case.
7. Exercise exact, bounded, and random envelope containment. An endpoint outside
   the envelope must become `movement_postcondition_mismatch`; a valid random
   endpoint must not.
8. Verify mixed component footprints are unioned over all possible landing cells
   and centered on `actual_landing`; an unknowable footprint disables only that
   action.
9. Replace action, builder, getter, `teleportRandom`, and `findFreeGrid` objects
   with working replacements and mutate recorded file digests. Assert the adapter
   **still executes** (calls the live object) and that changed telemetry raises a
   re-review signal; only a missing/throwing/`nil`/invalid result disables the one
   action.
10. Supply identical movement reports to strict and permissive `accept` objects.
    Assert only the policy result changes; capability and annotation remain the
    same.
11. Assert derivation/dry-run never invokes `useTalent`, `t.action`, `move`,
    `teleportRandom`, or another action entrypoint and never queries hidden actor
    occupancy. Calling live getters/builders is allowed and may consume RNG.
12. For the ordered executor, assert one action opportunity, one native
    submission, exact response consumption by index/kind, and no resubmission
    while pending.

### 9.2 Per-talent source-review checklist

For each new declaration, record:

- talent ID, game version, definition/action/builder/getter/helper paths and lines
  (advisory review metadata; recorded digests/live identities are telemetry only);
- every prompt and exact order for each effective-level/attribute/occupancy
  variant, including the entity value returned with coordinates;
- mover, requested center, native projected center, all exact/alternate/random
  landing branches, finite bounds, traversed cells, and other actors moved;
- all immediate, secondary, ground, delayed, callback, and post-landing effects;
- which branch predicates are player-known and which become `unknown`;
- native pre-use, range, LOS, `canProject`, rejection, energy, cooldown,
  pending/interaction, and callback behavior;
- pre-commit movement/effect report and policy acceptance fields; and
- final postconditions for success, native rejection, fizzle, resistance, and
  integrity mismatch.

The checklist is the irreducible manual work. A template removes repeated Lua
shape declarations, not the need to understand the native action.

### 9.3 Native source and packaged-`dist` probes

Run each scenario against the production source tree and the packaged `.teaa`,
record the package SHA-256 and loaded manifest/source digests as **advisory build
provenance**, and compare the same semantic signals. Existing acceptance already treats source and `dist` as
separate evidence and requires settled final movement postconditions rather than
mere submission (`VALIDATION.md:18-21,43`).

Every scenario must capture the observed prompt sequence and response kind **and**
settle to a final postcondition:

- Blink: one grid response; final self position lies in the declared radius-5
  envelope; Out of Phase postcondition matches the reviewed branch.
- Vault: one grid response; legal launch setup lands exactly on the requested
  grid and applies Directed Speed; missing-launch and blocked-grid setups reject
  without relocation.
- Dimensional Step: below-TL5 empty-grid case lands within the precise-fallback
  envelope; TL5 swap probes separately assert both actors' final locations on
  success and restoration/no-move branches on resistance/fizzle.
- Shadowstep: one actor response; final location is inside its envelope; attack
  and daze occur only when the final adjacency condition holds.
- Giant Leap: empty destination lands exactly; occupied destination stays within
  radius one; damage/daze footprint is centered on the actual final landing.
- Phase Door: exercise every level/attribute request sequence, self versus other
  subject, controlled versus LOS-fizzle envelope, and actual mover identity.
- Displacement Shield: verify no activation-time relocation and separately test
  the delayed transfer effect if/when its effect adapter is designed.
- Negative probes: missing/throwing/`nil`/invalid getter result, extra/reordered
  prompt, unknown variant input, out-of-envelope final location, owner/revision
  loss, and manual takeover all prevent further automated submission. Recorded
  source drift or live-object replacement is captured as telemetry only and must
  not on its own stop an otherwise valid action.

Sampling many random endpoints is not a proof of the envelope. The proof comes
from the curated semantic record of the source/helper behaviour; probes verify
that production lowering and postcondition instrumentation match that proof.

## 10. Anti-goals and genuine unsupported cases

- No scan that auto-admits talents because `is_teleport`, `requires_target`, or a
  cursor `type` resembles a known talent. The source examples in §3.2 show those
  signals are semantically ambiguous.
- No arbitrary modded talent admitted without review. Until curated it remains
  `unsupported_adapter`; once curated the adapter calls
  the **live** entry, and a later replacement is another addon's concern (the
  project is not responsible for other plugins' broken implementations).
- No movement whose request order, mover, finite landing envelope, or final
  postcondition cannot be established. This is execution non-determinability,
  not a judgment that the tactic is unsafe.
- No moving or swapping another actor until typed subject identities, two-actor
  destinations, restoration/failure branches, effects, and postconditions are
  implemented.
- No mixed movement/effect talent whose footprint cannot be computed over all
  possible landings. Known non-zero risk is reported and policy-controlled;
  uncomputable risk disables that action.
- No hidden-occupant or hidden-terrain probe to select a variant or improve a
  destination. Player-unknown facts remain unknown and native collision remains
  final authority (`docs/tome-mcp-0.9.0-movement-skills-design.md:242-272`).
- No direct calls from auto-combat to `move`, `teleportRandom`, or talent actions.
  Execution continues through `Actions` / native `useTalent` (the actual live
  entrypoints; see §3.1)
  (`docs/tome-mcp-0.9.0-movement-skills-design.md:334-347`).

Random landing, out-of-vision requests, retreat, kiting, and teleportation are
not anti-goals. Once a curated adapter establishes the execution envelope, those
facts are annotated and the data policy decides whether to accept them
(`docs/tome-mcp-auto-combat-plugin-design.md:18-28,407-415`).

## 11. Required contract clarification

The movement design currently says known bounds are recorded and missing bounds
appear as `unknown`, while still allowing audited random teleport
(`docs/tome-mcp-0.9.0-movement-skills-design.md:283-300`). This factory needs to
distinguish “unknown endpoint inside a proven envelope” from “unknown envelope,”
because only the former has a checkable postcondition.

Recommended exact addition after that paragraph:

> A stochastic endpoint is not an execution-integrity failure when the
> curated, source-reviewed adapter establishes the mover, request sequence,
> landing class, and a
> finite conservative landing envelope; visibility, occupancy, passability,
> hazard, and the chosen point inside that envelope may remain `unknown` and are
> reported to policy. If the adapter cannot establish the mover, request order,
> or any finite conservative envelope needed to verify the final postcondition,
> the action is unavailable with a typed movement capability/derivation reason.
> This is not a strategy refusal and does not make other complete actions
> unavailable.

Also replace the Phase Door level-only capability description with an explicit
effective-level **and** `phase_door_force_precise` variant matrix; the native
source makes the grid prompt depend on either TL5 or that attribute
(`game/modules/tome/data/talents/spells/conveyance.lua:71-72,104-114`).

## 12. Top uncertainties for implementation

1. Whether the first implementation should add the ordered prompt-response queue
   immediately or ship only single-prompt templates first. This changes Phase
   Door TL5 scope, but not the factory model.
2. The exact typed representation for mover/subject and `actual_landing` effect
   centers. The current descriptor is adequate for self-only movement but cannot
   losslessly represent swaps.
3. Whether TL5 Dimensional Step should admit a grid-only branch only when the
   requested cell is player-known empty, or wait entirely for the swap-capable
   descriptor. A hidden occupant must not be queried to answer this.
4. Which self-only secondary effects require full effect-manifest components
   versus postcondition-only metadata. Harmful/mixed effects cannot use the
   current unconditional movement guard skip.


## 13. Delivery slices (roadmap)

The movement work is delivered in four slices. Each slice is a
branch + PR that goes through an independent review before merge; the next slice
starts only after the previous one is accepted.

| Slice | Scope | Reference |
| --- | --- | --- |
| **S1 (first slice)** | Closed `MovementAdapterFactory` + **single-prompt** templates (`actor_charge`, `grid_move_exact`, `grid_move_bounded`, `self_random_teleport`, `actor_anchor_teleport`) expanding into the current `movement` descriptor; the **Phase Door effective-level x `phase_door_force_precise` variant matrix** (fixes the level-only gating gap); semantic source coverage and advisory drift telemetry (no runtime gate). Candidates admissible after source review: Rush, Tumble, Phase Door no-prompt/precise-attribute, Blink Rune, Vault, Dimensional Step **non-swap**. | §4.1, §4.2, §8 |
| **S2** | `request_then_landing`: the **ordered prompt-response queue** for multi-prompt talents (Phase Door TL4/TL5 actor-then-grid, and other actor+grid skills). | §4.2, §12.1 |
| **S3** | **Movement/effect composition**: movement talents whose landing also carries a harmful/beneficial effect (Shadowstep, Giant Leap): compose the movement report with the effect/selffire guard, union the `actual_landing` footprint, and stop skipping movement entries in the guard. | §2 (finding 2), §5 |
| **S4** | **`swap` / moving or swapping another actor**: typed two-subject descriptor, executor and verification (Dimensional Step TL5, the `moving_or_swapping_another_actor` gap). | §4.2, §12.2 |

Separate, non-movement item: **Displacement Shield** (actor-target damage-transfer
shield that does not relocate the player) is an effect-adapter task, outside this
factory (§8).

### 13.1 Per-slice live-test scenarios (maintainer-specified)

Each slice's live test is dispatched as a `[Test]` agent **after that slice merges**,
with the merged build pins filled in. The test agent only plays/reports; raw
evidence stays under `tmp/`.

- **S1 — Berserker / Trollmire 1–2 / Rush.** Halfling Berserker (`berserker_p2`),
  Insane/Roguelike; **must learn `T_RUSH` at level 1 and actually use it in real
  combat**; clear Trollmire levels 1 and 2, then stop. (See
  `tmp/mcp-play-support/movement-playtest-handoff.md`.)
- **S2 — Archmage / Phase Door to effective TL5.** Archmage (`archmage_arcane_p2`),
  learn and level `T_PHASE_DOOR` up to **effective talent level 5**, then exercise
  the ordered prompt-response queue in play (actor prompt then grid/landing prompt)
  and report the observed request sequence + landing annotation and postcondition;
  then stop. Verifies multi-prompt execution, not strategy.
- **S3 — debug Shadowblade / Shadowstep vs a training dummy.** Debug character
  `Shadowblade`, learn `T_SHADOWSTEP`, attack a **training dummy** (傀儡) to exercise
  the movement-talent path with its attack/damage component; report the movement +
  effect composition (guarded effect, `actual_landing` footprint) and the native
  postcondition; then stop. Verifies S3 (movement/effect composition).
- **S4 — Temporal Warden / Dimensional Step TL5 / successful swap.** Temporal Warden,
  learn `T_DIMENSIONAL_STEP` to **effective talent level 5**, then **successfully
  swap position with a monster** (two-subject swap) and report both actors'
  post-positions and effects; then stop. Verifies S4 (`swap` / moving another actor).

S3/S4 live tests use the test-only fixtures in
`docs/tome-mcp-0.9.0-movement-test-fixtures.md` (Shadowblade + training dummy;
Temporal Warden + swap monster).

Sequencing: S1 → S1 live test → S2 → S2 live test → S3 → S3 live test → S4 → S4 live
test; order may be re-prioritised by the maintainer. None of them authorises
execution by default (`allow_auto_combat_execution` stays `false`).

**Post-acceptance (maintainer):** after **all four slices are accepted and merged**,
resume the **regular test subagent** with a **Halfling / Celestial-Anorithil
(星月术士)** Insane/Roguelike run on the merged build (standard metrics) to
re-validate the whole plugin on the pilot build after the movement work.
