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
    gated by `capabilities.auto_combat`; `change_level` is a normal policy action
    in the current schema. **Superseded (v1.6):** the earlier `permissions.change_level=true`
    opt-in / default-off **hard gate** no longer applies — whether to change levels
    is a `strict` preset default, not a plugin-wide permission bit. The pilot
    preset simply contains no change-level rule.

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
close-out below. **Superseded (v1.6):** the "no auto-retreat" part of D6 is a
`strict` preset default (`pause|emergency_only|evaluate_rules`), not a plugin-wide
prohibition — retreat/kiting are ordinary policy actions.

## P2.5 close-out (tooltip-safe getters)

P2.5 wires the player-panel / tooltip-visible getters into the predicate layer
(doc: [docs/tome-mcp-0.9.0-p2.5-tooltip-getters.md](tome-mcp-0.9.0-p2.5-tooltip-getters.md)):

27. **`computed`** is now a numeric comparison `{field, cmp, value}` over the
    finite `PolicySchema.COMPUTED_FIELDS` enum (the live
    `ActorCombat.computed` panel paths); arbitrary paths are rejected and a
    missing/erroring/`nil` getter is `unknown`.
28. **`has_effect`** (with `who ∈ {self,target}`; target = the bound target the
    action uses) and **`ally_count`** now read the bounded visible effect list
    and a bounded visible friendly/neutral `allies()` list; a missing/truncated
    list is `unknown`.
29. **Dynamic tooltip text is never a predicate** and never auto-identifies —
    that is a data-model choice. **Superseded (v1.6):** the tripwire/audited-source
    purity prerequisite is gone; informational description reads are allowed under
    the two read red lines (no action submission, no player-unknown information).
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
removed from auto-combat claims — **D5/D6 superseded v1.6, see the notes above**
and [movement-skills-design](tome-mcp-0.9.0-movement-skills-design.md) §6.2).

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
    `tome.act change_level` action is untouched. **Superseded (v1.6):** the general
    `change_level` action is now re-admitted as a normal auto-combat policy action
    (scene transition still pauses/resets and requires explicit restart).
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
    `NativeCompatibility` (digest + identity + declaration + closure). **Superseded (v1.6):**
    getters are read via the live entrypoints; the registry is advisory telemetry, not a runtime gate.

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
45. **P2 `flee_below_hp_pct` control handback — FIXED (Option A).** A safety
    pause (`flee_below_hp_pct`, `no_emergency_action`) now releases the
    auto-combat lease to `manual` and marks the run `stopped`, so a remote action
    succeeds with no reconnect and no `control_conflict`. `resume` on a
    stopped/released run returns `not_running` and writes no event; `start`
    re-acquires the lease (D4). Other pause reasons keep the previous lease
    behavior. Tests: `test_auto_combat_service.lua` (handback, one event per
    transition, resume refusal, start re-acquire), `test_runtime.lua` (remote act
    succeeds without reconnecting), native probe `safety-handoff` (in-game).
    The controller also deduplicates repeated identical `pause`/`stop` calls.
46. **P3 interface polish — FIXED.** (a) the play console now accepts `respond`
    as an alias for `dismiss` on a native popup and its hint names
    `tome.dismiss` with the `{type=option, option_id=...}` /
    `{type=confirm, value=true}` shapes (the product `tome.respond`/`tome.dismiss`
    docstrings were updated too); test `server/tests/test_harness_respond_hint.py`.
    (b) `observe.auto_combat` is now always a stable object (never null) with
    `enabled/active/policy_id/policy_hash/state/actions/paused_reason/generation/
    last_decisions`; test `test_runtime.lua`. (c) `auto stop` records a single
    `stopped` decision-log event on a real transition; test
    `test_auto_combat_service.lua`.
47. **Metric note — `no_available_action` is now DECLARED.** Decision: add it to
    the metric stop set as a legitimate frozen-contract stop (`hold` with a
    visible enemy and no executable rule), alongside `no_visible_enemies`,
    `stopped`, `sustain_failure_cap` and `rule_loop_limit`. (The separate,
    actionable cause found in round 3 — an unaffordable ray — is fixed in 44; a
    recurring `no_available_action` with no resource/cooldown cause remains a
    defect signal.) `instant_budget_exhausted` is likewise a declared internal
    pause reason, not a defect.

