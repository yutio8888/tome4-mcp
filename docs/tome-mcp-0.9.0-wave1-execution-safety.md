# Wave 1 — auto-combat execution-safety fixes (AC-01 … AC-10)

Date: 2026-09-17 · branch `feat/wave1-execution-safety` · review
`tmp/mcp-play-support/wave1-execution-safety-handoff.md`.

Independent review confirmed ten execution-safety findings, all caused (or
hidden) by unit tests injecting `{status='...'}` fake host outcomes. This wave
fixes all ten on the production path and adds production-path tests.

## Decisions (required by the task)

### D1 — AC-03 emergency classification: any talent, guarded on the real target
`emergency:true` is allowed on any `use_talent` or `attack` rule (shape); only
`wait`/`rest`/`auto_explore`/`change_level` are ineligible. There is **no
talent-category whitelist**. Safety comes from the pre-execution adapter guard
over the *actual bound target*: range, `canProject`, geometry, self-hit risk and
ally/friendly-fire risk (reusing `Details.selffire`,
`Details.friendlyfire`, `Details.friendliesInEffect` and `ActorCombat`), plus
`max_selffire_risk`. A rule that passes the general guard is a valid emergency
self-preservation attempt; one that does not is denied (or pauses) exactly like
any other unsafe action.

### D2 — AC-03 selffire threshold
`max_selffire_risk == 0` is a **hard gate**: a candidate with any self/friendly
risk (or unresolvable area self-hit risk) is **rejected and recorded**, and the
next candidate is tried. `max_selffire_risk > 0` is a **pause threshold**: the
same risk pauses the run with `selffire_risk`. Candidate selection uses the same
guard.

### D3 — AC-06 instant definition (native `no_energy` + observed delta)
Confirmed chain: `ActorTalents:useTalent` calls
`self:useEnergy(self:getTalentSpeed(ab) * game.energy_to_act)` only `if not
util.getval(ab.no_energy, self, ab)` (Actor.lua:6352); chants set
`no_energy=true` (chants.lua:33). A completed `use_talent`/`set_sustain` is
**instant** iff the native action succeeded, the observed energy delta is 0, and
the talent's `no_energy` resolves truthy (a boolean `true`, or a function whose
result the observed delta already reflects). `no_energy=false` or a positive
delta is not instant. `instant_attempts` resets only on a new action opportunity
and the `max_instant_per_tick` cap is checked before another submission.

### D4 — AC-09 restart semantics: `start` re-acquires the lease
`start` = ensure lease + run. It re-acquires the auto-combat lease for an
already-active policy when the arbiter owner is `manual`, and fails
`control_not_held` only when another owner holds it. `active` means a policy
exists; the arbiter reports the *current* control. `stop`,
`no_visible_enemies` and manual input release the lease but keep
`store.running`/`active`, so the standalone UI and MCP `start` restart without a
deactivate detour.

### D5 — AC-10 `change_level`: removed from auto-combat claims this wave
`change_level` is removed from `PolicySchema.ACTIONS`/`ACTIVITY_ACTIONS`,
`AutoCombatCatalog.ACTIONS` and `capabilities.auto_combat.actions` (and the
`change_level='opt_in'` claim); `permissions` is removed from the schema.
Rationale: the auto-combat executor has no scene-transition adapter (the MCP
`tome.act change_level` path is a separate command lifecycle with its own scene
invalidation/pause), and the frozen contract keeps auto change-level off. The
general MCP `change_level` action is untouched. Recorded as a future phase.

### D6 — AC-04/D6 sustain and flee thresholds are honest
- `sustain.min_resource_pct` now gates activation: a sustain is only attempted
  when the adapter's resource percentage is known and `>= min_resource_pct`.
- `flee_below_hp_pct` is a distinct **pause** reason (`flee_below_hp_pct`), no
  auto-retreat: while `hp_pct < flee_below_hp_pct` the run pauses and returns
  control to the player.

## Findings to fixes

| AC | Fix |
| --- | --- |
| 01 | Map `native_pending` before the generic success branch; track the live auto-combat root (`s.auto_invocation`) so `nativePhase` reports `settling`; reap it when it settles; `AutoCombat:resume` refuses while native work remains. |
| 02 | Scalar resource projection (`value`, `min_`/`max_`, unlocked-pool filtering) for `resource_pct`/`resource_value`/`resources` logging. |
| 03 | Adapter-certified emergency (D1) + a version-pinned executor guard (range/geometry/self-ally selffire risk) run immediately before native execution and used for candidate filtering. |
| 04 | Order boundaries: no-visible-enemy end → critical layer → sustain (normal layer only). |
| 05 | Unknown `hp_pct` is an executor-level unknown-safety pause before rule/layer evaluation. |
| 06 | Instant classification + per-opportunity `instant_attempts` cap (D2). |
| 07 | `Runtime.hasControl` includes the auto-combat lease / owned native activity. |
| 08 | Activating a changed approved hash stops the old controller generation; the new running hash is never reported before the executor uses it. |
| 09 | `start` re-acquires the lease (D3); UI/MCP consistent. |
| 10 | Remove `change_level` from auto-combat claims (D4). |

## Production-path evidence

The review's root cause was fake `{status='...'}` host outcomes. This wave adds:

- `tests/test_auto_combat_execution.lua`: drives the real
  `Actions.execute` → `Runtime.buildAutoCombatHostFor` mapping, including a real
  suspended `Tracker` root that must surface `native_pending`, scalar resource
  reads, the adapter guard, and the instant classification.
- Native probe scenarios (pre-declared signals) for the behaviours observable in
  the engine: real `native_pending` → `waiting_native` → settle, scalar
  resources, the emergency/selffire guard, instant cap, and `hasControl`
  suppression.

## Validation

- Lua: 33 suites / **101,979 checks**. New/expanded: `test_auto_combat_execution`
  (10, production mapping + a real `Actions.execute` suspended root),
  controller 76 (AC-01 resume, AC-04/05/06, D6, guard paths), service 71
  (AC-08/AC-09), runtime 156 (AC-02 scalar resources, AC-03 guard on the real
  bound target, AC-07 `hasControl`).
- Python: 33 tests; both `--check` generators green.
- Native probe: **35/35** on source and `dist/*.teaa`; new `production-reads`
  scenario covers the real read host (scalar resource + unlock gate) and the
  standalone `hasControl`.
- `tests/test_auto_combat_execution.lua` is the regression test that would have
  caught AC-01/AC-06 (real `Actions.execute` pending root → production mapping);
  `test_runtime.lua` covers AC-02/AC-03/AC-07 on the production host.
- `dist/tome-mcp-bridge.teaa`: 59 files, SHA-256
  `bc9aab70df72a5b7b2565f93b109c290adbc4f222ca23837927137a75e431688`.
- Does not start Wave 2 (protocol generator, error registry, validator
  strictness, CAS-object doc, capability naming, ActorCombat digest audit).
