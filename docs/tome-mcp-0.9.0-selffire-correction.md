# Auto-combat selffire catalog correction (pre-v2, round 5)

Bounded correction round on top of `main` (`c4777eb`) following
`docs/tome-mcp-0.9.0-selffire-investigation.md` §8.1/§8.2 and the v1.4 read
policy in `docs/tome-mcp-auto-combat-plugin-design.md` §8.3. The full v2
effect-manifest / footprint-parity work is the next task and is **not** done
here.

## Corrected descriptors (`AutoCombatCatalog.ENTRIES`)

| Talent | Corrected classification |
| --- | --- |
| `T_SEARING_LIGHT` | cursor ball range **7** radius 1; instant hostile `hit`; radius-1 duration-4 ground zone with `selffire=0/friendlyfire=0` (`cursor`/`ground` fields). |
| `T_MOONLIGHT_RAY` | immediate `beam`, `selffire=100`, `friendlyfire=100` (engine defaults); geometric self risk 0 because the line excludes the origin. |
| `T_SUN_BEAM` | base `hit` plus a TL3+ radius-2 `secondary` ball (`selffire=0`, `friendlyfire=100`). |
| `T_FLAME` | conservative `widebeam` union (`bolt`/`beam`/`widebeam`), radius 1, range 10, default filters; conditional Burning Wake `ground` (SF `unknown`, FF 100). |
| `T_SOUL_ROT` | projectile `bolt` (not beam), `selffire=100`, `friendlyfire=100`; path blockers checked. |
| `T_BLOOD_GRASP` | projectile `bolt` (not hit), explicit `selffire=0`, `friendlyfire=0`. |
| `T_SHATTERING_BLOW`, `T_ATTACK` | melee delivery (`attackTarget`), not projected hit. |
| Self actions/sustains | no damage geometry. |

`T_FIREFLASH` remains unsupported (documented in the catalog): its ball
projectile sets `player_selffire=true` and
`selffire=self:spellFriendlyFire()`, so a ball covering the player can self-hit;
FF defaults true, and its optional Burning Wake ground inherits SF and defaults
FF true. The old `T_FLAMESHOCK` rationale was factually stale (its instant cone
explicitly sets `selffire=false`) and is removed; it stays out because instant FF
defaults true and the Burning Wake ground cone has dynamic SF / default-true FF.

## Engine-semantics read helpers (`ObservationDetails`)

- `M.selffire(typ)` now returns the **normalized engine field value**:
  explicit boolean/number wins, otherwise `true` (the `Target:getType`
  default), except `cone`, whose transform forces `false`. The old
  "beam/hit/bolt/arrow ⇒ false" shorthand is gone.
- `M.friendlyfire(typ)` returns the explicit value or the default `true`.
- `M.playerSelfOverride(player,typ)` models the projectile-only
  `player_selffire` / `allow_player_selffire` opt-in.
- `M.footprintContainsOrigin(...)` is the separate geometric containment test
  (hit/bolt on the target cell, beam excludes the origin, widebeam radius >=1 can
  include it, ball by radius, cone apex), so self risk = containment AND both
  filters.
- `M.damageScope` adds `bolt` (single) and `widebeam` (line).
- `M.friendliesInEffect` adds wide-beam width and bolt path checks
  (warning-quality; exact parity is v2).
- `M.friendlyfire({})` now reports `true`, not `unknown`.

## Guard (`Runtime.buildAutoCombatHost reads.guard`)

- No longer synthesizes `typ` from the static catalog. It obtains the real
  target spec from the audited native builder (`t.target(p,t)`) when the talent
  exposes one, and uses the corrected catalog only as an advisory fallback
  (Searing Light / Soul Rot build their table in the action).
- Evaluates `shape`/`range`/`radius`/`selffire`/`friendlyfire` from the real
  spec; self risk = geometric containment AND both filters (plus the projectile
  self opt-in); friendly risk = `friendlyfire` AND a visible friendly/neutral in
  the footprint.
- Checks `secondary` and `ground` components: positive/unknown self risk rejects;
  a positive friendly filter is checked against the instantaneous component
  footprint for secondaries, while a persistent ground zone with positive/unknown
  self or friendly probability rejects even when empty (`max_selffire_risk==0`)
  or pauses (`>0`).
- Melee `attackTarget` delivery skips the projection filters. `Actions.admit`
  and the native return remain the final authority; all frozen invariants
  (emergency layer, budget, target binding, `native_pending`, manual revocation,
  read-only `dry_run`) are preserved. `allow_auto_combat_execution` stays `false`.

## Tests and evidence

- `test_friendly_fire.lua` (35): per-shape engine-default fixtures
  (hit/bolt/beam/widebeam/ball/cone/self/…) and geometric containment.
- `test_interactive_runtime.lua` (122): corrected `Details` semantics.
- `test_auto_combat_pilots.lua` (61): corrected per-talent descriptors.
- `test_runtime.lua` (171): guard self-risk/ally-risk reject/pause, a
  builder-overrides-catalog case, and a Burning Wake ground-zone case.
- Native auto-combat probe **57/57** from source and `dist/*.teaa`, with
  `guard-real-spec` proving the guard uses the real builder (a temporary
  builder override drives the verdict while the catalog still advises a
  widebeam) and that `T_BLOOD_GRASP`'s real builder classifies as safe.
- Native acceptance suite **100/100** from source and `dist/*.teaa`; Python
  39/39; both `--check` generators green.
- Repackaged `dist/tome-mcp-bridge.teaa` sha256
  `4e60984fd7d4859db2e1b0f956185348fff5070b7c8e1308b35f658d6d13bd29`.

## Left for the v2 manifest

- The full versioned component manifest (source hashes, variants, provenance) and
  exact hex/wide-line/cone/bolt footprint parity, including friendlies on the
  precise native line.
- Modelling player projectile self-opt-in and persistent ground zones as
  first-class components with composition across ground ticks.
- Re-admitting dynamic talents (`T_FIREFLASH`, `T_FLAMESHOCK`, `T_SHADOW_BLAST`,
  `T_STARFALL`) only after the manifest can pin their SF formula inputs and
  ground components.
- The current geometry helpers remain warning-quality; the guard's pre-commit
  proof will come from the manifest.

## Build / review

Branch `fix/selffire-catalog-drift`, PR #12
(https://github.com/yutio8888/tome4-mcp/pull/12).
