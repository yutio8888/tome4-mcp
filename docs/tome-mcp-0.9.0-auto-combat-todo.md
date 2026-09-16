# Auto-combat P1a — open issues (after rounds 1–2)

Only items that are **not** fixed. Fixed/partial items and evidence are in
`docs/tome-mcp-0.9.0-auto-combat-round1-feedback.md` and
`...-round2-feedback.md`.

1. **Full §10 decision tracking (partial).** `native_result` is now recorded and
   denials/stops are logged, but `rule_results` (per-rule tri-state),
   `rejections[]` (rule + reason), and `resources_before/after` are still
   missing, so the log is decision tracking, not replay-grade.
2. **`observe.auto_combat.last_decisions`.** The summary is implemented
   (`enabled/active/policy_id/policy_hash/actions/state/paused_reason/generation`)
   but omits `last_decisions` on purpose to keep `observe` bounded and
   deterministic; callers use `tome.policy_log`. Decide whether to add a tiny
   bounded tail.
3. **ControlArbiter source naming.** `SOURCES={manual,mcp,auto_combat}` uses
   `mcp` where the design owner enum says `remote`, and has no
   `battle_companion`. Behaviour is correct (the Bridge remote lease and the
   arbiter are separate owners), but it does not match §9.1 literally.
4. **`T_BARRIER` rule is unreachable at level 1.** Kept behind `talent_known`
   (no rejected spam), but a level-1 Anorithil cannot learn Barrier, so it never
   fires in the pilot fight. Future presets should order the level-1 tree.
5. **Per-encounter restart.** The declared `recover` wait rule fixed the
   every-cooldown stop, but the run still ends (`no_visible_enemies`) after the
   last enemy, so the operator restarts per encounter. That is the frozen
   contract (§0.1); the "manual restarts" usability metric should be
   re-measured over a longer session.
6. **Sustain retry cap.** A rejected sustain is retried on the next action
   opportunity; there is no explicit repeat-failure cap yet (§5.3).
7. **Explicit re-acquire op.** Control is re-acquired with `connect control`
   (which atomically takes the lease, §9.2). A dedicated `auto reacquire`
   command was not added.
8. **Custom dialogs and `tome.dismiss`.** The in-game editor is adopted as a
   `dialog.choice`; Escape (its EXIT binding) closes it, but there is no clean
   generic "close this custom dialog" through `dismiss`. Future interactions
   pass.
9. **Heal prerequisite.** `T_HEALING_LIGHT` is emergency-only and a fresh
   Anorithil does not know it. The preset gates it with `talent_known`; the
   birth/play fixture should learn it before running the preset.
10. **Default execution flag (decision).** Kept `allow_auto_combat_execution`
    **off** by default: P1a is still pilot scope, the UI/`activate` give an
    explicit local opt-in, and flipping the default would change 0.9.0
    behaviour. Revisit after more playtests and adapter coverage.
11. **Harness-only: Ctrl+Shift+G under the console.** The console auto-reconnects
    after a key press, and `connect` intentionally takes the auto-combat lease,
    so a hotkey-started run cannot be observed through the harness. Not a
    product defect.

Coverage gaps that are not defects: `budget_exhausted`, `action_denied`,
`action_uncertain`, `player_interaction` and `control_lost` were not observed in
play; save/load and level-change persistence of the policy were unit-tested but
not exercised in the round-1/2 sessions.
