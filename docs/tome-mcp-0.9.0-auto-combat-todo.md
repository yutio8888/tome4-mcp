# Auto-combat P1a — open issues and decisions (after rounds 1–2 + cleanup)

Supersedes the earlier open-issues list. Items 1–4 and 6 are **fixed** here;
the rest are explicit decisions or playtest preconditions, not defects.

## Fixed in this pass

1. **Full §10 decision tracking.** `PolicyEvaluator.evaluate` now returns a
   `results` trace (`{rule,result='true'|'false'|'unknown'|'denied'|'skipped',
   emergency}`) for every considered rule, bounded by the rule cap. The
   controller keeps a per-opportunity `rejections[]` (`{rule,reason}`) and the
   service logs `rule_results`, `rejections`, `resources_before`,
   `resources_after` and `native_result` per action; `PolicyLog` bounds the
   arrays (32 rules / 8 rejections).
2. **`observe.auto_combat.last_decisions`.** Added as a bounded (≤5) newest-first
   tail from the controller's ≤8-entry ring; the log stays authoritative.
3. **ControlArbiter source naming.** `SOURCES={manual,remote,battle_companion,
   auto_combat}` (`mcp` renamed to `remote`; `battle_companion` tracked explicitly).
   Behaviour is unchanged; this is §9.1 alignment.
4. **Sustain retry cap (§5.3).** A sustain rejected without spending energy is
   retried on the next opportunity at most `AutoCombat.SUSTAIN_FAILURE_CAP` (2)
   times per run; after that it is disabled for the run and the denial reason is
   `sustain_failure_cap`.
5. **Per-rule replay-grade resources.** The live host exposes
   `resources()` (life/max_life/positive/negative/stamina) and the service
   records before/after around every step.

## Decisions (not defects)

6. **`T_BARRIER` / `T_HEALING_LIGHT` at level 1.** Both rules are gated with
   `talent_known`, so an unlearned talent is skipped without rejected spam. The
   pilot preset is valid at any level; a playtest that wants the emergency layer
   and Barrier to fire must learn those talents first (see precondition below).
7. **Per-encounter restart.** After the last enemy the run ends
   (`no_visible_enemies`) and control returns. This is the frozen contract
   (§0.1); the "manual restarts" usability metric is measured over a longer
   session rather than hidden by auto-restarting.
8. **Re-acquire is `connect control`.** `connect` atomically takes the lease
   (§9.2); no separate reacquire op. A remote `act` while auto owns control
   returns `control_conflict` with `recovery=connect_explicitly`.
9. **Custom dialogs.** The in-game editor is adopted as a `dialog.choice`; its
   own EXIT binding (Escape) closes it. There is no generic "close an arbitrary
   custom dialog" through `dismiss`, and none is needed for the pilot UI.
10. **`allow_auto_combat_execution` stays off by default.** The executor remains
    an opt-in trial (UI `activate` or the setting). Flipping the default would
    change 0.9.0 behaviour; revisit after the metric-driven playtest below and
    after adapter coverage grows.
11. **Harness hotkey limitation.** Under the MCP console, `Ctrl+Shift+G` cannot
    be observed because the console auto-reconnects and `connect` takes the
    auto-combat lease. Harness-only, not a product defect.

## Next validation (preconditions)

- The playtest role must **learn `T_HEALING_LIGHT` (and `T_BARRIER` if desired)
  before running the preset**, so the emergency/`no_emergency_action` paths are
  exercised end to end rather than only in unit tests and the native probe.
- Metric-driven round: declare up front (a) manual restarts per encounter /
  per 10 min, (b) unexpected-pause rate (pause reason ∉ declared set), and
  (c) coverage of the not-yet-observed codes (`budget_exhausted`,
  `action_denied`, `action_uncertain`, `player_interaction`, `control_lost`),
  plus in-session save/load and level-change persistence.

## P1a close-out (dry-run pass)

`dry_run` was the last P1a deliverable; it ships in
[docs/tome-mcp-0.9.0-p1a-dry-run.md](tome-mcp-0.9.0-p1a-dry-run.md). The
following were audited and are **decisions for later phases**, not P1a defects:

