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
  or missing builder shape is `adapter_source_drift`/`movement_derivation_unknown`;
  a builder-backed descriptor without a finite range fails closed. The builder
  never supplies actor/grid semantics or prompt order.
- `M.resolveOccupancy(...)` turns a player-known `'empty'|'actor'|'unknown'` read
  into the admitted non-swap descriptor, the typed S4 gap, or
  `movement_variant_unknown` (never probing a hidden actor).

`MovementPlanner.plan` runs an injected `provider.preflight` **before any variant,
bound or builder read**, then resolves the matrix, bounds, builder and occupancy
before any request/landing classification. `MovementPlanner.planTalent` bounds
`position`/`relative` requests and every scanned candidate by the single audited
`Distance.grid` native metric (range 0 is an empty non-self domain), and
annotates a bounded/random grid landing as `bounded`/`random`.

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

**Transitive helper closure (MAF-REV-02 rev 3/4/5).** The pinned target builder
immediately dispatches through `self:getTalentRange(t)` (→ the talent's live
`def.range`) and the engine scaling helpers. The generator also pins
`ranges={range={path,line}}` for every builder-backed movement talent, and
`EffectManifestDrift.identity` rejects a replaced `def.range` before the builder
runs. The closure is bounded **by construction**:

- **File-digest closure** — the generated engine pin set now includes every
  module that contributes a reached method: `engine/interface/ActorTalents.lua`,
  `mod/class/Actor.lua`, `mod/class/interface/Combat.lua`, `engine/Entity.lua`,
  `engine/interface/ActorStats.lua`, `engine/interface/ActorTemporaryEffects.lua`,
  plus the Phase Door spell-power callback data files.
  `EffectManifestDrift.verify` checks all of them in the preflight, so a source
  change fails before any read.
- **Method identity** — `verifyMovementHelpers` checks the methods actually
  reached: `getTalentLevel`, `getTalentLevelRaw`, `alterTalentLevelRaw`,
  `getTalentMastery`, `getTalentTypeMastery`, `getTalentTypeFrom`,
  `getTalentRange`, `knowTalent`, `callTalent`, `getTalentFromId`, `attr`,
  `getCun`/`getWil`/`getMag`, `hasEffect`, `combatTalentScale`,
  `combatTalentLimit`, `combatLimit`, `combatTalentSpellDamage`,
  `combatSpellpower`, `combatSpellpowerRaw`, `rescaleCombatStats`,
  `rescaleDamage`, and the `getSpellpower` callbacks for the spell-power talents.
  Each present object is checked with a first-seen `rawequal` baseline plus a
  `NativeCompatibility` source/digest/declaration audit; a wrong-source/body or
  replaced object is `adapter_source_drift` **before it is called**, and a
  rejected object never becomes the trusted baseline.
- A multi-candidate method preserves a `dependency_source_unreadable` candidate
  over an inapplicable candidate's `dependency_source_unverified`, so the
  documented hash-unavailable fallback still applies to a legitimate
  module-source method (for example `alterTalentLevelRaw` in `mod/class/Actor.lua`).

## 6. Evidence

Final artifact: `dist/tome-mcp-bridge.teaa`
`5cbf6407ce46675c4e00ce463ef50837bfdb2583e3c762fd43ec89c4b63aade9`
(baseline `100082399c8e2d1d197a457fa118a85475b9575006659669e9d60fd87d7529dd`).
`allow_auto_combat_execution` remains `false` (read-only unless explicitly set).

- `tests/test_auto_combat_movement_factory.lua` — 94 checks (templates, closed
  records/lists, Phase Door matrix, preflight ordering, builder geometry/range,
  occupancy, `Distance.grid` bounds, drift negatives).
- `tests/test_effect_manifest_drift.lua` — 46 checks, including `def.range` pins.
- `tests/test_runtime.lua` — 209 checks: a real-dispatch fixture implements the
  actual chain (`getTalentLevel` → `alterTalentLevelRaw`/`getTalentMastery` →
  `getTalentTypeMastery` → `getTalentTypeFrom`; Phase Door `getRange` →
  `combatTalentSpellDamage`/`combatSpellpower`/`combatSpellpowerRaw` →
  `knowTalent`/`callTalent`/`getCun`/`getWil`/`getMag`/`hasEffect`/`attr`), the
  chain plans, and a first-plan replacement of every leaf (including
  `getTalentTypeMastery`, `getTalentTypeFrom`, `attr`, `getCun`, `callTalent`,
  and the `getSpellpower` callback) is `adapter_source_drift` with zero calls.
- Full Lua suite 41/41 green; Python 39/39; the three generator `--check` runs
  exit 0.
- Native probes (source + `dist`) settle the task and assert final postconditions:
  auto-combat probe 116/116 each, full native acceptance 100/100 each. Raw output
  is under `tmp/s1/`.