Round-3 close-out: the P0 (43) and P1 (44) fixes are **merged in `main` at
`9f158f8`** (PR #9, packaged `dist` sha256
`6eaf42e8ad78c7f88da57414ced52dbc0e9d56cac623e266c36672dc47a47ae9`). The fixed
build was soaked in-game (`diag-fix-01`): `recover` waits advanced the tick
(170→180→190→200), `max_consecutive_settling=0`, no `no_available_action`. The
P2 (45) and P3 (46) are resolved in the round-3 follow-up
([docs/tome-mcp-0.9.0-auto-combat-round3-followup.md](tome-mcp-0.9.0-auto-combat-round3-followup.md)).

## Round 4: class/build pilots (2026-09-17)

Status doc: [docs/tome-mcp-0.9.0-auto-combat-class-pilots.md](tome-mcp-0.9.0-auto-combat-class-pilots.md).

48. **Three new pilots shipped.** `archmage_arcane_p2` (`T_FLAME`, `T_HEAL`,
    `T_ARCANE_POWER`, `T_SHIELDING`), `corruptor_blight_p2` (`T_SOUL_ROT`,
    `T_BLOOD_GRASP`, `T_DARK_RITUAL`), `berserker_p2` (`T_SHATTERING_BLOW`,
    `T_BERSERKER_RAGE`, `T_DAUNTING_PRESENCE`, `T_ADRENALINE_SURGE`). All
    source-verified, schema/catalogue-validated, evaluator-tested and exercised
    in the native probe (52/52 source + dist).
49. **Deferred/narrowed candidates (not defects).** Corruptor
    `T_HEALING_INVERSION` (utility, wrong tree) and `T_DRAIN` (level-scaled
    range) dropped as damage adapters; Archmage `T_FIREFLASH` (self-fire ball with
    `player_selffire`) and `T_FLAMESHOCK` (instant FF defaults true and the Burning
    Wake ground cone has dynamic SF / default-true FF; the old missing-selffire
    rationale was stale and removed) dropped; Bulwark dropped because its activated
    defensive option is a target-required range-0 area and the rest are sustains.
    Recorded in the status docs with reasons.
50. **Remaining P2 adapter work.** More classes (e.g. a caster with a clean
    ranged single-target heal, or a melee class with a real self-heal) and
    resource-recovery rules (`T_DRAIN`/`T_TWILIGHT`-style) remain future work;
    `allow_auto_combat_execution` still defaults to `false`.

## Round 5: selffire catalog drift + wrong target/getter usage (2026-09-17)

Status doc: [docs/tome-mcp-0.9.0-selffire-correction.md](tome-mcp-0.9.0-selffire-correction.md).

51. **Catalog drift — FIXED.** Searing Light (`range=7`, ball cursor, safe
    ground zone), Moonlight Ray (beam, FF 100 / geometric SF 0), Sun Beam
    (TL3+ radius-2 secondary), Flame (wide-line union + Burning Wake ground),
    Soul Rot (projectile bolt), Blood Grasp (bolt, SF/FF 0), Shattering
    Blow/Attack (melee `attackTarget`). `T_FIREFLASH` documented unsupported.
52. **Engine semantics — FIXED.** `ObservationDetails.selffire`/`friendlyfire`
    now return the normalized engine defaults (true; cone `selffire=false`); the
    geometric shorthand is a separate `footprintContainsOrigin`; the
    projectile-only `playerSelfOverride` is modelled; `damageScope` knows `bolt`
    and `widebeam`; `friendliesInEffect` checks bolt paths and wide-beam width.
53. **Guard real-spec read — FIXED.** `reads.guard` obtains the real target spec
    from the audited native builder (`t.target`) and uses the corrected catalog
    only as a fallback; it evaluates SF/FF/footprint from the real spec plus
    `secondary`/`ground` components. `allow_auto_combat_execution` stays `false`.
54. **V2 effect manifest — FIXED (this round).** Versioned component manifest
    with source hashes/variants/provenance (`EffectManifest`), exact footprint
    parity validated by the disposable native probe (`EffectFootprint`, 12/12
    cases against real `ActorProject:project`), composed player-projectile and
    persistent-ground risk (`EffectRisk`), and source-drift detection
    (`EffectManifestDrift`, `adapter_source_drift`). Dynamic talents remain a
    documented follow-up (`EffectManifest.UNSUPPORTED`). See
    [docs/tome-mcp-0.9.0-v2-effect-manifest.md](tome-mcp-0.9.0-v2-effect-manifest.md).
55. **Dynamic-talent re-admission — FIXED (this round).** `T_FIREFLASH`,
    `T_FLAMESHOCK`, `T_SHADOW_BLAST`, `T_STARFALL` are re-admitted as v2
    manifest entries with a pinned audited `spellFriendlyFire` provider, honest
    Burning Wake / persistent-ball ground components, builder identity pins and
    a range-0 cone guard fix. `EffectManifest.UNSUPPORTED` is empty. See
    [docs/tome-mcp-0.9.0-v2-dynamic-talents.md](tome-mcp-0.9.0-v2-dynamic-talents.md).
    `allow_auto_combat_execution` stays `false`.