12. **Sustain `min_resource_pct` is advisory.** The controller does not gate
    `set_sustain` on it; native `set_sustain` rejects an under-resourced
    activation and the rejection is counted, capped and logged (no energy
    spent). Honouring the threshold is P1b resource tuning.
13. **`flee_below_hp_pct` is inert.** P1a ships no default auto-retreat
    (§15.1); the field stays editable for the future `move{retreat}` rule.
14. **§15 row wording vs §15.1 whitelist.** §15 mentions
    Searing/Shadow Blast/Starfall; the frozen §15.1 whitelist supersedes it, so
    no Shadow Blast/Starfall adapter is in P1a.
15. **§10 log replay metadata** (tick/revision/level_instance_id) is now
    recorded; closed in the dry-run pass rather than deferred.

## P1b close-out (native activities)

P1b ships the generic `NativeActivity` abstraction and the `rest` /
`auto_explore` policy actions; see
[docs/tome-mcp-0.9.0-p1b-native-activity.md](tome-mcp-0.9.0-p1b-native-activity.md).
The three §16 open items are resolved:

16. **daily mode** stays unimplemented (design defers it to after P1b); the
    default preset remains `strict`. No daily preset or risk definition is
    added.
17. **manual input** keeps the P1a behaviour: it returns the single owner to
    `manual` and tears the MCP transport down; the arbiter never keeps the
    lease.
18. **rest / auto_explore / change_level**: `rest` (optional bounded
    `max_turns`) and `auto_explore` enter in P1b as additive schema-v1 actions
    gated by `capabilities.auto_combat`; `change_level` is opt-in via
    `permissions.change_level=true` and is **default off** (no preset enables
    it). The pilot preset is unchanged.

Items 12–13 remain the only deferred tuning decisions (sustain
`min_resource_pct`, `flee_below_hp_pct`); the P1b `NativeActivity` work did not
change their semantics.

## P2 close-out (tuning)

P2 ships the bounded tuning slice documented in
[docs/tome-mcp-0.9.0-p2-tuning.md](tome-mcp-0.9.0-p2-tuning.md):

19. **New predicates/selectors** built only from audited reads:
    `enemy_rank`, `enemy_level`, `enemy_type`, `enemy_is_elite`,
    `enemy_is_boss`, `enemy_distance`, and the `highest_rank_hostile` /
    `most_dangerous_hostile` selectors. Target-related conditions are evaluated
    against the action's selector (`opts.context_for`).
20. **Explicitly excluded in P2** (updated by P2.5): `has_effect` / `computed`
    and `ally_count` are now **resolved** by P2.5 (tooltip-safe panel getters;
    see below). Still excluded: `most_dangerous`-by-`computed` (the audited
    rank/hp/distance heuristic remains the default), `cluster_center`/AoE
    selffire, and `map_frontier`/`turn_parity` (not panel data). Documented
    rather than silently dropped.
21. **Decision replay**: read-only `tome.policy` op `replay` pages the bounded
    §10 trace oldest-first with a run header; the log stays in-memory runtime
    state and `observe` stays bounded.
22. **A/B harness + second class**: `tests/auto_combat_ab.lua` (fixed
    scenarios, baseline vs tuned) and the Halfling/Sun Paladin pilot
    (`sun_paladin_p2`, `T_SUN_BEAM`/`T_WEAPON_OF_LIGHT` adapters).

Items 12–13 (sustain `min_resource_pct`, `flee_below_hp_pct`) were **resolved by
Wave 1** (D6): `min_resource_pct` now gates sustain activation and
`flee_below_hp_pct` is a distinct pause reason (no auto-retreat). See the Wave 1
close-out below.

## P2.5 close-out (tooltip-safe getters)

P2.5 wires the player-panel / tooltip-visible getters into the predicate layer
(doc: [docs/tome-mcp-0.9.0-p2.5-tooltip-getters.md](tome-mcp-0.9.0-p2.5-tooltip-getters.md)):

