# P2.5 — tooltip-safe getters (player-panel / hover-visible predicates)

Date: 2026-09-17 · branch `feat/p2.5-tooltip-getters` · design
[tome-mcp-auto-combat-plugin-design.md](tome-mcp-auto-combat-plugin-design.md) v1.3
§5.2/§5.6/§8. Analysis: `tmp/mcp-play-support/getter-safety-analysis.md`.

P2.5 un-excludes the `computed` / `has_effect` / `ally_count` predicates P2 had
left unwired, using only **audited native getters / bounded visible reads**.
Execution and `change_level` stay default off; no RNG and no target-specific
resolution in reads.

## 1. Normative criterion

A read is **safe** iff both hold:

1. **the player can see the value** on the character sheet, or in a
   hover/tooltip panel; and
2. it comes from an **audited native getter/scalar field**, and is
   **fail-closed** (`unknown`) when that getter is overridden, missing or errors.
   (`ActorCombat.computed` already reports such getters in `computed.unknown`.)

Scalar panel data (stats, speeds, crit, powers, accuracy/APR/damage,
defense/armor/fatigue, saves, resists/penetration/affinity, vision, hp/max,
level/rank, the active-effect list, a talent's static cooldown/cost/range) is
safe.

**Dynamic tooltip text is nuanced and is not a predicate.** It may only be an
*informational* read when the source is an audited native function, proven pure
by an RNG/state **tripwire**, and the entity is already identified/known — never
to decide a predicate and never to auto-identify. That infrastructure is not
built in this slice, so no description source is enabled (recorded below).

## 2. `computed` — finite enum + numeric comparison

`PolicySchema.COMPUTED_FIELDS` is the explicit enum. It is exactly the audited
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
resolves the path by pure traversal; a nil/unknown value makes the evaluator
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

## 4. Still excluded (recorded, not silently dropped)

- **Informational pure-description reads**: the audited-source allowlist + RNG/
  state tripwire + already-identified check are not built in this slice, so no
  tooltip `desc`/`getDesc` source is called. Predicates never use text.
- **`most_dangerous`-by-`computed`**: the audited rank→hp→distance heuristic
  remains the default; nothing rolls RNG.
- **`cluster_center` / AoE selffire placement**: needs target geometry +
  `canProject` proof.
- **`map_frontier` / `turn_parity`**: not panel data and not assembled in the
  auto-combat host.

## 5. Validation

- `tests/test_actor_combat.lua` asserts every enum id resolves on an all-native
  actor and that `ActorCombat.field` is pure traversal.
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
