# ToME 1.7.6 self-fire and friendly-fire investigation

Status: docs-only investigation, based on `main` at `640971c`. No addon or game
behavior was changed. Source paths below are relative to the T-Engine checkout
root (`/workspace/t-engine4`).

## Recommendation

> **Maintainer policy override (design §8.3, v1.4):** this project does **not**
> require RNG/state purity for reads, and audited native dynamic getters/builders
> (`getTalentTarget`/`t.target`/`preUseTalent`, `canProject`, `spellFriendlyFire`,
> `desc`, ...) **may be called**; only the action-execution entrypoints
> (`useTalent`, ...) are the boundary. The two read red lines are: never commit an
> action, never expose player-unknown information. So the "never call `t.target`
> at guard time" advice below is **superseded**: calling the audited native target
> builder to obtain the real `typ` before deciding is allowed.
>
> **Extended supersession (v1.6).** The `rawequal` / function-identity /
> dependency-closure / source-hash-as-runtime-gate language that recurs below is
> also **superseded** by `AGENTS.md` and design §8.3. The guard calls the game's
> **live** provider/getter/builder and judges its usable return value; a missing/
> throwing/`nil`/invalid result makes the value `unknown`, while a replaced object,
> changed closure, or source-digest mismatch is **advisory re-review telemetry
> only**. What remains current below: the curated component/effect model, ground
> components, footprint parity, and the *fail-closed on an unobtainable value*
> rule. Pasted source quotes and observed results are kept as historical evidence.

Use a **version-pinned, curated effect manifest**, not a guard-time call to an
arbitrary talent `target` function. A talent adapter must describe the targeting
cursor separately from every damaging or detrimental component: immediate
projection, projectile impact, secondary projection, and persistent map effect.
The guard selects a curated variant using only audited scalar reads, expands the
real footprint, and rejects or pauses unless it can prove that neither the player
nor a known friendly can be affected.

The existing `getTarget` seam remains useful as post-submit conformance telemetry.
It is too late to be the pre-commit source of truth: native `useTalent` has already
run `preUseTalent`, which may consume RNG and mutate state, before the talent calls
`getTarget`.

The current `AutoCombatCatalog` should therefore become a v2 effect manifest.
Its single `shape` and qualitative `friendlyfire_risk` fields are not sufficient.
There are already concrete mismatches: Searing Light is range 7, not 10; Soul Rot
and Blood Grasp are bolts, not respectively a beam and a hit; Sun Ray has a
level-dependent secondary ball; and Flame has a live-state wide-beam variant and
an optional ground effect.

## 1. Engine semantics

### 1.1 Target normalization, not cursor permission

`Target:getType` clones the supplied table, constructs defaults, applies the
shape transform, and then fills only missing fields:

> `game/engines/default/engine/Target.lua:613-631, 635-695`
>
> ```lua
> _M.types_def = {
>     ball = function(dest, src) dest.ball = src.radius end,
>     cone = function(dest, src)
>         dest.cone = src.radius
>         dest.cone_angle = src.cone_angle or 55
>         dest.selffire = false
>     end,
>     bolt = function(dest, src) dest.stop_block = true end,
>     beam = function(dest, src) dest.line = true end,
>     widebeam = function(dest, src) dest.widebeam = src.radius end,
> }
> ...
> local target_type = {
>     range = 20,
>     selffire = true,
>     friendlyfire = true,
>     actorblock = true,
> }
> ...
> table.update(t, target_type)
> ```

`table.update` adds only absent values and preserves an explicit `false`:

> `game/engines/default/engine/utils.lua:555-567`
>
> ```lua
> elseif not dst[k] and type(dst[k]) ~= "boolean" then
>     dst[k] = e
> end
> ```

Therefore the normalized defaults are:

| Native type string | normalized `selffire` if omitted | normalized `friendlyfire` if omitted |
| --- | ---: | ---: |
| `hit`, `bolt`, `beam`, `widebeam`, `ball` | `true` | `true` |
| `cone` | `false` | `true` |
| `arrow` | `true` | `true` |
| `wide`, `self` | `true` | `true` |

`arrow`, `wide`, and `self` are not registered native geometry types in
`Target.types_def`; absent another matching substring, ActorProject treats them
as a single stopped grid. They must not be accepted as stable native shapes by a
new adapter. `wide` is currently only a bridge-side category.

Neither flag decides whether the cursor may be placed on a grid. An exhaustive
reference scan of `Target.lua` and `GameTargeting.lua` finds the flags only in
normalization/documentation, not in cursor acceptance. Player targeting passes
the table into targeting mode and yields the selected coordinates:

> `game/engines/default/engine/interface/GameTargeting.lua:296-323`
>
> ```lua
> self:targetMode("exclusive", msg, coroutine.running(), typ)
> ...
> return coroutine.yield()
> ```

Self-targeting has a generic confirmation, independent of `selffire`:

