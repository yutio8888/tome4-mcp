# P2.5 — tooltip-safe getters (player-panel / hover-visible predicates)

> **Supersession banner (v1.6).** The "proven pure by an RNG/state tripwire" criterion in §1/§4 is
> **superseded** by `AGENTS.md` and design §8.3. The current rule has only two read boundaries: a read
> must not submit a game action and must not expose player-unknown information. Current live getters —
> including dynamic tooltip/target getters — **may be evaluated**, and may consume RNG or have read-side
> effects; a missing/throwing/`nil`/invalid return makes the value `unknown`. "Text is not a predicate"
> stays as a **data-model** choice only, not a purity claim. The validation results and `dist` hash below
> are kept as historical evidence.

Date: 2026-09-17 · branch `feat/p2.5-tooltip-getters` · design
[tome-mcp-auto-combat-plugin-design.md](tome-mcp-auto-combat-plugin-design.md) v1.3
§5.2/§5.6/§8. Analysis: `tmp/mcp-play-support/getter-safety-analysis.md`.

P2.5 un-excludes the `computed` / `has_effect` / `ally_count` predicates P2 had
left unwired, using the live native getters / bounded visible reads — no identity
or purity gate. Execution and `change_level` stay default off in the `strict`
preset (a preset default, not a plugin-wide prohibition).

## 1. Normative criterion

A read is **safe** iff both hold:

1. **the player can see the value** on the character sheet, or in a
   hover/tooltip panel; and
2. it comes from the current live native getter/scalar field; a
   missing/throwing/`nil`/invalid return makes the value `unknown`
   (`ActorCombat.computed` reports such getters in `computed.unknown`).

In addition — the two read red lines — a read must never submit a game action
and never expose player-unknown information. There is **no** zero-RNG or
no-side-effect requirement.

Scalar panel data (stats, speeds, crit, powers, accuracy/APR/damage,
defense/armor/fatigue, saves, resists/penetration/affinity, vision, hp/max,
level/rank, the active-effect list, a talent's static cooldown/cost/range) is
safe.

**Dynamic tooltip text may be read for information** (the two red lines still
apply: no action submission, no player-unknown information). It is still not used
as a predicate and never auto-identifies an entity: that is a **data-model**
choice, not a purity claim. There is no RNG/state tripwire; dynamic description
getters may be evaluated and may have read-side effects.

## 2. `computed` — finite enum + numeric comparison

`PolicySchema.COMPUTED_FIELDS` is the explicit enum. It is exactly the live
`ActorCombat.computed` leaf paths:

- `stats.{str,dex,con,mag,wil,cun,lck}`
- `speeds.{global,movement,attack,spell,mind}`
- `crit.{physical,spell,mind,power_pct,multiplier}`
- `power.{physical,spell,mind}`
- `offense.{accuracy,apr,damage,damage_range}`
- `offense.damage_increase.<TYPE>`, `offense.resistance_penetration.<TYPE>`,
  `offense.damage_affinity.<TYPE>`, `resists.<TYPE>` for the 12 ToME damage
  types (PHYSICAL, FIRE, COLD, LIGHTNING, ACID, NATURE, BLIGHT, LIGHT,
  DARKNESS, MIND, TEMPORAL, ARCANE)
- `defense.{defense,defense_ranged,armor,armor_hardiness,fatigue}`
- `saves.{physical,spell,mental}`
- `utility.{see_stealth,see_invisible,crit_reduction}`

The predicate is numeric: `{"computed":{"field":"resists.DARKNESS","ge":50}}`.
`PolicySchema` rejects an unknown field (`unsupported_computed_field`), a
missing/multiple comparator, and non-numeric comparators. `ActorCombat.field`
resolves the path by live traversal; a nil/unknown value makes the evaluator
return `unknown` (never `true`).

## 3. `has_effect` and `ally_count`

- `has_effect`: `{"effect":"EFF_X","who":"self"|"target"}` (`who` defaults to
  `self`). It scans the bounded, player-visible effect list
  (`ObservationDetails.effects(actor,24)`) by exact `id` or case-insensitive
  `name`. `who=target` resolves the **same bound target the action uses**
  (`PolicySnapshot` passes the bound target id to the host). A missing actor or
  a truncated list is `unknown`; a complete list with no match is `false`.
- `ally_count`: the host assembles a bounded visible friendly/neutral
  `allies()` list (same visibility predicate as hostiles, excluding the player
  and the dead). No read ⇒ `unknown`.

The host reads live in `Runtime.autoCombatReads`; the `computed` getter set is
memoized per session revision so a rule loop does not re-run ~60 getters on
every predicate. `capabilities.auto_combat.computed_fields` exposes the enum.

## 4. Still excluded from predicates as data-model choices (recorded, not silently dropped)

- **Tooltip `desc`/`getDesc` as a predicate**: never used to decide a predicate
  and never to auto-identify (a data-model choice; the reads themselves are
  allowed under the two red lines).
- **`most_dangerous`-by-`computed`**: the rank→hp→distance heuristic remains the
  default; the deterministic planner tie-break does not sample RNG (live getters
  may consume RNG internally, which is allowed).
- **`cluster_center` / AoE selffire placement**: needs target geometry +
  `canProject` proof.
- **`map_frontier` / `turn_parity`**: not panel data and not assembled in the
  auto-combat host.

## 5. Validation

- `tests/test_actor_combat.lua` asserts every enum id resolves on an all-native
  actor and that `ActorCombat.field` does live, side-effect-free-by-construction
  path traversal (a missing/nil value → `unknown`).
- `tests/test_auto_combat_policy.lua`: enum accept/reject, numeric comparison,
  unknown fail-closed, `has_effect` `who` validation, `ally_count`.
- `tests/test_auto_combat_snapshot.lua`: `ally_count`, bound-target `has_effect`,
  numeric `computed` forwarding.
- Native probe: new `computed-predicate` scenario (a real `defense.armor`
  comparison decides a rule; a false threshold holds; an arbitrary path is
  rejected by the schema).
- Lua 32 suites / 101,928 checks; Python 33; both `--check` generators green;
  native probe 31/31 on source and `dist/*.teaa`; `dist` 59 files, SHA-256
  `592a1a4685f3aad99e26ffd7373035ed5f79a1881ced191179b183ea49458dd1`.
