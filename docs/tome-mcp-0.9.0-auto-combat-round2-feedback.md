# Auto-combat P1a — playtest round 2 feedback (agent-ham-insane-32)

Round: 2026-09-16 · Halfling / Celestial-Anorithil / Insane / Roguelike · preset
`anorithil_p1a` (`3843a4f494f1a7f8336f8b1509756304`) · `allow_auto_combat_execution=true`.
Raw evidence under `tmp/` (report, `play-mcp.jsonl`, `game.log`); hashes in
`validation/2026-09-16-auto-combat/playtest-round32-summary.json`.

## P0 regression: both pass

- **No-idle-hold.** With a visible forest troll out of melee and the ray on
  cooldown the controller went `acted ray` → `stopped no_available_action`
  (`run.state=None`, `control_owner=manual`), instead of freezing in
  `running/attempts=0`. A deterministic probe (adjacent wolf + a never-matching
  rule) also produced `stopped no_available_action`; 118 stops were
  `no_visible_enemies`. Across 10 samples after a fight the world tick advanced
  normally and then stopped with control returned.
- **Owner exclusivity.** `activate` only → `auto status` `control_owner=auto_combat`
  → remote `wait` returned `control_conflict` (`recovery=connect_explicitly`) and
  left the owner untouched → `connect control` took the lease
  (`control_owner=manual`) → the same `wait` completed.

No `unknown_safety`, no sustain spam (1 sustain event), no `control_lost`, no
`native_error`, no stuck `settling`. Real native work: melee 76, ray 4,
finish 4, heal 2, sustain 1.

## P1 fix: explicit cooldown recovery in the preset

The freeze is gone, but stopping on every cooldown meant the operator had to
manually spend a turn during `T_MOONLIGHT_RAY` cooldown. The pilot preset now
declares a lowest-priority, data-only recovery rule:

```json
{ "id": "recover", "priority": 1,
  "when": { "all": [ {"enemy_count":{"ge":1}}, {"nearest_enemy_distance":{"le":10}},
                    {"not": {"cooldown_ready": {"talent":"T_MOONLIGHT_RAY"}}} ] },
  "then": { "action": "wait" } }
```

This is an explicit policy rule (the design forbids deriving waiting from a
rule *failure*; it does not forbid a declared wait rule). The executor already
maps `wait` to the native wait entrypoint, and the native solo-pump scenario
executes a real wait.

## Other findings

- **P2 `native_result` null** — the round ran the archive before the tracking
  change; `acted` events now carry `native_result` (`AutoCombatService` +
  `PolicyLog`), covered by `test_auto_combat_service.lua`.
- **P2 `auto status` truncation** — the console now requests 64 log entries
  (engine ring is 256).
- **P3 heal prerequisites** — `T_HEALING_LIGHT` is emergency-only and a fresh
  Anorithil does not know it until a generic point is spent. The preset correctly
  gates it behind `talent_known`; the birth/play fixture should learn it or the
  preset should document the prerequisite (tracked in the TODO).
- **P3 Ctrl+Shift+G under the console** — the console auto-reconnects after a
  key press and `connect` intentionally takes the auto-combat lease, so the
  hotkey start cannot be observed through the harness. The binding itself fires
  (`Auto-combat: not_activated` was logged in round-1 UI verification).
- **Editor dialog and `dismiss`** — the custom editor is adopted as a
  `dialog.choice`; Escape (its EXIT binding) closes it. Closing arbitrary custom
  dialogs through `tome.dismiss` is tracked in the TODO.

## Suites

Lua 29 suites, Python 32, both generators, native auto-combat 13 (source and
`dist/*.teaa`), native suite 100.
