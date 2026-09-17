# Movement adapter factory — S1 implementation (0.9.0)

Status: **implemented on `feat/movement-adapter-factory`**, ready for review.
This document records what S1 of
`docs/tome-mcp-0.9.0-movement-adapter-factory-design.md` §13 actually built,
the closed template/variant model, the admitted talents, the typed unsupported
entries, and the evidence.

## 1. Scope

S1 delivers the closed `MovementAdapterFactory`, the **single-prompt** templates,
the **Phase Door effective-level x `phase_door_force_precise` variant matrix**
(fixing the old level-only gate), and source identity pins + drift for the new
descriptors. It does **not** implement the ordered prompt-response queue (S2),
movement/effect composition (S3) or moving/swapping another actor (S4).
`allow_auto_combat_execution` stays `false`.

## 2. Closed factory

`overload/mod/auto_combat/MovementAdapterFactory.lua` is pure data + pure
helpers. It never scans learned talents, `is_teleport`, a cursor shape or a
talent name; every admitted talent keeps an explicit manifest entry.

- `M.expand(template, params)` expands one of five closed templates into the
  existing `movement` descriptor. Template mechanical invariants (request kind,
  delivery, landing class, centre, traversal, relocation) are **fixed** and
  cannot be overridden; only the design §4.2 per-talent fields are
  parameterizable, and nested getter/condition records are closed. It rejects
  unknown templates/keys, fixed-field overrides, missing required parameters,
  non-finite/negative envelopes and wrong types with `movement_adapter_invalid`.
  - `actor_charge` → `{'actor'}`, `line_move`, `bounded_alternatives`, `actor`.
  - `grid_move_exact` → `{'grid'}`, exact, `requested_grid`.
  - `grid_move_bounded` → `{'grid'}`, finite radius/getter, bounded alternatives.
  - `self_random_teleport` → `{'none'}`, `teleport`, `random`, `self`.
  - `actor_anchor_teleport` → `{'actor'}`, `teleport`, bounded alternatives.
- `M.matrix(branches, axes)` builds a closed state-variant matrix. `axes` are
  condition records always resolved before branch selection, so an unknown axis
  is `movement_variant_unknown` even when no branch would test it. A branch is a
  template expansion or a reviewed `unsupported` capability entry with a typed
  runtime reason.
- `M.resolveVariant(movement, talent, reads)` returns exactly one descriptor.
  Zero matches, multiple matches or an indeterminate condition/axis return
  `movement_variant_unknown`; a known unimplemented branch returns its declared
  typed runtime reason (Phase Door TL4+ → `unsupported_target_plan`). There is no
  ordering fallback.
- `M.resolveBounds(...)` resolves `{getter='getRange'}` envelopes through the
  injected audited getter; a missing/erroring/non-finite value returns
  `movement_derivation_unknown`.
- `M.resolveBuilder(...)` calls the pinned target builder for **live geometry/
  conformance only** and copies an allowlisted `shape`/`range`/`radius`. A wrong
  or missing builder shape is `adapter_source_drift`/`movement_derivation_unknown`.
  The builder never supplies actor/grid semantics or prompt order.
- `M.resolveOccupancy(...)` turns a player-known `'empty'|'actor'|'unknown'` read
  into the admitted non-swap descriptor, the typed S4 gap, or
  `movement_variant_unknown` (never probing a hidden actor).

`MovementPlanner.plan` runs an injected `provider.preflight` **before any variant,
bound or builder read**, then resolves the matrix, bounds, builder and occupancy
before any request/landing classification. `MovementPlanner.planTalent` uses the
live finite builder range for `toward`/`away`/`preferred_distance` (an unknown
range is `movement_range_unknown`, never a hard-coded scan), and annotates a
bounded/random grid landing as `bounded`/`random`.

## 3. Phase Door variant matrix

| effective level | `phase_door_force_precise` | resolved requests | landing | disposition |
| --- | --- | --- | --- | --- |
| `< 4` | absent | `{'none'}` | random self, `t.getRange` | driven |
| `< 4` | present | `{'grid'}` | bounded around requested grid, `t.getRadius`, self-centred `t.getRange` LOS fallback | driven |
| `>= 4` | known (either) | `{'actor'}` / `{'actor','grid'}` | — | `unsupported_target_plan` (`scope='multi_prompt'`, S2), which both controllers pause on |
| any | unknown | — | — | `movement_variant_unknown` (both axes pre-read) |

The old fixed `radius=6, min_radius=1` is replaced by the audited dynamic
getters `t.getRange` (no-prompt) and `t.getRadius` (precise grid), with a
`{getter=...}` declaration and a finite resolution. An unavailable getter is a
typed derivation unknown, never a fabricated constant.

