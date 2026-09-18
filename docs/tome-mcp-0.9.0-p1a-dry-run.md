# Auto-combat P1a completion — `dry_run` + §15/§15.1 audit

> **Supersession banner (v1.6 / `AGENTS.md` + design §8.3).** This is a historical P1a status note. Its
> "no RNG" wording and the §15.1 strategy rows are slice-scope defaults, **not** the current plugin contract:
> current reads may consume RNG (the only red lines are no action submission and no player-unknown information),
> and movement/retreat/kiting/teleport/`rest`/`auto_explore`/`change_level` are ordinary policy actions whose
> restriction is a **`strict` preset default**. The rest of the `dry_run` record stands; historical results kept.

Date: 2026-09-17 · branch `feat/p1a-dry-run` · design
[tome-mcp-auto-combat-plugin-design.md](tome-mcp-auto-combat-plugin-design.md) v1.3.

This pass finishes the last declared P1a deliverable (`tome.policy` /
`dry_run` / status / log) and audits §15 / §15.1 against the implementation.
It does **not** start P1b/P2/P3 and does **not** flip the execution default:
`config.settings.tome_mcp_bridge.allow_auto_combat_execution` stays `false`.

## 1. `dry_run` (design §6.2, §7, §11.1)

`policy_op="dry_run"` evaluates a policy against the **current audited read
snapshot** and returns the decision it *would* make. It never executes: no
`Actions.execute`, no talent invocation, no energy spend, no dialog, no
control-lease change (a read may consume RNG/have read-side effects; that is
allowed). Reads are the same bounded readers the live
host uses, so the condition binding and the reported target are the same object.

Policy resolution: explicit `policy` argument wins; otherwise `running`, then
`approved`, then `draft`. The chosen policy is validated exactly like any other
policy (`invalid_policy` with per-field errors on failure).

Returned payload (subset):

```json
{ "ok": true, "dry_run": true, "executed": false, "side_effects": "none",
  "policy_hash": "…", "schema": "tome-auto-combat/v1", "policy_source": "running",
  "snapshot": { "revision": 1234, "level_instance_id": "level-3" },
  "decision": "act", "layer": "normal", "critical": false, "reason": null,
  "rule": "ray", "action": "use_talent", "talent": "T_MOONLIGHT_RAY",
  "target": "nearest_hostile", "bound_target": "actor-9", "target_distance": 4,
  "binding": { "ok": true, "selector": "nearest_hostile" },
  "results": [ { "rule": "ray", "result": "true", "emergency": false } ],
  "unsupported": [] }
```

- `decision` is `act` / `hold` / `pause`; `reason` carries the pause/hold
  reason (`no_emergency_action`, `unknown_safety`, `budget_exhausted`,
  `no_rule_matched`, …).
- `rule` / `action` / `talent` / `target` are the evaluator's selection.
- `bound_target` / `target_distance` are the values of the same context the
  condition was checked against. When the winning rule selects a non-default
  selector, the service re-binds and re-checks exactly like the controller
  (`binding.rebound=true`); a failed re-bind is reported as
  `binding.ok=false, reason="target_rebind_failed"`.
- `results` is the §10 per-rule trace (`true` / `false` / `unknown` / `denied` /
  `skipped`).
- `unsupported` is kept for the §7 payload shape. Schema v1 rejects unsupported
  talents/actions as `invalid_policy` before planning (nothing is silently
  degraded), so this list is empty for any policy that reaches planning.
- `executed=false` + `side_effects="none"` make the no-op contract explicit.

Availability: dry-run is wired through a **read-only host**
(`buildAutoCombatReadHost`) that is installed regardless of
`allow_auto_combat_execution`. It is a read, so the bridge allows it on an
`observe` connection; policy writes (`set_draft`/`approve`/`activate`/…) remain
`read_only_connection`. The MCP `tome.policy` `policy_op` literal and
`capabilities.auto_combat.policy_ops` now include `dry_run`.

## 2. §15.1 baseline audit