> `game/engines/default/engine/interface/GameTargeting.lua:140-143`
>
> ```lua
> if self.target_warning and self.target.target.x == self.player.x
>     and self.target.target.y == self.player.y then
>     Dialog:yesnoPopup(... "Target yourself?" ...)
> end
> ```

Thus `selffire` and `friendlyfire` are **projection filters**, not cursor
eligibility fields. They can influence AI tactics elsewhere, but not the player
cursor rule.

### 1.2 The two filters compose

For a grid containing the source actor, self-fire is not the only gate. The
source is also friendly to itself, so it must pass both filters. With boolean
fields, an immediate projection or map effect affects the source iff:

```text
source grid is in footprint AND selffire AND friendlyfire
```

With numeric fields, the engine performs independent `rng.percent` calls, so the
nominal self-hit probability is `P(selffire) * P(friendlyfire)`. An ally or
neutral actor needs only the friendly-fire check. The code uses reaction `>= 0`,
not strictly `> 0`, so neutrals are in the protected/affected side as well.

`true` means 100%, `false` means 0%, and a number is a percentage evaluated at
projection time. A safety read must never call `rng.percent`; it records the
number and treats every value above zero as risk.

### 1.3 `player_selffire` and `allow_player_selffire`

These fields occur only in ToME's override of **projectile** `projectDoAct`:

> `game/modules/tome/class/Actor.lua:8374-8400`
>
> ```lua
> if act and act == self and not (
>     ((type(typ.selffire) == "number" and rng.percent(typ.selffire))
>       or (type(typ.selffire) ~= "number" and typ.selffire))
>     and (act == game.player and
>          (typ.player_selffire or act.allow_player_selffire))
> ) then
>     shouldHit = false
> elseif act and self.reactionToward and
>     (self:reactionToward(act) >= 0) and not (...) then
>     shouldHit = false
> end
> ```

For a projectile fired by the player, self-hit therefore additionally requires
`typ.player_selffire` or `player.allow_player_selffire`. The misleading comment
says “Disable friendlyfire”, but this branch compares `act == self`; it does not
disable damage to escorts, summons, allies, or neutral actors. Those still use
`typ.friendlyfire`.

Neither override applies to immediate `ActorProject:project` nor to
`Map:addEffect`. `allow_player_selffire` is found nowhere else in the inspected
engine/module Lua source. `player_selffire` is a projectile self-hit opt-in, not
a general friendly-fire switch.

### 1.4 Effective player defaults by shape

The raw default alone is not the result; the generated footprint and delivery
path matter. This table assumes omitted flags and `friendlyfire=true` after
normalization.

| Shape | Does the native footprint include the source by default? | immediate `project` | moving `projectile` fired by player |
| --- | --- | --- | --- |
| `hit` | only when the chosen/stopped grid is the source grid | self-hits if explicitly aimed at self | suppressed unless a player override is set |
| `bolt` | normally no; only the terminal grid is applied | no normal self-hit | suppressed unless override even if it stops on the source |
| `arrow` | no registered native meaning; effectively a single stopped grid | unsupported as a certified shape | unsupported |
| `beam` | no; line iteration starts after the origin | no self-hit by geometry | no self-hit by geometry |
| `widebeam` | possibly yes: radius circles around the first path cells can include the origin | self-hits when the expanded footprint contains the origin | suppressed unless override |
| `ball` | yes iff source-to-center distance is within radius | self-hits when contained | suppressed unless override |
| `cone` | its transform forces `selffire=false` | no self-hit | no self-hit |
| `wide` | no native definition | unsupported | unsupported |
| `self` | no native definition; a self coordinate is a single target | self-hits | suppressed unless override |
| range-0 `ball` | yes, centered on the source | self-hits | suppressed unless override |
| range-0 `cone` | source may be in geometric grids, but normalized `selffire=false` | no self-hit | no self-hit |

The wide-beam inclusion follows its implementation: it starts the path at the
first cell after the source, then draws a radius circle around every path cell
(`game/engines/default/engine/utils.lua:2787-2811`). With radius 1, the first
circle can include the source.

## 2. Where damage actually happens

### 2.1 Immediate projection

`ActorProject:project` first calls `on_project_init`, normalizes the target type,
constructs a grid set, and then filters each actor before invoking the damage
projector:

> `game/engines/default/engine/interface/ActorProject.lua:41-63, 118-224, 242-269`
>
> ```lua
> self:check("on_project_init", t, x, y, damtype, dam, particles)
> local typ = Target:getType(t)
> ...
> if single_target then addGrid(stop_x, stop_y) end
> ...
> local act = game.level.map(px, py, engine.Map.ACTOR)
> if act == self and not selffire_pass then
> elseif act and self:reactionToward(act) >= 0 and not friendlyfire_pass then
> else
>     DamageType:get(damtype).projector(...)
> end
> ```

