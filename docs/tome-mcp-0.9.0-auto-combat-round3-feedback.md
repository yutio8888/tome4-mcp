# Auto-combat P1a — metric-driven playtest round 3 feedback

Status: final. The main play session ended (character death) and the fix
confirmation passed in-game; a residual `diag-fix-01` soak is left running.
No test process is being stopped.

## 1. Session, build, character

| Item | Value |
| --- | --- |
| Main play session | `agent-ham-insane-33` (console `agent-ham-insane-33`) |
| Display | `:140` (reused after the old `agent-ham-insane-32` rig was stopped) |
| Build tested | `main` @ `ecb963c`; packaged `dist/tome-mcp-bridge.teaa` sha256 `c5c94255012daee3818be0f86c91e8aa04f7b02e1f43589c2dd1a179dec259c0` |
| Character | Halfling / Celestial-Anorithil / Insane / Roguelike, level 1, Trollmire d1 |
| Birth fixture | `mcp-play-birth-hai2` force-learned `T_HEALING_LIGHT` + `T_BARRIER` (cheat=false) — confirmed in `observe.talents` |
| Preset | `anorithil_p1a` (hash `dae9d04affa8512500f3da40f8820ec7` for the tested build) |
| Play window | 2026-09-17T01:38:47Z → 02:14:45Z (≈36.0 min); character died at (62,12), exp 27.7/29.7 |
| Fix-confirmation session (running) | `diag-fix-01`, display `:140`, fixed dist sha `6eaf42e8ad78c7f88da57414ced52dbc0e9d56cac623e266c36672dc47a47ae9` |
| New preset hash after fix | `b5c357564461941420b2214817df624d` |

## 2. Declared metrics — observed

Declared pause reasons: `new_enemy`, `no_emergency_action`, `player_interaction`,
`unknown_safety`, `budget_exhausted`, `action_denied`, `action_uncertain`,
`control_lost`, `flee_below_hp_pct`.
Declared stop reasons: `no_visible_enemies`, `stopped`, `sustain_failure_cap`,
`rule_loop_limit`.

### 2.1 Manual restarts

- `auto start`: **25** (final transcript count; play report curated 24 over 36.0 min).
- Window 36.0 min ⇒ **≈6.9 restarts / 10 min**.
- Automatic run completed **16** battles (runs with ≥1 native `acted`) ⇒ **≈1.6 start / battle**.
- Breakdown of the 20 logged stops: 14 `no_visible_enemies` (normal clear),
  **6 `no_available_action`** (negative-energy soft-lock, defect P1),
  plus the 2 `settling` freezes and 1 no-enemy no-op start.
- `resume`: 53 (52 of them the operator repeatedly resuming a `flee_below_hp_pct`
  pause — experimental perturbation, not counted as a plugin defect).
- `auto stop`: 14 (used to escape pauses / freezes).

### 2.2 Pause / stop histogram (source: full policy log, 172 events, seq 1..172)

| kind | reason | count | class |
| --- | --- | --- | --- |
| paused | `new_enemy` | 1 | expected |
| paused | `flee_below_hp_pct` | 54 | expected (53 induced by repeated resume) |
| stopped | `no_visible_enemies` | 14 | expected |
| stopped | `no_available_action` | **6** | **UNEXPECTED** |
| denied (not a pause/stop) | `native_rejected` | 6 | outside the declared pause/stop enum |
| acted | melee/ray/finish/barrier/recover/heal | 91 | all `native_result=ok` |

Raw evidence of the unexpected stop (seq 43 representative):
```json
{"generation":2,"kind":"stopped","reason":"no_available_action",
 "rejections":[{"reason":"native_rejected","rule":"ray"}],
 "resources_after":{"life":72.70,"max_life":94,"negative":5.5,"positive":50},
 "resources_before":{"life":72.70,"max_life":94,"negative":5.5,"positive":50},
 "rule_results":[{"rule":"barrier","result":"false"},{"rule":"finish","result":"false"},
   {"rule":"melee","result":"false"},{"rule":"ray","result":"denied"},
   {"rule":"recover","result":"false"}],
 "seq":43,"tick":1122}
```
Game log proof of cause: 6× `[useTalent] TALENT FAILED: T_MOONLIGHT_RAY ... You do not
have enough Negative energy to use Moonlight Ray.`

### 2.3 Previously unobserved codes

| code | hit? | note |
| --- | --- | --- |
| `budget_exhausted` | no | never reached 2 actions/opportunity |
| `action_denied` | no | the 6 rejects surfaced as `denied native_rejected`, not as a pause reason |
| `action_uncertain` | no | all 91 `acted` were `ok` |
| `player_interaction` | no | no level-up (exp capped at 27.7/29.7) and no native dialog during combat |
| `control_lost` | no | lease only moved manual⇄auto_combat by explicit commands |

## 3. Defects found

### P0 — auto-combat `recover` (wait) freezes the game in `settling` / silent idle

- Reproduction: 3/3 `recover` waits froze. Two `phase=settling` freezes (one 13m11s,
  one 20s+) and one silent idle (`phase=ready`, tick frozen, run running).
- Evidence: `phase=settling`, `control=auto_combat`, `world_tick` frozen,
  `player.energy` stuck at 30.77 / 57.0; `connect control` only switched the lease
  and left `phase=settling`/`actionable=false`; only `auto stop` (+Escape) returned
  `phase=ready`.
- Root cause (instrumented native run): the auto-combat pump runs the action from
  `Game:display`. `p:waitTurn()` clears `game.paused`, but the core tick loop is
  parked and nothing calls `core.game.requestNextTick()`, so the game never ticks
  again. The remote `act` path is woken by its `onTickEnd`; the auto path was not.
