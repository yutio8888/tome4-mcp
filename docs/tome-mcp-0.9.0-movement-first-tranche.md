# Movement / repositioning first tranche (MOV-1 … MOV-6)

Status: **implementation, ready for review.** Branch `feat/movement-first-tranche`
(baseline `main@a3b3a9a`). This tranche executes the v1.6 plugin-responsibility
principle (`AGENTS.md` §"插件职责边界",
`docs/tome-mcp-auto-combat-plugin-design.md` §0.1/§1.2/§5.3/§5.4/§8.1) and the
`docs/tome-mcp-0.9.0-movement-skills-design.md` design. It does **not** change
`allow_auto_combat_execution` (still `false` by default) and does not start the
assistant/P3 work.

## 1. What changed

### MOV-1 — schema, catalog, deterministic planner

- `PolicySchema` re-admits `change_level` and adds `move`. Both are ordinary
  actions; there is no permission bit.
- A pure-data `destination` object with selectors
  `toward|away|preferred_distance|position|relative|native_landing|native_random`
  and an **explicit** `accept` object
  (`visibility`/`passability`/`hazard`/`landing`). Every accept field is
  required, so there is no hidden plugin default.
- Ordered `target_plan` schema support (`request` actor/grid/self/none). A
  longer-than-one-prompt plan is schema-valid but a documented capability limit
  at execution (below).
- New module `MovementPlanner.lua`: fixed keypad order `[7,8,9,4,6,1,2,3]`,
  deterministic scoring/tie-breaks (`score`, distance from origin, `y`, `x`),
  bounded candidate generation and no RNG. It evaluates the policy's `accept`
  object; it never adds a strategic filter.
- New movement adapters in the v2 `EffectManifest` (source-pinned by
  `tools/generate_effect_manifest.py`): `T_RUSH` (actor-anchored
  `bounded_alternatives` line move), `T_SKIRMISHER_CUNNING_ROLL` (exact grid) and
  `T_PHASE_DOOR` (random self teleport). The guard source-pins and then skips
  movement entries (no damage footprint to model) instead of inventing one.

### MOV-2 — execution

- Runtime lowering: `move` → `{type='move',direction}` through the existing
  `Actions.execute`; a grid `use_talent` → `{type='use_talent',x,y}`; a
  no-target `native_random` teleport → `{type='use_talent'}`; `change_level` →
  the audited native `CHANGE_LEVEL` handler.
- `T_RUSH` is an ordinary actor-target `use_talent`; its landing is the
  actor-anchored native envelope. `T_SKIRMISHER_CUNNING_ROLL` is an exact grid
  request. Native range/collision stays final authority.
- `change_level` re-admitted with a scene lifecycle: a real transition
  (`level_changed`) is preserved through `mapAutoCombatOutcome`, the controller
  stops/reset (`reason='level_changed'`) and the lease is released, so a new
  scene needs an explicit `start`. A pending confirmation
  (`change_level_pending`) pauses for the player instead of being counted as a
  completed transition.

### MOV-3 — honest uncertainty annotation

`dry_run`/decision/log carry the planner annotation: `landing` kind
(deterministic/bounded/random), `visible`, `remembered`, `known_passable`,
`known_hazard`, `confidence` and reasons. Unknown stays `unknown`. The live
provider reads only current FOV (`Observer.terrainVisible`), native
`remembers`/`seens` and the audited `Details.terrain` block status; hidden
occupancy is never inspected.

### MOV-4 — selffire Q4

`max_selffire_risk` is policy-owned: the same known self/friendly risk is a
**reject** at `0` and a **pause** above it, with the footprint reported in the
verdict. There is no unconditional global hard reject. Only an incalculable
footprint fails closed; built-in presets keep `max_selffire_risk=0`.

### MOV-5 — Wave-1 supersession

D5 (removal of `change_level`) is superseded. `change_level` is back in
`PolicySchema.ACTIONS`/`ACTIVITY_ACTIONS`, `EffectManifest.ACTIONS`,
`AutoCombatCatalog`, the runtime capability list, and the schema tests; the
Wave-1 assertions that it was removed are updated and the supersession is
recorded in `docs/tome-mcp-0.9.0-wave1-execution-safety.md`.

## 2. Capability limits (reported, not strategic refusals)

| Limit | Reason | Behaviour |
| --- | --- | --- |
| Multi-prompt `target_plan` execution | `Actions.use_talent` prefills one native prompt; the second becomes a native interaction | schema-valid; the executor pauses/hands the interaction back, never guesses |
| Talent `toward/away/preferred_distance` | bounded grid scan (`SCAN_RADIUS=12`) for candidate enumeration; native range is final | supported; proposals beyond native range are rejected by the native builder |
| `known_safe` hazard | no canonical movement-hazard manifest yet | fails closed (`hazard='unknown'`); a policy can choose `avoid_known`/`any` |
| Phase Door TL4/TL5, Blink, Displacement Shield, Vault, Dimensional Step, Shadowstep, Giant Leap | adapters not yet source-reviewed | capability gap; not generically refused |
| Moving/swapping another actor | typed multi-actor destination/effect semantics not implemented | capability gap |
| `native_landing` exact vs bounded | actor-anchored landings are native choices | `bounded` requires policy `landing='allow_random'`; `exact` accepts `deterministic` |

## 3. Execution-model invariants (unchanged)

One native action per opportunity; per-opportunity attempt and instant budgets;
`native_pending` never resubmitted; manual input revokes the lease; owner
arbitration; read-only `dry_run`; deterministic tie-breaks (no RNG); native
resolution final; scene change pauses/resets and needs an explicit restart.

## 4. Evidence

See `VALIDATION.md` §"0.9.0：移动/重新定位第一段（MOV-1 … MOV-6）" for the
per-ID results, commands, raw artifacts and package SHA-256.
