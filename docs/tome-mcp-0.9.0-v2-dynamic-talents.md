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
  guard resolves it to the live scalar or to `unknown`. An unavailable,
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
  `spellFriendlyFire`; its FF defaults to **true**.
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

## Guard correctness fix

Flameshock is a `range=0` self-centred cone. The guard previously rejected it:
the distance range check (`distance > 0`) and `canProject` (which reports only
the origin as a hit for a range-0 projection) both fired. The guard now skips
the target-distance and `canProject` gates for a range-0 effect; the line of
sight is still validated implicitly and the cone footprint is expanded natively.
No other whitelist talent has range 0.

## Evidence (DYN-5)

| Layer | Session | Result |
| --- | --- | --- |
| Auto-combat probe (source) | `v2-dyn-src` | **85/85** (incl. `dynamic-talents:*`) |
| Auto-combat probe (`dist`) | `v2-dyn-dist` | **85/85** |
| Native acceptance (source) | `v2-dyn-accept-src` | **100/100** |
| Native acceptance (`dist`) | `v2-dyn-accept-dist` | **100/100** |

Lua suites green including `test_effect_manifest` (312) and
`test_auto_combat_guard` (35); Python 39/39; all three `--check` generators
green. Native `dynamic-talents` records `spellFriendlyFire=0` resolved, Shadow
Blast's ground verdict `phase=ground`, `risk=friendly`, FF 100, and the
production guard's `source=builder`/`footprint_backend=native`.

`dist/tome-mcp-bridge.teaa` repackaged:

```
sha256 = 2860a9fbf7c5a54916a75446a4c94ec3751ee45f5c8d4f4379f0b9d7574131f7
```

(`main` baseline `3d3c57be091c69ba1f9fe60e191495c528c3f8d5dfa74fd910ae3a2b8d3d9a29`.)

## Still unsupported

None of the four. `EffectManifest.UNSUPPORTED` is now empty; the only remaining
out-of-scope work is the P3 assistant layer, which is not a talent-modelling
gap.
