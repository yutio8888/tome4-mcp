# Re-admitting the four dynamic talents under the v2 effect manifest (TODO #55)

Status: implemented on branch `feat/v2-dynamic-talents` (PR pending review), based
on `main@c131389`. `allow_auto_combat_execution` is unchanged (`false`).

This closes TODO #55: `T_FIREFLASH`, `T_FLAMESHOCK`, `T_SHADOW_BLAST` and
`T_STARFALL` are removed from `EffectManifest.UNSUPPORTED` and modelled as
first-class v2 manifest entries with pinned dynamic inputs, honest ground
components and fail-closed drift.

## Source review (DYN-1)

| Talent | Source | Target / delivery | Components |
| --- | --- | --- | --- |
| `T_FLAMESHOCK` | `data/talents/spells/fire.lua:90` | `cone`, `range=0`, `radius=4..8`, explicit `selffire=false`; `self:project` | instant source-centred cone (SF 0, FF 100); Burning Wake source-centred cone (duration 4, SF `spellFriendlyFire`, FF default true) |
| `T_FIREFLASH` | `data/talents/spells/fire.lua:141` | `ball`, `range=7`, `radius=2..5`, `player_selffire=true`, `selffire=spellFriendlyFire()`; `self:projectile` | projectile ball (player opt-in, dynamic SF, FF 100); Burning Wake impact ball (duration 4, radius = talent radius, SF = target-spec SF, FF 100) |
| `T_SHADOW_BLAST` | `data/talents/celestial/star-fury.lua:56` | `ball`, `range=6`, `radius=3`, `selffire=spellFriendlyFire()`; `self:project` | instant radius-3 ball (dynamic SF, FF 100); persistent radius-3 ball (duration ≤9, dynamic SF, FF 100) |
| `T_STARFALL` | `data/talents/celestial/star-fury.lua:141` | `ball`, `range=6`, `radius=1..2`, `selffire=spellFriendlyFire()`; `self:project` | instant ball (dynamic SF, FF 100); no ground |

All four expose a `t.target` builder, so `conformance.builder=true`; the guard
reads the live builder for the instant geometry and filter values, and the
identity/drift check pins the builder's source path and definition line.

## Pinned dynamic inputs (DYN-2)

- `spellFriendlyFire` is resolved through a new audited provider
  (`guard.spellFriendlyFire` in `Runtime.lua`) registered via
  `NativeCompatibility` against `mod/class/interface/Combat.lua` (digest +
  exact identity + `function _M:spellFriendlyFire` declaration). It is now also
  pinned by `tools/generate_effect_manifest.py` (`combat` in `ENGINE_FILES`).
- Manifest components declare `selffire={dynamic='spellFriendlyFire'}`; the
  guard resolves it to the live scalar or to `unknown`, and the audited
  provider is **authoritative**: the live builder's raw `selffire`/`friendlyfire`
  must not overwrite an `unknown` result (an overridden method could return `0`
  to the builder while the provider fails closed). An unavailable,
  overridden or erroring getter leaves the component **`unknown`** (fail
  closed) — it never yields a permissive verdict.
- Dynamic radii come from the live builder: ground components use
  `radius={from='target'}`, which the guard fills from the builder's `radius`.
  If the builder radius is unavailable the footprint is unknown.
- No talent is left unsupported; no unresolved branch is treated as safe.

## Ground honesty and composition (DYN-3)

- Burning Wake (Fireflash, Flameshock) is modelled as a duration-4, per-grid
  ground component (`per_grid` where the source iterates projected grids; the
  Fireflash branch creates one impact zone). Its SF is the audited
  `spellFriendlyFire`; its FF defaults to **true**. The Fireflash ground is an
  impact ball; the Flameshock ground is a **source-centred directional cone**
  (`center='self', direction='target'`) whose aim vector is kept independently of
  its centre and matches the real `Map:addEffect` fan geometry.
- Shadow Blast's persistent radius-3 ball is a ground component (duration up to
  9) with dynamic SF and default-true FF.
- Starfall has **no** ground component.
- The v2 risk rules compose these with the instant component: a persistent
  ground with positive/unknown FF is future friendly risk even when the current
  footprint is empty. Because all three grounds have FF=100, they reject
  conservatively regardless of the resolved SF.

## Registration and drift (DYN-4)