27. **`computed`** is now a numeric comparison `{field, cmp, value}` over the
    finite `PolicySchema.COMPUTED_FIELDS` enum (the audited
    `ActorCombat.computed` panel paths); arbitrary paths are rejected and an
    overridden/missing getter is `unknown`.
28. **`has_effect`** (with `who ∈ {self,target}`; target = the bound target the
    action uses) and **`ally_count`** now read the bounded visible effect list
    and a bounded visible friendly/neutral `allies()` list; a missing/truncated
    list is `unknown`.
29. **Dynamic tooltip text is never a predicate** and never auto-identifies.
    Informational pure-description reads (audited source + RNG/state tripwire +
    already-identified entity) remain **excluded** in this slice: the tripwire/
    allowlist infrastructure is not built yet, so no such source is enabled.
    `most_dangerous`-by-`computed`, `cluster_center`/AoE and
    `map_frontier`/`turn_parity` remain excluded as before.

## P3 first slice (legacy assistant adapter)

The generation-only adapter is documented in
[docs/tome-mcp-0.9.0-p3-assistant-adapter.md](tome-mcp-0.9.0-p3-assistant-adapter.md).
Decisions recorded here:

23. **Pinned version** `tome-auto_talent_assistant` 2.3.9 on ToME 1.7.4, export
    format `tome-auto-combat-assistant-export/v1`; any mismatch is refused.
24. **Normalized export, not `.tata`/`actor.Assistant`.** The assistant has no
    stable ABI (pointer-rebuilt `.tata`, numeric `conditionType` internals), so
    the adapter maps an explicit, documented export and reports unknown keys
    rather than guessing.
25. **Generation only.** `import_assistant` produces a draft + warnings and
    stores it only with `store=true` (control-only). It never approves,
    activates or starts; native activities and `change_level` are never
    generated.
26. **`has_effect`/`computed`** stay warned as runtime-unknown; wiring host
    getters for panel/tooltip-visible values is a future enablement, out of this
    generation-only slice.

## Wave 1 close-out (auto-combat execution safety)

Wave 1 fixes AC-01 … AC-10 from the independent review; see
[docs/tome-mcp-0.9.0-wave1-execution-safety.md](tome-mcp-0.9.0-wave1-execution-safety.md).
The four binding maintainer decisions are recorded there (D1 any-talent
emergency with a real-target guard; D2 hard gate vs pause threshold; D3
`no_energy` + observed-delta instant; D4 start re-acquires; D5 `change_level`
removed from auto-combat claims; D6 honest sustain/flee thresholds).

27. **AC-01** `native_pending` is mapped before the success branch, the live
    auto root is tracked for `nativePhase`, and `resume` refuses a live body.
28. **AC-02** scalar resource projection (`min_`/`max_`, unlock gate).
29. **AC-03** version-pinned pre-execution adapter guard (range/`canProject`/
    geometry/self-ally selffire) + adapter certification removed (D1/D2).
30. **AC-04/AC-05/D6** boundary ordering (no-enemy → critical → sustain),
    unknown-HP pause, `min_resource_pct` gating and the `flee_below_hp_pct`
    pause.
31. **AC-06** instant classification via `no_energy` + observed delta and the
    per-opportunity instant cap.
32. **AC-07** `hasControl` includes the standalone auto-combat lease.
33. **AC-08/AC-09** replacement activation invalidates the old generation;
    `start` re-acquires the lease (stop/no-enemy/manual restartable).
34. **AC-10** `change_level` removed from the auto-combat policy
    schema/catalogue/capabilities this wave (future phase); the general MCP
    `tome.act change_level` action is untouched.
35. **P2.5 follow-up**: the assistant adapter no longer warns
    `condition_unknown_at_runtime` for `has_effect`/`computed` (the host now
    resolves them).

## Wave 2 close-out (interface / contract)

Wave 2 fixes INT-01 … INT-06 and SAFE-01; see
[docs/tome-mcp-0.9.0-wave2-interface-contract.md](tome-mcp-0.9.0-wave2-interface-contract.md).
Decisions D7–D12 recorded there.