Ball, cone, wide-beam, wall, and triangle grids are expanded before this filter.
The immediate path does **not** call ToME's `projectDoAct` player override, so a
player's direct ball with default flags can damage the player.

ToME's `Actor:on_project_init` can set both flags to false when the actor has
`nullify_all_friendlyfire` (`game/modules/tome/class/Actor.lua:7779-7789`). That
is a dynamic safety improvement, not a basis for a static adapter; unless the
attribute read is audited, ignoring it is conservative.

After the filters, the damage type resolves the actor and ultimately calls
`takeHit`:

> `game/modules/tome/data/damage_types.lua:116-128, 550-553`
>
> ```lua
> local target = game.level.map(x, y, Map.ACTOR)
> ...
> dead, dam = target:takeHit(dam, src, ...)
> ```

Compound damage types can perform additional projections or effects. Therefore
adapter review must follow the chosen damage type and callbacks, not stop at the
outer target table.

### 2.2 Moving projectile

`ActorProject:projectile` normalizes the type and creates an `engine.Projectile`
(`ActorProject.lua:406-436`). At impact/beam steps the projectile calls
`src:projectDoAct`; ToME's override quoted in section 1.3 applies the player-only
self gate, then invokes the same damage projector. `friendlyfire` still governs
all non-hostile actors and is also the second gate for self.

This delivery distinction is why a canonical adapter needs `delivery`, not only
`shape`. Fireflash is a projectile and explicitly opts back into player self-hit;
Shadow Blast is an immediate projection and never receives that projectile
protection.

### 2.3 Persistent map effects

`Map:addEffect` has an independent pair of flags and defaults both to true:

> `game/engines/default/engine/Map.lua:1096-1137`
>
> ```lua
> function _M:addEffect(..., selffire, friendlyfire)
>     if selffire == nil then selffire = true end
>     if friendlyfire == nil then friendlyfire = true end
>     ...
>     update_fct=update_fct, selffire=selffire,
>     friendlyfire=friendlyfire,
> end
> ```

Every damaging tick repeats the two filters and directly calls the damage type:

> `game/engines/default/engine/Map.lua:1258-1273`
>
> ```lua
> if act == e.src and not selffire_pass then
> elseif act and e.src:reactionToward(act) >= 0 and not friendlyfire_pass then
> else
>     DamageType:get(e.damtype).projector(e.src, lx, ly, ...)
> end
> ```

There is no `player_selffire` exception here. Missing the final `friendlyfire`
argument means 100% ally/neutral effect even when a talent passes an explicit
`selffire` argument.

## 3. Five-pilot source classification

The table covers every entry currently whitelisted in
`AutoCombatCatalog.ENTRIES`, including the shared basic attack. “No target spec”
means the talent is a self action/sustain; it is not a missing hostile geometry.

