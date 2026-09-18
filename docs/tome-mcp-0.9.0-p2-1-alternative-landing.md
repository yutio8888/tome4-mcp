# P2-1 movement robustness — alternative deterministic landing (S1 Rush re-test)

Date: 2026-09-18. Branch `fix/approach-alternative-landing` off `main@c4b40bc`.
Role: `[Dev]`. Findings: **P2-1** (movement robustness) and **P3-2** (denied
cooldown detail) from the S1 Rush re-test report
(`tmp/mcp-play-support/agent-ham-s1rush2-report.md`, sha256
`298c1cbf66bd4975cfde36213d3c24ce64ef2ff1395a43ac1881196900ecdd1c`).

## 1. Reproduction (pre-fix)

`approach`/`toward` (and any deterministic single-coordinate landing) whose
native request is refused (`native_rejected`) stopped the run with
`stopped reason=no_available_action` even though other feasible adjacent steps
existed. Measured twice in real play (seq 38/57: player (57,6) approaching a
troll at (58,4); the straight landing (57,5) is a tree and is natively refused,
while (58,6)/(56,6)/(57,7) are feasible).

Raw evidence: `{"kind":"denied","seq":57,"tick":3690,"reason":"native_rejected",
"rule":"approach"}` immediately followed by `{"kind":"stopped","seq":58,
"reason":"no_available_action"}`.

Native reproduction kept in the probe scenario `movement-fallback`
(`tests/native/tome-auto-combat-probe/overload/mod/AutoCombatProbe.lua`). On the
pre-fix production code it observes exactly the reported shape:
`movement-fallback:moves` FAIL with `action=stopped reason=no_available_action`,
`movement-fallback:alternative` FAIL (the second plan re-selects the blocked
cell), `movement-fallback:retry-recorded` FAIL. See
`tmp/movement-p2-1/probe-prefix-02.log`.

## 2. Fix

The fix is **fallback selection over the same selector/anchor**, not a strategy
restriction. No action is forbidden and no preset default is changed.

- `MovementPlanner.planStep` / `planTalent` accept an `exclude` set keyed by
  `"x,y"`. Candidate enumeration skips an excluded coordinate and then applies
  the **unchanged** deterministic tie-break and the policy's declared accept
  conditions (visibility/passability/hazard/landing). An excluded exact-grid
  request returns the honest `no_acceptable_destination`.
- `AutoCombat` keeps `rejected_landings` (per action opportunity). On a settled
  `native_rejected` with no energy spent for a plan that has a **single
  deterministic landed coordinate** (`M.landingKey`: `step` plans and
  `landing.kind=='deterministic'` grid plans), the coordinate is recorded and
  the rule is retried instead of denied. The refusal is recorded as a
  `movement_retry` decision and logged through notify (with the underlying
  native code). The rule still counts against `max_actions_per_tick`, and
  `newOpportunity` clears the exclusion set, so the fallback can never loop past
  the budget or across opportunities.
- An integrity guard denies the rule when a provider re-offers an
  already-refused coordinate, so a non-conforming provider cannot resubmit the
  same landing.
- Non-deterministic landings (`bounded`/`random`, i.e. Rush and teleports) have
  no single coordinate key, so they keep the pre-existing deny/stop behavior:
  **Rush/teleport behavior is unchanged**.
- `Runtime.autoCombatReads.plan` forwards `attempt.exclude` into the planner;
  `Runtime.buildAutoCombatHost` passes `exclude` transparently.

Only when every alternative is refused/infeasible does the run keep the honest
`no_available_action` stop.

### 2.1 P3-2 denied cooldown detail

`Actions.execute` now attaches structured cooldown info to a native rejection of
an activated `use_talent` whose own `talents_cd` is still positive:
`missing = {{kind='cooldown',talent=<id>,remaining=<turns>,required=0}}` plus a
human `hint`. This reuses the already-declared `missing` array and `hint` field
(`results.schema.json`), so **no protocol/schema is widened**. `Runtime.commandView`
renders the cooldown entry in its bounded `unmet:` hint.

## 3. Evidence

See `VALIDATION.md` §"P2-1 movement robustness". Raw artifacts under
`tmp/movement-p2-1/`.