| §15.1 item | Status | Evidence / decision |
| --- | --- | --- |
| Pilot build Halfling / Celestial-Anorithil | **satisfied** | `PolicyPresets.anorithil_p1a`, validated schema + catalog in `test_auto_combat_io.lua` |
| Talent whitelist (8) each with an adapter | **satisfied** | All 8 in `Schema.TALENTS` and `Catalog.ENTRIES`; new catalog test asserts the two sets cannot drift. `T_ATTACK` → native attack; sustains → `set_sustain`; `T_TWILIGHT` is an active resource-conversion talent (not a sustain) and runs through the generic native `use_talent` entrypoint |
| strict (`pause_on_new_enemy=true`), `max_selffire_risk=0` | **satisfied** | preset + `PolicyEvaluator`/`AutoCombat` strict logic; §14 fixture |
| default no auto-retreat | **satisfied (P1a slice default, superseded as a plugin contract v1.6)** | `flee_below_hp_pct` is accepted by the schema/editor but intentionally inert in P1a (design §5.4/§15.1); the P1a schema has no `move{retreat}` rule, but retreat/kiting are ordinary policy actions (a `strict` preset default, not a plugin-wide exclusion) |
| no rest / auto_explore / change_level | **satisfied as the P1a/`strict` slice scope (superseded as a plugin contract v1.6)** | P1a `Schema.ACTIONS={use_talent,attack,wait}`; the auto-combat host maps nothing else at that slice. Current policy admits `move`/`rest`/`auto_explore`/`change_level`; the `strict` preset simply contains no such rules |
| protocol v4 incremental capability gate | **satisfied** | `capabilities.auto_combat` (schema/source/baseline/execution/`policy_ops`, now incl. `dry_run`) |
| `expected_hash` points at one object | **satisfied** | draft writes compare draft hash; approve/activate compare the approved hash; `policy_conflict` on mismatch (`PolicyStore`) |
| `tome.policy` / `dry_run` / status / log | **satisfied** | `dry_run` added here; `status` exposes owner/lease/revision/three hashes/run/last decisions/log status; `PolicyLog` is the bounded §10 ring |

## 3. Decisions recorded (not silently dropped)

- **`min_resource_pct` on sustain entries.** The schema/editor accept it, but
  the controller does not consult it before `set_sustain`; native `set_sustain`
  rejects an under-resourced activation and the rejection degrades gracefully
  (counted, capped, logged). Honouring the threshold is a P1b resource-tuning
  item, not a P1a safety gap.
- **`flee_below_hp_pct`.** Inert by design in P1a (no default auto-retreat,
  §15.1). It remains editable for the future retreat rule.
- **§15 row wording vs §15.1 whitelist.** §15's row mentions
  "Searing·Shadow Blast·Starfall"; the frozen §15.1 whitelist (`T_MOONLIGHT_RAY`,
  `T_SEARING_LIGHT`, `T_ATTACK`, …) supersedes it. No shadow/starfall adapter is
  in P1a.
- **§10 log replay metadata.** Closed in this pass: log entries now carry
  `tick`, `revision` and `level_instance_id` (in addition to the existing
  `policy_hash`, `rule_results`, `rejections`, resources before/after and
  `native_result`), so the log is replay-grade for the decision trace.

## 4. Tests and acceptance

- Lua: 29 suites green; auto-combat service **52** checks (was 34),
  catalog **23** (was 12), runtime **135** (was 128).
- Python: **33** tests (was 32), including the new
  `tome.policy` `dry_run` typing/forwarding test.
- `python3 tools/generate_protocol.py --check` → 0.
- `python3 tools/generate_native_seams.py --check` → 0.
- `python3 tools/package.py` → `dist/tome-mcp-bridge.teaa`, 57 production
  files, SHA-256
  `ea3c9f71ae6c6b8039445cce5d9bfda2889df0a3c7a68c484033a567a18a9487`.

New unit coverage: `test_auto_combat_service.lua` (decision/rule/target/`results`/
snapshot metadata/explicit-policy resolution/emergency pause/rebind/no-executor),
`test_auto_combat_catalog.lua` (whitelist↔catalog drift, log replay metadata),
`test_runtime.lua` (control-mode dry run with execution off, observe-mode dry run,
policy-write still refused in observe), `server/tests/test_server.py`
(`dry_run` enum + forwarded args).
