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

`max_selffire_risk` is policy-owned and numeric: the guard freezes a measured
self/friendly risk and **permits** a known value at or below the threshold,
**rejects** a known value above it, and **fails closed** (rejects) only when the
footprint cannot be computed. The verdict carries the measurement, threshold and
provenance. Built-in presets keep `max_selffire_risk=0`.

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

---

## rev 2 — review fixes (MFT-REV-01 … 09)

Independent review of rev 1 (`4ba89dc2`) returned 0 P0 / 6 P1 / 3 P2. All nine
are fixed; R-1…R-6 stay true.

- **Policy modes (REV-01).** `policy.mode` is explicit normalized data:
  `on_no_enemy` (`stop|evaluate_rules`) and `on_low_hp`
  (`pause|emergency_only|evaluate_rules`). Built-in presets expand the old
  conservative behaviour as data. `emergency` is now a scheduling label only —
  the schema has no action allowlist, and `evaluate_rules` executes any declared
  action at low HP. The executor no longer imposes a global flee pause.
- **Q4 selffire (REV-02).** `EffectRisk.measure` freezes a numeric aggregation
  (self `min(SF,FF)`, friendly `FF`, `unknown` dominates). The guard compares it
  with `max_selffire_risk`: at/under tolerance it **permits** and carries
  `measurement`/`threshold`/provenance; above tolerance or an incalculable
  footprint it rejects. Dry-run, decisions and the policy log report the
  measurement.
- **Ordered `target_plan` (REV-03).** Each step is validated for its request
  kind; `EffectManifest.verify` compares the ordered sequence with the
  source-pinned `movement.target_requests`; the planner consumes the first
  request. A multi-prompt plan pauses with the typed
  `unsupported_target_plan` instead of being ignored.
- **Destination semantics (REV-04).** `landing='deterministic'` rejects every
  non-single landing (`bounded` and `random`). Hazard polarity is
  `true`=known hazard, `false`=affirmatively safe, `unknown`=unknown.
- **Dry-run accuracy (REV-05).** Dry-run runs the same bounded deny/fall-through
  loop as live control (no commit/executor call) and returns the action live
  execution would next submit, with the rejected rules and reasons.
- **Uncertain scene change (REV-06).** `level_changed` is preserved independently
  of the outcome status; any started/completed transition stops/resets the
  controller and refuses `resume`.
- **Decision-log completeness (REV-07).** Movement annotations and guard risk
  detail flow through a bounded projection into `PolicyLog`/replay.
- **Capability reporting (REV-08).** Structured `EffectManifest.UNSUPPORTED`
  entries (talent/scope/missing/reason) and Phase Door `unsupported_variants`
  are published and enforced with the same typed reason.
- **Native applicability (REV-09).** The source and packaged auto-combat probe
  now learn and execute Rush, exact-grid Tumble and random Phase Door through the
  real executor, and run a real native `change_level` stair fixture (the
  `mcp-test` arena is now two levels) observing the scene change, stopped state
  and refused resume.

---

## rev 3 — amended re-review fixes (MFT-REV-03/05/07/08/09, MFT-NEW-01)

The amended re-review (`4ba89dc2`) kept 01/02/04/06 PASS and re-opened five
findings plus one documentation contradiction. All are fixed.

- **Actor `target_plan[].selector` (REV-03).** `EffectManifest.verify` now rejects
  an actor-step selector that contradicts the action binding
  (`target_plan_selector_mismatch`); the planner also returns that typed reason
  defensively instead of silently using the already-bound target.
- **dry-run/live parity (REV-05).** Dry-run uses a distinct `instant_attempts`
  counter (guard-rejected candidates no longer charge an instant slot) and pauses
  on `unsupported_target_plan` exactly as live control does.
- **PolicyLog movement/risk (REV-07).** `PolicyLog.add` now stores the accepted
  movement annotation and permitted-risk detail through a depth/key-bounded
  projection, so `tome.policy_log`/`replay` can reconstruct them.
- **Variant fail-closed (REV-08).** An `unknown`/unavailable effective talent
  level for a level-scoped movement variant fails closed
  (`unsupported_movement_variant`, `unknown=true`). The documented Displacement
  Shield gap has a structured `UNSUPPORTED` entry.
- **Native applicability (REV-09).** The probe now settles each native movement
  task and asserts the final postcondition: Rush reaches its target, Tumble lands
  on the requested cell, Phase Door changes position, and the real stair fixture
  observes the scene change/stopped/refused-resume lifecycle. Actor and grid
  single-target lowering use the engine `force_target` path
  (`Actions.execute` `force_actor`/`force_grid`), which answers every native
  target request instead of only the first pre-filled prompt.
- **Documentation (NEW-01).** The MOV-4 section and the `AutoCombatGuard` header
  now describe the Q4 numeric comparison (permit within tolerance, reject above,
  fail closed only for an incalculable footprint).
