# Auto-combat P1a — TODO (after round 1)

Items found by the round-1 playtest that are intentionally not fixed yet.

1. **Full §10 decision tracking.** The log carries
   `kind/reason/rule/talent/target/generation/policy_hash`, but not
   `rule_results`, `rejections[]`, `resources_before/after`, `native_result`.
   The P0 deadlock is now diagnosable (holds are stops and are logged), but a
   replay-grade record is still missing.
2. **`observe.auto_combat` summary (design §11.2).** `observe` does not yet
   include `{enabled, policy_id, policy_hash, actions, paused_reason,
   last_decisions}`; callers use `tome.policy status` + `tome.policy_log`.
3. **ControlArbiter source naming.** `SOURCES={manual,mcp,auto_combat}` uses
   `mcp` where the design owner enum says `remote`, and has no
   `battle_companion`. Behaviour is correct (the Bridge remote lease and the
   arbiter are separate), but the naming does not match §9.1.
4. **`T_BARRIER` rule is unreachable at level 1.** The preset keeps the rule
   behind `talent_known` (correct, no rejected spam), but a level-1 Anorithil
   cannot learn Barrier, so it never fires in the pilot fight. Future presets
   should order the level-1 tree accordingly.
5. **Per-fight restart friction.** With "no idle waiting", the run stops
   (`no_available_action`) when every usable talent is on cooldown, and ends
   (`no_visible_enemies`) after the last enemy. This is the frozen contract, but
   the usability metric "manual restarts" should be re-measured once a
   multi-enemy encounter is played.
6. **Sustain retry cap.** A rejected sustain is retried on the next action
   opportunity; there is no explicit repeat-failure cap yet (design §5.3).
7. **Explicit re-acquire op.** Control is re-acquired with `connect control`.
   A dedicated `auto reacquire`/`control_source` switch was not added because
   `connect` already implements the atomic takeover (§9.2).