| Talent(s) | Source evidence | Classification and exact targeting/effect fields |
| --- | --- | --- |
| `T_CHANT_OF_FORTRESS` | `game/modules/tome/data/talents/celestial/chants.lua:85-100` | No `target`; self sustain, `range=0`. |
| `T_HYMN_OF_SHADOWS` | `.../celestial/hymns.lua:45-68` | No `target`; self sustain, `range=0`. |
| `T_HEALING_LIGHT` | `.../celestial/light.lua:21-41` | No `target`; directly heals `self`. |
| `T_BARRIER` | `.../celestial/light.lua:96-109` | No `target`; applies a shield to `self`. |
| `T_TWILIGHT` | `.../celestial/twilight.lua:23-35` | No `target`; resource conversion on `self` (`range=10` is irrelevant to targeting). |
| `T_MOONLIGHT_RAY` | `.../celestial/star-fury.lua:29-43` | Function, stable output: `{type="beam", range=self:getTalentRange(t), talent=t}`. Immediate projection; missing FF normalizes true; origin excluded by line geometry. |
| `T_SEARING_LIGHT` | `.../celestial/sunlight.lua:30-54` | No `t.target`. Action-local cursor `{type="ball", range=7, radius=1}`; actual instant component `{type="hit", talent=t}`; ground component duration 4/radius 1 with `selffire=false, friendlyfire=false`. |
| `T_SUN_BEAM` | `.../celestial/sun.lua:29-70` | Base function `{type="hit", range=7, talent=t}`. Level-dependent secondary at effective TL >=3: `{type="ball", range=7, radius=2, selffire=false, talent=t}` used for blindness; FF omitted -> true. |
| `T_WEAPON_OF_LIGHT` | `.../celestial/combat.lua:63-105` | No activation target; self sustain. Its melee callback can create separate friendly-safe balls only with another sustain (`friendlyfire=false`). |
| `T_FLAME` | `.../spells/fire.lua:29-75` | Function and live-state dependent. Thaumaturgy: `widebeam`, radius 1, range 10, `selffire=false`, `friendlyfire=self:spellFriendlyFire()`. Otherwise `bolt` below effective TL 5 and `beam` at/above 5; both omit SF/FF. If `burning_wake` exists, creates radius-0 ground zones along impact/grids with `ground.selffire=self:spellFriendlyFire()` and omitted ground FF -> true. |
| `T_HEAL` | `.../spells/aegis.lua:21-40` | No `target`; directly heals `self`. |
| `T_ARCANE_POWER` | `.../spells/arcane.lua:73-97` | No `target`; self sustain. |
| `T_SHIELDING` | `.../spells/aegis.lua:51-76` | No `target`; self sustain. |
| `T_SOUL_ROT` | `.../corruptions/vim.lua:21-38` | No `t.target`. Action-local `{type="bolt", range=10, talent=t, display=...}`; projectile; missing SF/FF normalize true. |
| `T_BLOOD_GRASP` | `.../corruptions/blood.lua:81-100` | Function, stable output: `{type="bolt", range=10, selffire=false, friendlyfire=false, talent=t, display=...}`; projectile. |
| `T_DARK_RITUAL` | `.../corruptions/blight.lua:21-41` | No `target`; self sustain. |
| `T_SHATTERING_BLOW` | `.../techniques/strength-of-the-berserker.lua:147-173` | Function, stable `{type="hit", range=1}` cursor; damage is `attackTargetWith`, not ActorProject. |
| `T_BERSERKER_RAGE` | `.../techniques/strength-of-the-berserker.lua:61-135` | No `target`; self sustain. |
| `T_DAUNTING_PRESENCE` | `.../techniques/conditioning.lua:100-131` | No activation target; self sustain. Callback uses an immediate range-0 ball, radius 6, `friendlyfire=false`, SF omitted, to apply a non-damage effect. This callback is a separate component even though it is not cast targeting. |
| `T_ADRENALINE_SURGE` | `.../techniques/conditioning.lua:144-160` | No `target`; instant self buff. |
| `T_ATTACK` | `.../misc/misc.lua:35-81` | Function, stable cursor `{type="hit", range=1}`; damage is `attackTarget` (or a known alternate attack), not ActorProject. |

This classification also identifies four current catalog errors/omissions:

* `AutoCombatCatalog.lua:21-22` says Searing Light `range=10`; native source says
  7 and its cursor, instant hit, and ground field are three distinct semantics.
* `AutoCombatCatalog.lua:38-39` calls Soul Rot a beam; native source creates a
  bolt. The catalog's line check is conservative for ally occupancy but its
  `canProject` behavior is not the bolt's blocking behavior.
* `AutoCombatCatalog.lua:42-43` calls Blood Grasp a hit; it is a bolt with both
  filters explicitly false.
* `AutoCombatCatalog.lua:25` records only Sun Ray's hit and misses the radius-2
  blindness component at talent level 3+.

## 4. Can the real target table be acquired safely before commit?

### 4.1 Directly calling `t.target(self, t)`

For the **currently inspected definitions**, the target-bearing whitelist has no
`rng.*` call inside its target builders:

* Moonlight Ray, Sun Ray/`target2`, Blood Grasp, Shattering Blow, and Attack
  allocate a table and read a numeric range.
* Flame additionally reads effective talent level and live Thaumaturgy state
  (`archmage_widebeam*` attributes plus BODY inventory). Its wide-beam branch
  calls `spellFriendlyFire`.
* Searing Light and Soul Rot have no `t.target`, so direct evaluation cannot
  recover the table that their action later constructs.

This is not a general purity guarantee. `getTalentRange` and `getTalentRadius`
explicitly dispatch a function-valued field:

> `game/engines/default/engine/interface/ActorTalents.lua:1048-1059`
>
> ```lua
> if type(t.range) == "function" then return t.range(self, t) end
> ...
> if type(t.radius) == "function" then return t.radius(self, t) end
> ```

An updated talent can therefore introduce arbitrary code behind a target builder
without changing the bridge. Flame already depends on live equipment/attributes:

> `game/modules/tome/data/talents/spells/spells.lua:122-129`
>
> ```lua
> if self:attr("archmage_widebeam_always") then return true end
> if not self:attr("archmage_widebeam") then return false end
> local inven = self:getInven("BODY")
> ...
> ```

`spellFriendlyFire` is RNG-free in this version, but it is not strictly
side-effect-free because it prints, and its result depends on current Luck,
Spellcraft, and `combat_spell_friendlyfire`:

> `game/modules/tome/class/interface/Combat.lua:2092-2100`
>
> ```lua
> local chance = (self:getLck() - 50) * 0.2
> if self:isTalentActive(self.T_SPELLCRAFT) then ... end
> chance = chance + (self.combat_spell_friendlyfire or 0)
> chance = 100 - chance
> print("[SPELL] friendly fire chance", chance)
> return util.bound(chance, 0, 100)
> ```