## 4. Admitted vs unsupported (S1)

Admitted (explicit manifest entry + template + pins):

- `T_RUSH` — `actor_charge`.
- `T_SKIRMISHER_CUNNING_ROLL` (Tumble) — `grid_move_exact`, `line_move`.
- `T_SKIRMISHER_VAULT` — `grid_move_exact`, `leap`, no traversal.
- `T_DIMENSIONAL_STEP` — `grid_move_bounded` (radius 5). Below effective TL5 it
  is the non-swap teleport; at TL5 it is occupancy-dependent (a player-known
  empty grid is the same non-swap branch; a known occupied grid is the S4 swap
  gap; unknown occupancy fails closed without probing a hidden actor).
- `T_PHASE_DOOR` — no-prompt and precise-grid variants per §3.

Structured unsupported (typed reason, never a strategy refusal):

- `T_PHASE_DOOR` TL4+: `actor_then_grid_target_plan` published as
  `unsupported_target_plan` (S2 queue).
- `T_DIMENSIONAL_STEP` TL5 occupied grid: `moving_or_swapping_another_actor`
  (S4).
- `T_BLINK_RUNE`: `stable_native_talent_id` — the native inscription id is
  slot-indexed (`T_RUNE:_BLINK_1..6`), so there is no single stable id to pin.
  This is an id/capability gap, not a refusal of the tactic.
- `T_SHADOWSTEP`, `T_GIANT_LEAP`: movement/effect composition (S3).
- `T_DISPLACEMENT_SHIELD`: effect-adapter task, no player relocation.

## 5. Source identity and drift

`tools/generate_effect_manifest.py` now also pins, for movement talents:

- `action={path,line}` for every movement talent;
- `getters={getRange=..., getRadius=...}` for every dynamic envelope getter.

`EffectManifestDrift.identity` verifies the live `def.action` and `def[name]`
objects by source path/line and first-seen `rawequal` identity (same mechanism as
the target builder), and a movement entry without an action pin fails closed
(`action_unpinned`). A replaced action/getter returns `adapter_source_drift`.
`teleportRandom` / `findFreeGrid` are transitively pinned by the existing
`actor.lua` / `utils.lua` engine file hashes.

**Audit ordering (MAF-REV-02).** The planner now calls `provider.preflight` —
the same `EffectManifestDrift.ensure` the guard uses — **before** any variant,
bound or builder read, in both live planning and dry-run. `getTalentLevel` and
`attr` are invoked through `NativeCompatibility` dependencies (the same
`actor.attr` id TalentQuery registers); the target builder and dynamic getters
are invoked only after `EffectManifestDrift.identity` has verified them.
`Runtime.autoCombatReads.plan` builds the provider; `buildAutoCombatHost` reuses
the same audited `manifestDrift`/`effectiveTalentLevel` for the guard.

## 6. Evidence

Final artifact: `dist/tome-mcp-bridge.teaa`
`d34bef117aa41d281f39ed07a121614fe229ea39ac76eb39f934e9549b9baff3`
(baseline `736fc9f6600443f3ac590db2af2a2e82c9171ed46547e9eb686b979a54a8aeae`).
`allow_auto_combat_execution` remains `false` (read-only unless explicitly set).

- `tests/test_auto_combat_movement_factory.lua` — 62 checks: every template's
  exact descriptor, closed-key/type/negative-envelope and **fixed-field override**
  rejections, closed nested getter/condition records, the full Phase Door matrix
  (both axes pre-read, TL4+ known attribute → `unsupported_target_plan`, either
  unknown input → `movement_variant_unknown`, overlap/no-match), the preflight
  ordering (no dynamic reader before the preflight), live builder
  shape/range/range-unknown, occupancy (empty/actor/unknown), bounded grid
  annotation and action/getter drift negatives.
- `tests/test_auto_combat_movement.lua` — the known Phase Door actor+grid rule
  drives the real planner through the controller and asserts the **paused**
  state with `unsupported_target_plan` and no native request.
- `tests/test_effect_manifest.lua`, `tests/test_effect_manifest_drift.lua`,
  `tests/test_runtime.lua` updated for the matrix/builder/occupancy model.
- Full Lua suite 41/41 green; Python 39/39; the three generator `--check` runs
  exit 0.
- Native probes (source + `dist`) settle the task and assert final postconditions:
  auto-combat probe 113/113 each (including `movement-talents:door-execute` for
  the Phase Door no-prompt branch and `movement-factory:*` for the precise-grid
  variant, the unknown-attribute fail-closed, the Dimensional Step empty/actor/
  unknown occupancy cases, the Vault live-range `toward` selector and Vault
  exact), full native acceptance 100/100 each. Raw output is under `tmp/s1/`.