- Fix (branch `fix/auto-combat-wait-tick`): request the boundary tick after every
  auto-combat executor action in `Runtime.lua buildAutoCombatHost reads.execute`.
- Regression test: native probe `solo-pump:tick-advanced` (fails on unpatched main:
  `turn 0`, `energy 0`; passes with the fix). Native auto-combat probe now 36 checks.

### P1 — unaffordable `T_MOONLIGHT_RAY` → `native_rejected` → `stopped no_available_action`

- Reproduction: 6× at `tick=1122`, `negative=5.5` (< the 10-point cost); the ray rule
  was selected because it only checked cooldown, the native cast was refused, and the
  cooldown-only `recover` rule did not match; the run stopped without spending a turn,
  so negative never regenerated (soft-lock).
- Fix: ray rule is now resource-gated (`resource_value negative >= 10`) and the
  declared `recover` rule waits when the ray is either cooling down or unaffordable.
- Test: `tests/test_auto_combat_policy.lua` (preset waits when unaffordable; casts
  when affordable).

### P2 — `flee_below_hp_pct` pause keeps `control_owner=auto_combat`; `resume` cannot escape

- After the flee pause the operator's remote action is rejected
  `control_conflict ... recovery=connect_explicitly` (design says flee hands control
  back). `resume` re-pauses and writes a new `paused` event each time (53 events),
  which can evict the bounded decision log. Reported; not fixed yet.

### P3 — interface notes

- `respond` is refused on native popups (must use `dismiss(type=option, option_id=...)`);
  the hint is misleading.
- `observe.auto_combat` sometimes `null` after the run stops / after death.
- `auto stop` writes no log event (run boundaries are lost).

## 4. Current step and ETA

- In-game fix confirmation **done** on `diag-fix-01` (display `:140`, fixed dist
  `6eaf42e8…`): the production pump ran three `recover`/wait opportunities in a row
  and the world tick advanced through each one (`recover` tick 180 → `recover` tick
  190 → `ray` tick 200, all `native_result=ok`). A 200 s soak showed
  `max_consecutive_settling = 0` and no `no_available_action`; the earlier build
  froze at the first `recover`. The session is left running (no process stopped).
- Remaining: commit the branch, push and open the PR; write the validation
  summary; update `docs/tome-mcp-0.9.0-auto-combat-todo.md` with the P2/P3 items.

In-game confirmation evidence (`tmp/tome-mcp-validation/sessions/diag-fix-01/`):
```json
{"seq":3,"kind":"acted","rule":"recover","talent":null,"native_result":"ok","tick":180,"generation":1}
{"seq":4,"kind":"acted","rule":"recover","talent":null,"native_result":"ok","tick":190,"generation":1}
{"seq":5,"kind":"acted","rule":"ray","talent":"T_MOONLIGHT_RAY","native_result":"ok","tick":200,"generation":1}
```

| Artifact | sha256 |
| --- | --- |
| `tmp/tome-mcp-validation/sessions/diag-fix-01/game.log` | `5623e70566b5bcca4e9f59be3cbbaf8d7056701eda11a6e1d16ff0fdf6318775` |
| `tmp/mcp-play-support/diag-fix-01.log` | `9cdaaf088a91105e55d2e1e8586d82e6a3bb647f8d147bc83f6a2ea9696eefe1` |

## 5. Evidence paths and sha256 (raw stays under `tmp/`)

| Artifact | sha256 |
| --- | --- |
| `tmp/tome-mcp-validation/sessions/agent-ham-insane-33/play-mcp.jsonl` | `f8687f1ce1acbc4d165eb23af54cf325cad9ace858e72e28f5c36c16fda2b829` |
| `tmp/tome-mcp-validation/sessions/agent-ham-insane-33/game.log` | `d10d157d6a69c37c2d3a04d39f7112830a8e26adcf6e9daa19e28165fef28f3d` |
| `tmp/tome-mcp-validation/sessions/agent-ham-insane-33/decisions.jsonl` | `08bc14cd2580ee765b5aea0053a4ee90e93394fdcb14102f3f09d0cec301ebec` |
| `tmp/mcp-play-support/agent-ham-insane-33-report.md` | `3a479a038542702a6b883f2bb03249f61f0280b2652a06db56222164dc372bd3` |
| `tmp/mcp-play-support/agent-ham-insane-33.log` | `c9726015a6b57a0eec4418eaca3ce10ea26732cd0edac412be860c76453f0778` |
| `tmp/mcp-play-support/t33-timeline.log` | `9809ad9b01034e79ee58809bc23aa44e38e3965aa28b49a5bf1cd89db60d61fc` |
| `tmp/mcp-play-support/full-log33.json` | `79d8ec03c759cfd656edf1e5a2346e098c12e6cba45c8bef0109a175b6988ec0` |
| `tmp/mcp-play-support/settle-evidence.json` | `55787422c5945f3e828d09eb755593f9ead19f847eb28d818132b08798874117` |

Build artifacts:
- branch `fix/auto-combat-wait-tick`, PR #9 (`https://github.com/yutio8888/tome4-mcp/pull/9`)
- fixed packaged `dist/tome-mcp-bridge.teaa` sha256
  `6eaf42e8ad78c7f88da57414ced52dbc0e9d56cac623e266c36672dc47a47ae9`
- native auto-combat probe 36/36 (source + dist); native acceptance suite 100/100
  (source + dist); Lua suites pass (policy 80); Python 34/34.