Calling `getTalentTarget` is worse than calling the builder directly: it writes a
global `typ` and adds `talent_mode`; for a table target it mutates the shared
talent table (`ActorTalents.lua:1062-1070`). It is not an acceptable read API.

Conclusion: source review shows that several present builders happen to be
RNG-free, but the API has no purity contract; one current builder has an
observable print side effect and two supported talents have no builder at all.
Production guard code must not invoke arbitrary `t.target` or
`getTalentTarget`.

### 4.2 Existing `getTarget` seam and two-phase execution

The bridge wrapper records the real `typ` only when the talent action calls the
first `getTarget` (`overload/mod/mcp_bridge/Actions.lua:217-265`). By then native
execution has started. `useTalent` runs `preUseTalent`, logs the talent, sets
current talent mode, and only then invokes the action:

> `game/engines/default/engine/interface/ActorTalents.lua:168-202`
>
> ```lua
> if not self:preUseTalent(ab, silent) then return false end
> ...
> self:setCurrentTalentMode("active", ab.id)
> local ok, ret = xpcall(function() return ab.action(who, ab) end, ...)
> ```

`preUseTalent` is not a read. Among other paths it performs probabilistic spell
failure and can spend energy or fire callbacks:

> `game/modules/tome/class/Actor.lua:5867-5900`
>
> ```lua
> if ab.is_spell ... and self:attr("spell_failure") then
>     if rng.percent(self:attr("spell_failure")) then
>         ... self:useEnergy() ...
>         self:fireTalentCheck("callbackOnTalentDisturbed", ab)
>         return false
>     end
> end
> ```

A “probe” that starts `useTalent`, captures `typ`, returns nil, and later starts a
second cast can therefore consume RNG, mutate logs/current-mode bookkeeping,
trigger hooks, or spend a turn on failure. Rolling back Lua fields would not roll
back RNG or arbitrary callbacks. Pausing the same coroutine at `getTarget` avoids
a second cast but still performs these pre-target effects before safety is known.

Therefore a true probe-then-commit protocol is **not viable** through this seam.
The seam may compare the observed cursor type with the curated manifest during
the actual cast. A mismatch is a compatibility fault and should stop future
automation, but it cannot retroactively serve as the pre-commit proof.

No live target-builder probe was run for this investigation because doing so
would not establish a general no-RNG/no-mutation guarantee.

## 5. Ground effects must be modeled independently

The target table used to acquire a cursor says nothing reliable about later
`addEffect` arguments. Concrete examples:

* Searing Light: cursor ball; immediate hit; safe ground (`false, false`).
* Shadow Blast: immediate ball has dynamic SF; ground independently calls
  `spellFriendlyFire()` for SF and omits FF, so ground FF defaults true.
* Flameshock: immediate cone explicitly has `selffire=false`, but optional
  Burning Wake is a source-centered cone ground effect with dynamic SF and
  default-true FF.
* Flame: an optional radius-0 Burning Wake zone is created at projectile impact
  or on each projected grid; its SF is dynamic and its FF defaults true.
* Fireflash: its optional ground ball inherits `tg.selffire` but omits FF.

The guard must represent these as separate components with their own center,
shape/radius, duration, SF, and FF. For a persistent zone whose SF or FF can be
positive, checking only current occupancy is not enough: the caster or an escort
can enter it on a later tick. Under strict safety the action is rejected outright
(`max_selffire_risk=0`) or paused for the player (`>0`) unless both ground flags
are proven zero for all friendly actors. This is deliberately stricter than an
instantaneous footprint check.

## 6. Canonical adapter model

Replace each single catalog descriptor with a versioned record of this form
(names illustrative, not a product-code patch):

```lua
T_SEARING_LIGHT = {
  source = {
    game_version = "1.7.6",
    files = {{path="/data/talents/celestial/sunlight.lua", md5="..."}},
    definition_line = 23,
  },
  target = {mode="hostile", cursor={shape="ball", range=7, radius=1}},
  variants = {{
    when = "always",
    components = {
      {phase="instant", delivery="project", shape="hit", center="target",
       selffire=100, friendlyfire=100, hostile_single_target=true},
      {phase="ground", delivery="map_effect", shape="ball", center="target",
       radius=1, duration=4, selffire=0, friendlyfire=0},
    },
  }},
}
```

Required fields per adapter/component:

* `source`: game version, source-file paths/lines and hashes, definition identity/line,
  adapter schema version, and hashes for relevant engine semantics (`Target.lua`,
  `ActorProject.lua`, ToME `Actor.lua`, `Map.lua`, geometry helpers, and any
  damage-type/callback file). This is **advisory re-review metadata** (see the top
  banner); the guard calls the live providers directly.
* `target`: selector class and **cursor** geometry. Cursor geometry is never
  silently reused as damage geometry.
