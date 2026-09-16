# Auto-combat P1a — playtest round 1 feedback (agent-ham-insane-27)

Round: 2026-09-16 · character: Halfling / Celestial-Anorithil / Insane / Roguelike
· policy `anorithil_p1a` · policy hash `3843a4f494f1a7f8336f8b1509756304`
· `allow_auto_combat_execution=true`.

Raw evidence stays under `tmp/` (report, `play-mcp.jsonl`, `game.log`); hashes are
recorded in `validation/2026-09-16-auto-combat/playtest-round27-summary.json`.

## What worked

- The plugin did real native work through `Actions.execute`: 94 decisions —
  `melee` 59, `ray` (`T_MOONLIGHT_RAY`) 8, `finish` (`T_SEARING_LIGHT`) 5,
  `heal` (`T_HEALING_LIGHT`) 4, `sustain:T_HYMN_OF_SHADOWS` 2.
- Sustain maintenance semantics worked: after the human turned Hymn off, the
  plugin re-enabled it; a rejected request (cooldown) was skipped without
  blocking other output.
- Strict pauses fired for `new_enemy` (1) and `no_emergency_action` (1);
  `resume` advanced the generation and continued.
- No bridge `native_error`, no lost lease, no stuck `settling`, no
  `native_pending` stall, no command-id/revision anomaly.

## P0 fixes (this round)

### 1. Silent `hold` deadlock → stop with `no_available_action`

`PolicyEvaluator` returns `hold` when no rule matches; the controller previously
returned `{action='hold'}` without acting, pausing or logging. In a turn-based
game that freezes the fight forever (the human saw a 55 s freeze with revision,
`world_tick` and energy unchanged, while the plugin still owned the lease).

Fix (`AutoCombat.lua`): a `hold` is now a stop that explains itself —
`no_visible_enemies` when nothing is visible, otherwise `no_available_action` —
and `AutoCombatService.step` logs the stop and revokes the lease, so control
returns to the player. No implicit wait rule is added (design §0.1 forbids
deriving waiting from a rule failure).

### 2. Owner exclusivity: remote `act` during `auto_combat`

Design §11.1 requires the remote connection to re-acquire `remote` control
before acting; the playtest showed remote `wait`/`move`/infusion executing while
`control_owner` stayed `auto_combat`.

Fix (`Runtime.lua`):
- an `act` while `auto_combat` owns the lease now returns
  `control_conflict` (new protocol error code, category `state`, recovery
  `connect_explicitly`) before the command sequence is consumed;
- `connect` (control mode) now takes the auto-combat lease atomically:
  `AutoCombat.manualInput` stops the run and the arbiter returns to `manual`,
  then the fresh control token can act;
- `actionable` is false while auto-combat owns the lease, and
  `control_source` reports `auto_combat` ahead of `remote`, so observers are not
  misled during a pause.

## P2 fix: decision tracking

- `denied` events (rule/sustain rejected or un-bindable) are now emitted by the
  controller notify callback and recorded with `rule`/`talent`/`target`/`reason`
  (`native_rejected`, `sustain_rejected`, `target_rebind_failed`).
- Holds are no longer silent because they are stops and are logged.
- Still open (TODO): the full §10 record (`rule_results`, `resources_before/after`,
  `native_result`) is not yet emitted.

## P3 fixes / notes

- `actionable`/`control_source` semantics corrected (above).
- `ControlArbiter.SOURCES` still uses `mcp` rather than the design's `remote`
  and has no `battle_companion`; tracked in the P1a TODO.

## Standalone UI (no MCP client)

The in-game editor is the human path. It is opened with **Ctrl+G** and the run is
started/stopped with **Ctrl+Shift+G** (both also available from the Escape game
menu as `Auto-combat policy`). An in-engine check (session `agent-ham-insane-31`,)
confirmed Ctrl+G opens the `Auto-combat policy` dialog, Escape closes it,
Ctrl+Shift+G attempts the run and reports `not_activated` gracefully without a
preset, and there are no Lua errors. The editor's buttons call the same
`Runtime.autoCombatHandle`/`setAutoCombatExecution` accessors that are unit
tested in `test_runtime.lua`.

The first keybind attempt used Ctrl+A, which the engine already binds to
`DEBUG_MODE`; the final binding moved to the free Ctrl+G / Ctrl+Shift+G pair.

## Suites

- `bash tests/run.sh` — 29 suites green.
- `server/tests` — 32 tests green.
- `generate_protocol.py --check`, `generate_native_seams.py --check` — green.
- `tests/native/auto_combat_run.py` (source and `dist/*.teaa`) — 13 checks,
  pre-declared reasons unchanged.
- `tests/native/run.py` — 100 checks green.

## New/updated unit tests

- `test_auto_combat_controller.lua`: no-available-action stop, denied notify,
  sustain budget, sustain `set_sustain`, empty-hostile melee false.
- `test_auto_combat_service.lua`: exactly-once pause logging, no-enemy self-stop.
- `test_auto_combat_snapshot.lua`: melee known-false for far/empty hostiles.
- `test_auto_combat_host.lua`: `sustain_on`/`talent_known` exposure.
- `test_runtime.lua`: `control_conflict` then reconnect takeover.
