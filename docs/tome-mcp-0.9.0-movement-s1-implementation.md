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
  existing `movement` descriptor. It rejects unknown templates, unknown keys,
  missing required parameters, non-finite/negative envelopes and wrong types
  with `movement_adapter_invalid`.
  - `actor_charge` → `{'actor'}`, `line_move`, `bounded_alternatives`, `actor`.
  - `grid_move_exact` → `{'grid'}`, exact, `requested_grid`.
  - `grid_move_bounded` → `{'grid'}`, finite radius/getter, bounded alternatives.
  - `self_random_teleport` → `{'none'}`, `teleport`, `random`, `self`.
  - `actor_anchor_teleport` → `{'actor'}`, `teleport`, bounded alternatives.
- `M.matrix(branches)` builds a closed state-variant matrix. A branch is either
  a template expansion or a reviewed `unsupported` capability entry.
- `M.resolveVariant(movement, talent, reads)` returns exactly one descriptor.
  Zero matches, multiple matches or an indeterminate condition return
  `movement_variant_unknown`; a known unimplemented branch returns
  `unsupported_movement_variant` with its typed `missing` reason. There is no
  ordering fallback.
- `M.resolveBounds(movement, talent, reads)` resolves `{getter='getRange'}`-style
  envelopes through the injected audited getter. A missing/erroring/non-finite
  value returns `movement_derivation_unknown`.

`MovementPlanner.plan` resolves the variant matrix and the dynamic bounds before
any request/landing classification, so an unknown state never reaches a leaf.
`MovementPlanner.planTalent` now annotates a bounded/random **grid** landing as
`bounded`/`random` (with envelope + optional LOS fallback) instead of
`deterministic`, so a `landing='deterministic'` policy correctly rejects it.

The live provider (`Runtime.autoCombatReads.plan`) supplies `attr` (a successful
read is definite; an unavailable reader is `known=false`) and `talentGetter`
(the live talent field, finite-checked). Both are fail-closed.

## 3. Phase Door variant matrix

| effective level | `phase_door_force_precise` | resolved requests | landing | disposition |
| --- | --- | --- | --- | --- |
| `< 4` | absent | `{'none'}` | random self, `t.getRange` | driven |
| `< 4` | present | `{'grid'}` | bounded around requested grid, `t.getRadius`, self-centred `t.getRange` LOS fallback | driven |
| `>= 4` | either | `{'actor'}` / `{'actor','grid'}` | — | `unsupported_movement_variant` (`actor_then_grid_target_plan`, S2) |
| unknown | unknown | — | — | `movement_variant_unknown` (fail closed) |

The old fixed `radius=6, min_radius=1` is replaced by the audited dynamic
getters `t.getRange` (no-prompt) and `t.getRadius` (precise grid), with a
`{getter=...}` declaration and a finite resolution. An unavailable getter is a
typed derivation unknown, never a fabricated constant.

## 4. Admitted vs unsupported (S1)

Admitted (explicit manifest entry + template + pins):

- `T_RUSH` — `actor_charge`.
- `T_SKIRMISHER_CUNNING_ROLL` (Tumble) — `grid_move_exact`, `line_move`.
- `T_SKIRMISHER_VAULT` — `grid_move_exact`, `leap`, no traversal.
- `T_DIMENSIONAL_STEP` — `grid_move_bounded` (radius 5) below effective TL5.
- `T_PHASE_DOOR` — no-prompt and precise-grid variants per §3.

Structured unsupported (typed reason, never a strategy refusal):

- `T_PHASE_DOOR` TL4+: `actor_then_grid_target_plan` (S2 queue).
- `T_DIMENSIONAL_STEP` TL5: `moving_or_swapping_another_actor` (S4).
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

## 6. Evidence

- `tests/test_auto_combat_movement_factory.lua` — 43 checks: every template's
  exact descriptor, closed-key/type/negative-envelope rejections, the full Phase
  Door matrix including unknown level/attribute and overlapping/no-match
  variants, dynamic bound resolution, bounded grid annotation, and action/getter
  drift negatives (including a distinct same-line closure).
- `tests/test_effect_manifest.lua`, `tests/test_effect_manifest_drift.lua`,
  `tests/test_auto_combat_movement.lua`, `tests/test_runtime.lua` updated for the
  matrix API and the dynamic getters.
- Full suite, Python and the three generator `--check` runs are recorded in the
  round report under `tmp/`.
