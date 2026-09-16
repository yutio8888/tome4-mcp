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