* `variants[].when`: a declarative condition over an allowlist of audited scalar
  reads, or `unknown`. No Lua function in policy/metadata.
* `components[]`: `phase` (`instant`, `secondary`, `ground`, `melee`), `delivery`
  (`project`, `projectile`, `map_effect`, `attackTarget`), shape, range, radius,
  center/origin, duration, blocking/piercing rules, and whether the component is
  damaging or detrimental.
* Raw and effective filter fields: `selffire`, `friendlyfire`,
  `player_selffire`, and whether `allow_player_selffire` is relevant. Values are
  `0..100` or `unknown`; booleans normalize to 0/100. Preserve provenance:
  `explicit`, `target_default`, `cone_default`, `map_default`, or
  `curated_formula`.
* `footprint`: exact instantaneous grid rule, plus a separately named ground
  footprint. Store level-dependent variants rather than one alleged shape.
* `conformance`: the subset expected at the real `getTarget` seam. This validates
  cursor geometry only; action-local/ground components remain source-curated.

For simple self buffs and sustains, use `components={}` and `target.mode="self"`.
Do not invent a `hit` shape. For melee attacks, use `delivery="attackTarget"` and
audit alternate-attack closure rather than pretending that ActorProject flags
apply.

## 7. Pre-commit guard algorithm

For each selected hostile action, immediately before calling `Actions.execute`:

1. **Resolve an adapter.** Require exact talent ID, expected talent mode and
   curated source coverage; call the **live** function objects (no identity/hash
   gate). Missing/mismatched *value* (missing/throwing/`nil`/invalid return) is
   `safety_unknown`.
2. **Resolve the variant without talent callbacks as a predicate.** Read the live
   scalar providers or raw bounded fields. If a branch cannot
   be selected, use a declared conservative union only when that union is itself
   safe; otherwise return unknown. For Flame, the safe geometric union includes
   bolt, beam, and radius-1 wide-beam footprints. Burning Wake must be proven
   absent or modeled as a ground component.
3. **Validate the bound target.** It must still exist, be hostile, visible/known,
   and have finite coordinates. Use the adapter's cursor range and the live
   `canProject` for block checks. A custom callback that cannot be resolved makes
   the adapter unsupported.
4. **Expand every component footprint.** Use a pure, engine-version-pinned
   geometry implementation. Bolt checks every potential stopping actor; beam
   checks its traversed line; wide-beam checks width; ball/cone use their actual
   centers. Do not use the current collinearity approximation as a proof for
   arbitrary ToME lines/hex maps.
5. **Compute self risk.** For each component containing the caster:
   `Pself = P(selffire) * P(friendlyfire)`. For a player projectile, also require
   the boolean player override; no such override applies to direct or ground
   effects. `unknown` in any required term is unknown risk.
6. **Compute friendly risk.** For each visible/known ally or neutral in the
   footprint, risk is `P(friendlyfire)`. If a harmful footprint includes grids
   whose occupancy is not player-known, safety is unknown. A hostile single-target
   component is safe only after the target's hostility is revalidated.
7. **Apply persistent-zone policy.** Any ground component with positive or
   unknown self/friendly probability is future risk even when currently empty.
   Strict mode does not try to predict future movement.
8. **Decide before submission.** Zero risk for all components proceeds. Positive
   or unknown risk uses the following policy. Record component, phase, probability
   or `unknown`, affected known actors, and provenance in the decision log.
9. **Conformance-check during execution.** At the first real `getTarget`, compare
   observed cursor shape/range/radius and explicit flags with the manifest. A
   mismatch is recorded as **telemetry** and disables only that adapter's precise
   claim (falling back to the conservative union/unknown); it does not by itself
   stop unrelated automation. It is defense in depth, not the pre-commit proof.

### Fail-closed behavior and `max_selffire_risk`

Preserve the currently documented mode semantics rather than pretending the
field is a probabilistic authorization threshold:

* `max_selffire_risk == 0`: positive **or unknown** self/friendly risk hard-rejects
  this candidate and allows the policy evaluator to try another verified action.
* `max_selffire_risk > 0`: the same condition pauses automation for human review;
  it does not authorize a cast up to that percentage. This matches current
  `Runtime.lua:1049-1053` behavior, which uses the value only to choose reject vs
  pause.
* If the unsafe/unknown action is the only selected emergency/self-preservation
  action, pause even in hard-reject mode, consistent with design section 8.1;
  silently falling through to no action would conceal loss of the emergency path.

A future schema may introduce an explicitly named probability budget, but that
would be a separate behavior change and must define composition across repeated
ground ticks. It is not part of this proposal.

## 8. Catalog reconciliation

The existing `ObservationDetails` functions remain useful for reporting a raw
observed target table, but they must not be the v2 safety model:

* `M.selffire` returning false for a missing `beam`/`hit`/`bolt`/`arrow` is a
  geometric shorthand (“the ordinary footprint cannot contain the origin”), not
  the engine's normalized field value; `Target:getType` actually defaults the
  field to true.