- The four talents are in `EffectManifest.ENTRIES` with `conformance.builder=true`
  and generated source/builder pins, and in `PolicySchema.TALENTS`.
- `tools/generate_effect_manifest.py` pins `Combat.lua` in addition to the
  existing engine-semantics files; `--check` is green.
- A builder replacement/mutation still fails closed
  (`adapter_source_drift`), and the trusted baseline is the original function
  object (`rawequal`).

## Guard correctness fixes

Flameshock is a `range=0` self-centred cone. The guard previously rejected it:
the distance range check (`distance > 0`) and `canProject` (which reports only
the origin as a hit for a range-0 projection) both fired. The guard now skips
the target-distance and `canProject` gates for a range-0 effect, but requires
the bound hostile to lie in the **resolved native instant footprint** — a far
or wall-blocked target is rejected (`target_out_of_range`). No other whitelist
talent has range 0.

## Rev 2 review fixes (DYN-REV-01 … DYN-REV-03)

- **DYN-REV-01** the audited dynamic provider is authoritative for declared
  dynamic filters; the raw builder value no longer overwrites an `unknown`
  provider (guard and Runtime replacement regressions for Fireflash/Starfall).
- **DYN-REV-02** the range-0 direction special case now also requires the bound
  target to be inside the expanded native instant footprint (near allowed, far
  and wall-blocked rejected); the probe asserts the exact intended verdict.
- **DYN-REV-03** the Flameshock ground cone carries `center='self',
  direction='target'`; ground (`map_effect`) footprints use the real
  `Map:addEffect` geometry (a directional `beam_any_angle` fan), and a native
  grid-set parity check proves the eastward grid is included.

## Rev 3 review fixes (DYN-REV2-01)

- **DYN-REV2-01** `nativeMapEffect` now passes the engine's boolean **`true`**
  block argument to `circle_grids`/`beam_any_angle_grids`, exactly as
  `Map:addEffect` does (`utils.lua` blocks every terrain grid with `block_move`,
  with **no** `pass_projectile` exemption). The previous custom callback could
  extend a persistent zone through movement-blocking, projectile-passable
  terrain. The native regression no longer duplicates production's callback: it
  records the grid set from a real `Map:addEffect` call, and adds a
  `block_move=true, pass_projectile=true` terrain case where the boolean-true
  rule and the old exempt rule differ (new/recorded 17 grids, old rule 19,
  cell behind the wall excluded). A unit check captures the `block=true`
  argument for both map-effect helpers.

## Evidence (DYN-5)

| Layer | Session | Result |
| --- | --- | --- |
| Auto-combat probe (source) | `v2-dynrev3-src` | **88/88** (incl. wall, ground-direction, map-effect terrain parity) |
| Auto-combat probe (`dist`) | `v2-dynrev3-dist` | **88/88** |
| Native acceptance (source) | `v2-dynrev3-accept-src` | **100/100** |
| Native acceptance (`dist`) | `v2-dynrev3-accept-dist` | **100/100** |

Lua suites green including `test_effect_manifest` (312),
`test_auto_combat_guard` (40) and `test_effect_footprint` (30); Python 39/39; all
three `--check` generators green. Native `dynamic-talents` records
`spellFriendlyFire=0` resolved, Shadow Blast's ground verdict `phase=ground`,
`risk=friendly`, FF 100, the wall-blocked Flameshock rejection
(`outside_instant_footprint`), the directional ground cone matching the real
`Map:addEffect` (east grid included), and the boolean-true terrain parity case
(new/recorded 17 grids vs the old rule's 19).

`dist/tome-mcp-bridge.teaa` repackaged:

```
sha256 = 7035d6026488df5e612d72ab4a745bcd2892af25fdfa5f0f2ee7e01282e4c09e
```

(rev 2 package `1c06737021456a84a29b74aeaa5aaed50e5c467adc5b779e013195158b3413d7`;
rev 1 package `2860a9fbf7c5a54916a75446a4c94ec3751ee45f5c8d4f4379f0b9d7574131f7`;
`main` baseline `3d3c57be091c69ba1f9fe60e191495c528c3f8d5dfa74fd910ae3a2b8d3d9a29`.)

## Still unsupported

None of the four. `EffectManifest.UNSUPPORTED` is now empty; the only remaining
out-of-scope work is the P3 assistant layer, which is not a talent-modelling
gap.