## Round S1: Rush native settlement (2026-09-18)

Status doc:
[docs/tome-mcp-0.9.0-auto-combat-native-settlement.md](tome-mcp-0.9.0-auto-combat-native-settlement.md).
Source report: `tmp/mcp-play-support/agent-ham-s1rush-report.md`.

56. **F1 (P0) auto-slot Rush deadlock — FIXED.** `Actions.execute` prefilled only
    the first native `getTarget`; Rush requests a target twice (the use-message
    path then the action), so the second request opened the native targeting UI
    and the auto pump stayed in `waiting_native`/`settling` forever (~500% CPU,
    no Lua error). The internal `authoritative_target` flag now answers **every**
    native target request with the decided target via the native force path,
    keeping the range/self-warning guards (a genuine invalid target is a typed
    native cancel, never bypassed). A residual unanswerable request is surfaced
    as `observe.auto_combat.pending_interaction` and a bounded typed abort
    (`native_timeout`, ticks/wall/frames) cancels the UI, releases the invocation
    and the lease, and settles. Native probe: `movement-talents:rush-settles`.
57. **F3 (P2) `berserker_p2` movement — FIXED.** The stale "no move rule" comment
    is gone; the preset now drives `rush` (stamina/cooldown/distance gated) and a
    deterministic `approach` step. Preset defaults, not plugin restrictions.
58. **F4 (P2) invisible stall — FIXED.** A typed `native_aborted` /
    `native_timeout` policy-log event is recorded with action/talent/target and
    elapsed ticks/frames; `observe.auto_combat.last_native_abort` exposes it.
59. **Remaining follow-up (not this fix).** F2 (no-enemy `enemy_distance` vs
    safety-predicate authoring semantics) is a documented authoring pattern, not
    a plugin defect; no code change. `allow_auto_combat_execution` stays `false`.

60. **P0 fix review follow-ups (all P3, non-blocking; review sha256
    `57b430e766dd935c7f94f5b3463599b691298fd730018004aa7be1921725af40`).**
    - **N1 — fixed**: round-doc §2.1 wrongly described `force_actor`/`force_grid`+`force_target`;
      corrected to state that the auto host uses only `authoritative_target` and the bridge's own
      per-request guard wrapper (force_target bypasses the guard, so it must not be "restored").
    - **N2 — protocol-doc hygiene**: sync `docs/tome-mcp-api-fields.md` with the new client-visible
      fields (`observe.auto_combat.last_native_abort`, `observe.auto_combat.pending_interaction`, and
      the policy-log `action`/`elapsed_ticks`/`elapsed_frames`). No breakage (observe `auto_combat`
      is free-form for clients; the strict `forbid` models govern requests only).
    - **N3 — accepted residual**: if a native flow raised a further UI after receiving the
      authoritative cancel, the `command.target_cancelled` branch skips cancel/dismiss and the UI
      would stay open (recovery only via session adoption). Standard flows treat nil coordinates as a
      terminal cancel (verified for `getTargetLimited`); keep as a documented residual.
    - **N4 — hardening**: in the non-target fallback `Interactions.dismissTop(s.game)` closes the
      game's top dialog regardless of owner; scope it to root-owned handles.
    - **N5 — accepted by design**: authoritative lowering answers every `getTarget` of the invocation
      with the same decided coordinates, including a hypothetical multi-geometry talent; keep it on
      the preset/adapter authoring radar (author policies against talents whose requests share the
      decided target).

61. **S1 Rush 复测新发现（报告 sha256
    `298c1cbf66bd4975cfde36213d3c24ce64ef2ff1395a43ac1881196900ecdd1c`；P0 已验证关闭）。**
    - **P2-1（移动健壮性）— 已修复**（`fix/approach-alternative-landing`）：`approach`/`toward` 的确定落点被
      **原生拒绝**后，不再直接 `stopped reason=no_available_action`。控制器按“同一 selector/anchor + 已声明
      确定性 tie-break + 接受条件”重规划，排除被拒坐标选下一个可行相邻格；排除集按行动机会清空，仍受
      `max_actions_per_tick` 约束，且绝不重复提交同一落点（provider 若重提同一坐标则拒绝该规则）。仅当所有
      备选都不可行/被拒时才保留诚实的 `no_available_action` 停止。非确定性落点（`bounded`/`random`，即 Rush/
      传送）无单坐标键，行为**不变**。见
      [docs/tome-mcp-0.9.0-p2-1-alternative-landing.md](tome-mcp-0.9.0-p2-1-alternative-landing.md)。
    - **P3-2（denied 详情）— 已修复**：原生拒绝的 `use_talent` 若自身冷却仍在计时，`missing` 数组
      会带 `{kind='cooldown',talent,remaining,required=0}` 并附 `hint`。复用已声明的 `missing`/`hint`，
      **不扩宽协议/schema**。