* `M.friendlyfire` returns unknown when the raw field is absent, while the engine
  projection default is true. The manifest can resolve that default because it
  has audited the actual component and delivery path.
* `M.damageScope` has no `widebeam` or bolt-path semantics.
* `M.friendliesInEffect` uses simple integer collinearity for beams and treats
  `ball`, `cone`, and `wide` alike as a radius around the selected target
  (`ObservationDetails.lua:67-85`). That is warning-quality geometry, not proof
  for native cone/wide-beam/hex-grid footprints.

The current guard also synthesizes `typ` from the catalog
(`Runtime.lua:1062-1063`) and then checks allies solely from `entry.shape`
(`Runtime.lua:1077-1083`); it never obtains the action's ground components and
does not use `friendlyfire_risk` as an executable semantic. V2 should consume the
canonical component probabilities directly and derive any public risk label.

### 8.1 Current whitelist

Create `tome-auto-combat-adapters/v2` and mechanically derive the public summary
from canonical components. Do not retain `friendlyfire_risk` as an independent
truth that can disagree with fields.

Required entry corrections:

* `T_SEARING_LIGHT`: cursor ball/range 7/radius 1; instant hostile hit; safe
  radius-1 duration-4 ground zone.
* `T_MOONLIGHT_RAY`: immediate beam, default FF 100, geometric SF 0 because the
  source is not on the beam line.
* `T_SUN_BEAM`: base hit plus TL3+ radius-2 blindness ball, SF 0 and FF 100.
* `T_FLAME`: bolt/beam/wide-beam variants; use a conservative wide-line union if
  exact live branch is not safely available. Add conditional Burning Wake ground
  components. Do not call `t.target` as a *predicate* (calling the live builder to
  read geometry is allowed; see §8.3/the top note).
* `T_SOUL_ROT`: projectile bolt, FF 100; check allies/neutral blockers on path.
* `T_BLOOD_GRASP`: projectile bolt, explicit SF 0 and FF 0.
* `T_SHATTERING_BLOW` and `T_ATTACK`: melee delivery, not projected hit damage.
* Self actions/sustains: no damage geometry. Keep independently triggered harmful
  callbacks in the manifest if they exist.

### 8.2 Previously dropped and dynamic talents

`T_FIREFLASH` should remain unsupported under strict mode. Its target is a ball
projectile with `player_selffire=true` and
`selffire=self:spellFriendlyFire()`:

> `game/modules/tome/data/talents/spells/fire.lua:141-173`

The projectile opt-in makes a positive numeric SF effective when the ball covers
the player; FF defaults true. Its optional Burning Wake ground also inherits SF
and defaults FF true.

The old reason recorded for `T_FLAMESHOCK` is factually stale in this checkout.
The instantaneous cone **does explicitly set** `selffire=false`:

> `game/modules/tome/data/talents/spells/fire.lua:101-106`
>
> ```lua
> return {type="cone", range=self:getTalentRange(t),
>     radius=self:getTalentRadius(t), selffire=false, talent=t}
> ```

It is still not ready for the current catalog: instant FF defaults true, and when
Burning Wake is active the source-centered ground cone has dynamic SF and
default-true FF (`fire.lua:116-124`). It may be added only after v2 models both
components and verifies Burning Wake state; the missing-selffire rationale must
be removed.

`T_SHADOW_BLAST` has an immediate ball with dynamic SF and a persistent ball that
independently computes the same dynamic SF; both omit FF, so FF is 100
(`game/modules/tome/data/talents/celestial/star-fury.lua:55-88`). Under
`max_selffire_risk=0`, it is usable only if the live evaluator resolves SF to
zero and the ground future-risk rule is satisfied—which still fails because FF
is positive. Otherwise reject/pause.

`T_STARFALL` is an immediate ball with
`selffire=self:spellFriendlyFire()` and default FF 100
(`.../celestial/star-fury.lua:141-161`). It has no ground component, but any
positive/unknown SF or a friendly in the footprint rejects/pauses.

For these dynamic talents, call the live `spellFriendlyFire` (or read it through
  the live provider) to obtain the real value; a missing/throwing/`nil` return
  stays `unknown`. Do **not** hard-code a copied formula as a substitute for the
  live read, and do **not** disable the adapter on a source hash mismatch alone —
  the live method's *return* is what matters; recorded hashes are re-review
  telemetry.

## 9. Verification plan

### 9.1 Pure unit tests

Add a pure component-risk module and fixture tests before wiring it into runtime:

* normalization: missing direct/map flags -> 100; cone SF -> 0; explicit false
  wins; numeric values remain percentages; invalid/non-finite -> unknown;
* composition: self requires SF and FF; ally/neutral requires FF; player
  projectile additionally requires an override; direct and ground ignore that
  override;
