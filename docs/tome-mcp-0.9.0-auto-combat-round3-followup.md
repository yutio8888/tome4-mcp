# Auto-combat P1a — round-3 follow-up status (#45 / #46 / #47)

Small targeted round on top of `main` (`fb2ccdd`, i.e. after the merged
round-3 P0/P1 fix). No new product phase; `allow_auto_combat_execution` still
defaults to `false`.

## #45 — `flee_below_hp_pct` control handback (Option A) — DONE

A **safety pause** now hands control straight back to the player:

- On `flee_below_hp_pct` or `no_emergency_action` the service releases the
  auto-combat lease (`control_owner=manual`), stops the run
  (`run.state=stopped`, `run.reason` keeps the safety reason), and logs the
  transition once.
- A remote `tome.act` then succeeds with the **same** lease — no
  `connect control`, no `control_conflict`.
- `resume` on a stopped/released run returns `not_running` and writes no
  repeated `paused` event. `start` re-acquires the lease (existing D4 semantics).
- Other pauses keep the previous lease behavior (`new_enemy`,
  `player_interaction`, `unknown_safety`, `budget_exhausted`, `action_denied`,
  `action_uncertain`, `rule_loop_limit`). None showed the identical concrete
  breakage, so the scope was not widened.
- Log dedupe: the controller only notifies/logs a `paused` or `stopped`
  transition, never once per repeated call.

Decision-log evidence from the native probe (`safety-handoff`):
```json
{"owner":"manual","run":{"state":"stopped","reason":"flee_below_hp_pct"},
 "log":{"count":1,"total":1},"last_decisions":[{"kind":"paused","reason":"flee_below_hp_pct"}]}
```

## #46 — P3 interface polish — DONE

- **(a)** The play console (`harness/console/agent-play.py`) accepts `respond`
  as an alias for `dismiss` when a native (session-owned) popup is pending, and
  its hint now names `tome.dismiss` with the real answer shapes
  (`{"type":"option","option_id":"..."}`, `{"type":"confirm","value":true}`).
  The product `tome.respond` / `tome.dismiss` docstrings were updated too.
- **(b)** `observe.auto_combat` is always a stable object, never `null`, with
  `enabled/active/policy_id/policy_hash/state/actions/paused_reason/generation/
  last_decisions`. Before activation / after a stop / after death it reports
  `state='stopped'`.
- **(c)** An explicit `auto stop` on a running/paused run records one `stopped`
  decision-log event (a stop of an already-stopped run stays silent).

## #47 — metric hygiene — DECIDED

`no_available_action` is **declared** as a legitimate frozen-contract stop reason
(no executable rule with a visible enemy), alongside `no_visible_enemies`,
`stopped`, `sustain_failure_cap` and `rule_loop_limit`. A recurring
`no_available_action` with no cooldown/resource cause remains a defect signal;
the round-3 unaffordable-ray cause is already fixed. `instant_budget_exhausted`
is likewise a declared internal pause reason. Recorded in
`docs/tome-mcp-0.9.0-auto-combat-todo.md` #47.

## Optional — unobserved-code coverage

Done as deterministic unit tests rather than live-combat probes (cheaper and
repeatable): `test_auto_combat_controller.lua` now hits `action_denied`,
`action_uncertain` and `player_interaction`; `test_auto_combat_service.lua`
hits the service-level `control_lost`. `budget_exhausted` /
`instant_budget_exhausted` were already covered. No random live combat is
required.

## Tests and evidence

- Lua suites: all pass — controller 82, service 94, runtime 167, policy 80,
  interactive runtime 113, … (`bash tests/run.sh`).
- Python: 39/39, including `server/tests/test_harness_respond_hint.py`.
- `generate_protocol.py --check`: OK; `tools/package.py` verifies the generated
  native seams.
- Native auto-combat probe: **41/41** from source and from
  `dist/tome-mcp-bridge.teaa` (new scenarios `safety-handoff` and
  `solo-pump:tick-advanced`).
- Native acceptance suite: **100/100** from source and `dist/*.teaa`.
- Repackaged `dist/tome-mcp-bridge.teaa` sha256:
  `1e671e304ed7bf77cb0e97c761ecced3b54eda80328e9b97187385ef27c28f88`.

Raw probe/run evidence stays under `tmp/tome-mcp-validation/sessions/`.