62. **P2-1 / P3-2 review follow-ups（评审 sha256
    `8e67e3917d0fc9b7339d6cc25c2256b6562539ff9bf8e43583aa54c7e05487a2`；verdict merge with
    follow-ups，均 P3，非阻塞）。**
    - **N1**：`PolicyLog.add`（`PolicyLog.lua:44-53`）丢掉了 `movement_retry` 日志里客户端可见的
      `landing` 字段 → 建议在允许字段集中补上 `landing`。
      **已修复**：`PolicyLog.add` 的允许字段集中加入 `landing`；同时 `AutoCombatService` 的
      controller notify 回调也把 `landing` 透传进 `withContext`（否则即使 PolicyLog 允许，
      客户端可见的 `movement_retry` 仍缺该字段）。回归测试：`test_auto_combat_catalog.lua`
      （PolicyLog 条目）与 `test_auto_combat_service.lua`（端到端 service log），两处均在
      还原生产代码后失败、修复后通过。
    - **N2（工具链，重要）**：`tests/run.sh` 的 `task_root` 上溯 4 层目录，**在备用 worktree 中运行会
      静默指向主检出（main）的测试**，导致 worktree 内的验证结果失真。修法：优先用脚本自身所在目录
      推导根（如 `${BASH_SOURCE[0]}` 的 `realpath ../../..`），或显式支持 `TOME_MCP_ADDON_DIR`。
      在修复前，worktree 内验证**必须**用绝对路径逐文件跑（本次 dispatcher/评审均如此，结论有效）。
      **已修复**：`tests/run.sh` 现从 `${BASH_SOURCE[0]}` 推导 `addon_dir`（脚本目录的上一级），
      支持 `TOME_MCP_ADDON_DIR` 覆盖，并从 `addon_dir/../../..` 推导 `game_root` 读取游戏核心；
      运行时会打印 `tests/run.sh: addon_dir=… game_root=…`。在备用 worktree 中运行实测本 worktree
      （sentinel 证明），在规范检出中仍跑 41 套全绿（行为未削弱）。
    - **N3（可选）**：`exclude` 是 opportunity 级全局集合，跨规则可能**过度排除**（保守失败方向，可接受）；
      如需精细可在集合键里带 rule。

63. **N1/N2 review follow-ups（评审 sha256
    `72c764df332a0cc41575da97268d9b4306e1e3ffe9bae38c576929288bccb9b4`；verdict MERGE，3 项 P3 非阻塞）。**
    - **P3-a（环境）**：冻结 worktree 无 `server/.venv`（未跟踪、不在归档内），用系统 python 跑会因缺 `mcp`
      模块产生 2 个收集错误；用 `/workspace/t-engine4/tmp/tome-mcp-venv` 则 39 OK。非本次改动所致。
    - **P3-b（潜在、既有）**：42 个测试文件的根推导回退 `or 'game/addons/tome-mcp-bridge'`（如
      `tests/test_actions.lua:4`），若以**裸相对路径**（`lua tests/test_json.lua`，无 `/tests/` 前缀）
      从非规范 cwd 调用，会**静默测试规范树**。`run.sh` 始终用绝对路径，安全；建议加
      `assert(root,'invoke via absolute path')` 之类护栏。
    - **P3-c（加固）**：`PolicyLog.add`（`PolicyLog.lua:46-47`）复制 `landing` 未做类型守卫（`movement`/`risk`
      用 `boundedObject`）。当前唯一生产者产出受限字符串；建议加 `type(event.landing)=='string'` 守卫。

64. **anor-reg-01 fix2 review follow-up（评审 sha256
    `a91c5955e3ccb2c276d1c0df26c912c4597c35567104f3f45102dceccab61ac5`；verdict merge with
    follow-ups，1 项 P3 非阻塞）。**
    - **RR-1（P3，测试覆盖）**：`replay.status.window` 的 **oldest-first**（`replay`）顺序缺少**已提交**的
      回归断言——本次只对 newest-first（status）有断言，oldest-first 仅经人工/临时验证（实测 replay 2,3,4
      报告 window 2..4）。建议补一条提交进仓库的断言，覆盖两种顺序的 `first_seq<=last_seq` 与 extent。