* geometry: hit, bolt stopping path, beam excluding origin, wide-beam including
  near-origin width, ball overlap, cone, range-0 ball, and unknown shapes;
* policy: positive and unknown risk reject at zero and pause above zero; safe
  alternatives remain selectable; sole unknown emergency pauses;
* ground: safe Searing field passes; default-FF or dynamic-SF persistent fields
  fail even when initially empty;
* per-talent fixtures: Searing's three geometries, Sun Ray TL2/TL3, Flame's three
  variants and Burning Wake on/off, Soul Rot bolt, Blood Grasp safe bolt,
  Fireflash/Flameshock/Shadow Blast/Starfall dispositions;
* drift telemetry: a changed recorded source hash, a replaced function object, an
  unknown variant input, or a getTarget conformance mismatch is recorded as a
  stable re-review reason; a missing/erroring/`nil`/invalid return disables only
  that adapter's affected component.

The fixtures must never call engine RNG or a talent function.

### 9.2 Disposable native probe

Run a dedicated test addon in a disposable game/session, never a live save:

1. Place a test player, ally, neutral, and hostile at controlled grids.
2. Use a recording damage type/function to collect projector invocations instead
   of taking real damage.
3. Exercise boolean SF/FF matrices for immediate ball/cone/beam/wide-beam,
   projectile ball with and without `player_selffire` and
   `allow_player_selffire`, and `Map:addEffect` followed by one effect tick.
4. Verify source inclusion and ally/neutral inclusion against the pure model.
5. Exercise each curated talent variant in purpose-built characters and compare
   the real first `getTarget` table with the manifest. Do not use an aborted cast
   as a read API.
6. Numeric percentage tests, if needed, run only in this throwaway environment
   with a controlled RNG harness; production reads never sample them.

Expected native evidence should be small JSON summaries checked into validation,
not raw logs or saves.

### 9.3 Per-talent source-review checklist

Before enabling any talent:

1. Locate the exact `newTalent` definition and ID; record file hash and line.
2. Review `target`, `target2`/other helpers, `range`, `radius`, `direct_hit`, and
   every level/equipment/attribute branch.
3. Review the whole action for every `project`, `projectile`, `attackTarget*`, and
   `Map:addEffect`, including callbacks executed at projectile stop and later
   turns.
4. Follow compound damage types, timed effects, and talent callbacks that can
   create secondary harmful projections.
5. Normalize defaults using the correct delivery path; record explicit versus
   default provenance and all positional `addEffect` arguments.
6. Record a conservative footprint for every variant. Reading branch inputs may
   consume RNG or have read-side effects (allowed); only a missing/erroring/`nil`
   value makes the branch unknown.
7. Add pure fixtures and a native conformance case.
8. Record complete file paths/lines and digests plus function identity/closure as
   **advisory re-review metadata**. A recorded mismatch is telemetry (CI
   regeneration may flag it for a human to repeat this checklist); it is not a
   runtime gate. Only an unobtainable value returns `unknown`.

Digest/identity records extend the existing `NativeCompatibility` telemetry
(`NativeCompatibility.lua:4-27, 65-119`); they are not consulted as a runtime
entry gate.

## 10. Unsupported cases

The following remain unsupported until a curated adapter exists:

* Arbitrary or addon-replaced `target`, `range`, `radius`, block/filter, damage
  type, or callback functions. There is no engine purity contract.
* `wide`, `arrow`, `self`, or composite/custom type strings without an explicit
  adapter mapping to native grid generation.
* Talents whose harmful component is created only inside action code and has no
  curated component manifest.
* Dynamic variants whose condition cannot be obtained (the live read is missing,
  throws, or returns `nil`/an invalid value).
* Positive/unknown persistent ground SF/FF in strict mode; future actor movement
  makes an empty current footprint insufficient proof.
* Random, bouncing, chaining, homing, reflected, teleported, delayed, or
  target-created secondary effects unless the complete footprint and callback
  semantics are curated.
* Friendly safety through unseen/unknown grids. The bridge may not inspect hidden
  actors; if occupancy matters and is not player-known, the action fails closed.
* Relying on `nullify_all_friendlyfire` or other runtime safety modifiers unless
  their exact getter and application point are part of the curated adapter.
* A generic two-phase native probe. The existing seam occurs after potentially
  random/mutating pre-use work and cannot be rolled back.

## 11. Remaining uncertainty

The Lua source establishes all filter/default/control-flow claims above. The one
area that still deserves the disposable native probe is exact footprint parity on
hex maps and corner/blocking cases, especially wide beams and bolt stopping. The
current bridge's simple collinearity/radius helper is not enough to claim parity.

The per-talent source review did not execute live casts, so it intentionally does
not claim that every compound damage type or external addon callback is harmless.
That uncertainty is why the manifest curates the full effect semantics and treats
an unobtainable value as `unknown` (never as safe).
