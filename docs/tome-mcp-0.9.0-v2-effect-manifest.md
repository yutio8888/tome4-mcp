# Auto-combat v2 effect manifest, native-equivalent footprint, drift-safe guard

Status: implemented on **PR [#13](https://github.com/yutio8888/tome4-mcp/pull/13)**
(rev 2, reviewed head reported to the dispatcher); **not merged**. The actual
`main` base is `f9b34c2` and the branch stays unmerged until review accepts it.
This round executes `docs/tome-mcp-0.9.0-selffire-investigation.md` §6–§9 and
closes TODO #54 (versioned component manifest, exact footprint parity, composed
projectile/ground risk, source-drift detection). `allow_auto_combat_execution`
is unchanged (`false`).

## What changed

### 1. Canonical v2 manifest (`overload/mod/auto_combat/EffectManifest.lua`)

Replaces the single-shape catalogue as the guard's source of truth. Each talent
is a versioned record with:

- a **cursor** component kept separate from every damaging component;
- **instant / projectile / secondary / ground / melee** components, each with
  `delivery` (`project`/`projectile`/`map_effect`/`attackTarget`), `shape`,
  `range`, `radius`, `center`, `duration`, `selffire`, `friendlyfire`,
  `player_selffire` and per-value provenance
  (`explicit`/`target_default`/`cone_default`/`map_default`/`curated_formula`);
- **declarative variants** (`talent_level`, `attr`) with no Lua functions in
  metadata; an unresolved branch is kept, producing the conservative union;
- `source` identity from the generated `EffectManifestSources.lua`
  (file + md5 + definition line) and a `conformance` subset for the real
  builder.

`AutoCombatCatalog` is now a thin derived facade (`M.compat`) so the public
capability summary can never disagree with the canonical components.

### 2. Manifest-driven guard (`overload/mod/auto_combat/AutoCombatGuard.lua`)

`Runtime.buildAutoCombatHost.reads.guard` now:

1. requires the manifest entry and a source-drift pass;
2. reads the audited native builder only for the instant geometry, keeping the
   canonical components authoritative for secondary/ground/variants;
3. expands each active component's exact footprint;
4. composes self/friendly risk per delivery (self needs SF ∧ FF; a player
   projectile additionally needs the override; an ally/neutral needs FF alone;
   a persistent ground component with positive/unknown SF/FF is future risk
   even when empty) and applies D2 (`0` rejects, `>0` pauses).

The guard no longer reads `shape`/`selffire`/`friendlyfire` from the catalogue.

### 3. Footprint parity (`overload/mod/auto_combat/EffectFootprint.lua`)

Two backends share one interface. `M.native` mirrors `ActorProject:project`'s
grid collection exactly and delegates line/circle/cone geometry to the audited
native `core.fov` helpers. `M.model` is an engine-free model used by unit tests
and headless fixtures. The guard prefers native in-game.

### 4. Source-drift detection (`overload/mod/auto_combat/EffectManifestDrift.lua`)

`tools/generate_effect_manifest.py` pins the md5 of the 20 talent source files
and the five engine-semantics files (`Target.lua`, `ActorProject.lua`,
`Map.lua`, `utils.lua`, ToME `Actor.lua`) plus each definition line. At load
time a mismatch returns `adapter_source_drift` and the adapter is disabled; the
identity/closure check also catches a target builder added, removed or replaced
under an unchanged data hash. `generate_effect_manifest.py --check` fails CI on
drift.

## Rev 2 review fixes (V2-REV-01 … V2-REV-07)

All seven independent-review findings are fixed with a regression test that
would have failed before:

- **V2-REV-01** `talent_level` variants use the audited effective level
  (`self:getTalentLevel(t)`, mastery/alterations), registered through
  `NativeCompatibility`; an unavailable/overridden/erroring getter leaves the
  branch conservative. Regression: raw 2 + effective 3 keeps Sun Ray's radius-2
  secondary active.
- **V2-REV-02** drift runs before the hostile/self early return; a missing live
  `fs`/`md5` is a failure, not a pass; `identity()` now requires every declared
  definition and matches the builder's source path + definition line (a
  same-type replacement on another file/line fails); the guard fails closed on a
  throwing or non-table builder instead of using stale manifest geometry.
- **V2-REV-03** a supplied native context that cannot expand returns unknown
  (`native_failed`), never the approximate model; the model is reserved for an
  explicitly headless context (no `core.fov`).
- **V2-REV-04** each membership carries the effective projectile opt-in
  (`typ.player_selffire` OR `player.allow_player_selffire`); Flame's below-TL5
  bolt is `delivery='projectile'`; Burning Wake is a duration-4 per-grid zone.
- **V2-REV-05** the probe's corner cases use a three-return `block_path` and
  count the corner callback (`for_highlights=true`); two distinct branches now
  trigger (first-step and later-step). It asserts the square map mode and that
  the **production guard** reports `footprint_backend='native'`.
- **V2-REV-06** persistent-ground self risk requires SF ∧ FF; FF alone is the
  friendly risk (adds the SF=100/FF=0 safe case).
- **V2-REV-07** this status now locates the work on PR #13, not on `main`.

## Native evidence

| Layer | Session | Result |
| --- | --- | --- |
| Auto-combat probe (source) | `v2-rev2-src` | **79/79**, incl. 13 footprint cases + 3 `manifest-drift:*` |
| Auto-combat probe (`dist`) | `v2-rev2-dist` | **79/79** |
| Native acceptance (source) | `v2-rev2-accept-src` | **100/100** |
| Native acceptance (`dist`) | `v2-rev2-accept-dist` | **100/100** |

Footprint parity compares the production backend against the real
`ActorProject:project` grid set for `hit`, `bolt`, `beam`, `ball` (r1/r2),
`widebeam` (r1/r2), `cone` (r1/r2) and explicit three-return `block_path` cases
(bolt/beam stop, first-step corner, later-step corner). All 13 matched exactly;
both corner cases report a non-zero corner-callback count and the expected stop
set. The production guard reports `footprint_backend='native'`.

Lua suites: full `tests/run.sh` green, including the new
`test_effect_manifest` (240), `test_effect_manifest_drift` (18),
`test_effect_footprint` (24), `test_effect_risk` (29) and
`test_auto_combat_guard` (26). Python: 39/39. All three `--check` generators green.

`dist/tome-mcp-bridge.teaa` repackaged:

```
sha256 = ceb1e3799b827b6d9bc192b9bdb5c3e0407053e10f4e6514260617f793e27518
```

(`main` baseline artifact `4e60984fd7d4859db2e1b0f956185348fff5070b7c8e1308b35f658d6d13bd29`.)

## Frozen invariants preserved

`allow_auto_combat_execution` stays `false`; the emergency layer, action budget,
target binding, `native_pending` handling, manual revocation and read-only
`dry_run` are untouched. The only protocol-visible change is the capability
`adapter_version` string (`tome-auto-combat-adapters/v2`); no server, schema or
wire field changed.

## Deferred

- Dynamic talents (`T_FIREFLASH`, `T_FLAMESHOCK`, `T_SHADOW_BLAST`,
  `T_STARFALL`) are documented under `EffectManifest.UNSUPPORTED` with their
  reason; they still need a pinned `spellFriendlyFire` input closure plus full
  ground modelling before re-admission.
- `EffectFootprint.model` is a pure approximation used only for an explicitly
  headless context (no `core.fov`); the in-game guard uses the native backend and
  fails closed (`native_failed`) if it cannot expand, which the probe shows is
  exact.