65. **P3 follow-ups 清尾（本条，分支 `fix/p3-followups`）：四个非阻塞 P3 已全部关闭。**
    详见 [docs/tome-mcp-0.9.0-p3-followups.md](tome-mcp-0.9.0-p3-followups.md)。
    - **#60-N2（文档卫生）**：已同步 `docs/tome-mcp-api-fields.md`——新增 §4.9 `auto_combat` 摘要
      （`last_native_abort`、条件键 `pending_interaction`）与 §6.1.1 policy 事件表
      （`action`/`elapsed_ticks`/`elapsed_frames`/`native_result`/`landing`/`missing`/`hint`/`native_message`），
      并声明请求侧 schema 未变（`protocol/v4/requests.schema.json` 与 `server/` 严格模型无新字段）。
    - **#63-P3-b（工具链）**：42 个可执行测试文件的根推导改为从**本测试自身路径**推导，裸相对调用
      不再静默回退到规范树；无法解析时 fail loudly。绝对路径与 `tests/run.sh` 不变；`bash tests/run.sh`
      仍 41 套全绿。
    - **#63-P3-c（加固）**：确认 `PolicyLog.add` 已用 `boundedString(event.landing,64)` 守卫（`PolicyLog.lua:77`），
      并新增已提交回归：非字符串丢弃、超长截断至 64、合法短串保留。
    - **#64/RR-1（测试覆盖）**：`tests/test_auto_combat_service.lua` 新增 oldest-first `replay` 窗口断言
      （extent == 返回切片、`first_seq<=last_seq`，且与 newest-first `log` 的 extent 语义一致）。

65. **P3 门禁清尾完成（PR #22，merge `55d9ab3365f04359db9abf7124d668a3b5735987`）——以下门禁全部闭环。**
    - **#60-N2 ✅**：`docs/tome-mcp-api-fields.md` 与发射点对齐（§2/§3 协议 4；补齐 `history`/
      `max_retained_commands`/`action_support`/`capabilities.auto_combat`，删除不存在的 `max_commands`；
      `actions`/`native_tasks`/`inspect_kinds` 补全；`last_native_abort` 归为稳定键，`pending_interaction`
      为唯一条件键并如实描述其谓词；§6 补 `shape`/`selffire`；收窄有界/类型守卫声明）。Sol 复核后
      又抓出 DOC-V4-01.1-.5（协议自相矛盾、字段缺失/过期、条件过度声称、交互形状不全、守卫过度声称）
      与 DOC-PROVENANCE-01（基线出处写错），**已由 Dev model B 逐条修正并经同一 Sol 复核 PASS**。
    - **#63-P3-c ✅**：`PolicyLog` 的 `landing` 由 `boundedString(...,64)` 守卫 + **已提交回归**。
    - **#64/RR-1 ✅**：补上 **oldest-first `replay` 窗口断言**（`first_seq<=last_seq`），与 newest-first 共存。
    - **#63-P3-b ✅**：**42 个**测试文件改为从自身路径推导根，裸相对调用**响亮失败**（不再静默测 canonical 树）。
    - 本批**仅触及 `tests/` 与 `docs/`**（零生产改动，`dist` 保持 `536d5e14…`），Sol 终审 **MERGE，0 findings**。

66. **S2 契约修订的应用事故（已修复，`main@ed894fb`）。** 我上一轮用脚本把修订稿
    `tmp/mcp-play-support/s2-contract-revision.md`（sha256 `cd41df23…`）的 Part C 应用到设计文档时，
    脚本在 **C.6 的锚点断言处抛出异常，且在写盘之前**，因此**只有单独跑的 C.6 落入 `813892a`**，
    **C.4（§4.4 执行模型 bullet）、C.5（§6.1 两行）、C.7（措辞一致性）全部缺失**：
    §4.4 前言**前向引用了一条并不存在的 §6.1 签名规则**（悬空引用），`unexpected_target_request`
    那行仍写 "wrong-kind"，`none` 仍被列为 `request_sequence` 可声明值（rev2 已定的排除决议未合并）。
    由 Dev（model A）在 rev3 开工前**独立发现并拒绝实施**（避免了"代码与自身规范文档相矛盾"），
    判定正确。修复：`ed894fb` 逐字补上 C.4/C.5（含 `observed_shape`、安全暂停释放租约、
    `movement_request_kind_unknown` 触发条件收窄）并明确 `none` 不可声明（仅保留 N=1 的
    `target_requests` 叶子）。**教训（我的流程改进）**：应用规范文本必须**逐块写盘 + 逐块校验**，
    或先 `git stash`/写临时文件再一次性提交；不得把一个可能中途失败的脚本当作原子操作。