36. **INT-01** the v4 request schema/checker derives the 14 live ops and the
    additive args from `Runtime.dispatch` + the MCP tool list; result shapes are
    per-op representative fields with a checked allowlist gap mechanism.
37. **INT-02** the 75-code error registry is the single source; generated
    Lua/Python envelopes; CI fails on an unregistered emitted code.
38. **INT-03** strict union validation for logging/tie_break/composite
    conditions/action shapes.
39. **INT-04** approve CASes draft, activate CASes approved (prose corrected).
40. **INT-05** remote `auto_explore` added to capabilities/action_support/
    native_tasks.
41. **INT-06** `get`/`clear` added; §11 names blessed (`policy_log`/`replay`/
    `invalid_policy`).
42. **SAFE-01** finite computed getters registered through
    `NativeCompatibility` (digest + identity + declaration + closure).

## Round 3 metric-driven playtest (2026-09-17)

Full report: [docs/tome-mcp-0.9.0-auto-combat-round3-feedback.md](tome-mcp-0.9.0-auto-combat-round3-feedback.md).
Validation: `validation/2026-09-17-auto-combat-playtest-3/summary.json`.

43. **P0 `recover`(wait) stall — FIXED.** The auto-combat pump executes from
    `Game:display`; `p:waitTurn()` cleared `game.paused` but nothing requested the
    next native tick, so the core tick loop parked (`phase=settling`, frozen world
    tick) or the pump went silent. Fix: `core.game.requestNextTick()` after every
    executor action in `buildAutoCombatHost reads.execute`. Regression test:
    native probe `solo-pump:tick-advanced` (fails on unpatched main, passes with
    the fix); 3/3 in-game reproductions now advance the tick (180→190→200).
44. **P1 unaffordable ray soft-lock — FIXED.** An off-cooldown but unpayable
    `T_MOONLIGHT_RAY` was chosen, refused as `native_rejected`, and the run stopped
    at `no_available_action` without spending a turn (negative pool never
    regenerated). Fix: the preset ray rule is gated on
    `resource_value(negative)>=10` and the declared `recover` rule waits on
    cooldown **or** unaffordable. Test: `test_auto_combat_policy.lua`.
45. **P2 `flee_below_hp_pct` control handback — DEFERRED.** The pause keeps
    `control_owner=auto_combat`; remote actions get `control_conflict` and only an
    explicit `connect control` / `auto stop` can proceed, while `resume` re-pauses
    and appends one `paused` event per call (log churn). Deferred because the fix
    changes the control/lease contract (§9) and needs a design decision on whether
    a safety pause may keep the lease; the current workaround is explicit
    `connect control`. Reason: not a P1a pilot blocker and not covered by a frozen
    invariant.
46. **P3 interface polish — DEFERRED.** (a) `respond` on a native popup returns
    `no_pending_interaction` while the working call is
    `dismiss{type=option, option_id=...}`; the hint should name `type`. (b)
    `observe.auto_combat` is sometimes `null` after the run stops / after death.
    (c) `auto stop` writes no `stopped` event, so run boundaries are lost in the
    decision log. Deferred as low-severity client ergonomics; raw evidence in the
    round-3 report.
47. **Metric note — `no_available_action` is an undocumented stop reason.**
    The declared stop set omits it even though it is an established frozen-contract
    stop (`hold` with a visible enemy). Round 3 recorded it as *unexpected* per the
    pre-declared metric and fixed the observed cause (44); future metrics should
    either declare it or keep treating every occurrence as a defect trend.

Round-3 close-out: the P0 (43) and P1 (44) fixes are **merged in `main` at
`9f158f8`** (PR #9, packaged `dist` sha256
`6eaf42e8ad78c7f88da57414ced52dbc0e9d56cac623e266c36672dc47a47ae9`). The fixed
build was soaked in-game (`diag-fix-01`): `recover` waits advanced the tick
(170→180→190→200), `max_consecutive_settling=0`, no `no_available_action`. The
P2 (45) and P3 (46) items remain open/deferred as written above.
