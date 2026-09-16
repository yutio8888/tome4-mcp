# P1b — native activities (`rest` / `auto_explore`) design note

Date: 2026-09-17 · branch `feat/p1b-native-activity` · design
[tome-mcp-auto-combat-plugin-design.md](tome-mcp-auto-combat-plugin-design.md) v1.3 §15 row 2 / §16.

P1b turns the two runtime-managed native paths (`rest`, `auto_explore`) into
**first-class data-policy actions** executed by the local auto-combat plugin,
and extracts a generic **`NativeActivity`** abstraction so the multi-turn
lifecycle is modelled in one place. `change_level` stays opt-in and **default
off**. Execution remains gated by
`config.settings.tome_mcp_bridge.allow_auto_combat_execution` (default `false`).

## 1. §16 decisions (resolved)

1. **daily mode.** Not implemented in P1b (the design defers it to after P1b).
   The default preset stays `strict` (`pause_on_new_enemy=true`); no
   `daily`/auto-rest-combat mode is added. Recorded, not silently dropped.
2. **manual input.** Unchanged from P1a: a manual input always returns the
   single owner to `manual` and tears the MCP transport down (`disconnect`).
   The arbiter never keeps the lease; this is the existing §9.2 behaviour.
3. **rest/auto_explore + change_level.**
   - `rest` and `auto_explore` enter in **P1b** as schema-v1 **additive actions**
     (capability-gated through `capabilities.auto_combat`), with adapters and
     the same budget / `native_pending` / pause-on-interaction semantics as
     P1a actions.
   - `rest` carries an optional bounded `max_turns` (1..1000); absent means the
     native full rest.
   - `auto_explore` keeps every native guard (zone/level `no_autoexplore`, a
     visible hostile refuses) and stops on the first interaction/popup.
   - **`change_level` remains opt-in and default off.** Policies must set
     `permissions.change_level=true`; the schema rejects a `change_level` rule
     otherwise. No preset enables it.

## 2. `NativeActivity` abstraction

### Problem

`rest` and `auto_explore` are multi-turn native processes. Today `Runtime.lua`
handles them with `command.action.type=='rest'` / `=='auto_explore'` branches in
`nativePhase`, `busy`, `boundary`, `settle`, `execute`, `revoke`, the
`beforeRestStep`/`onRestStop` callbacks and the stop helpers. There is no single
description of "what is a native activity, how do I start/stop/reap/describe
it", and the auto-combat executor cannot own one because ownership is expressed
as the *MCP command* (`s.active`).

### Model

`overload/mod/mcp_bridge/NativeActivity.lua` is a registry of **activity
descriptors** plus the owner-agnostic lifecycle. An *activity record* is a
plain table with a stable shape used by both owners:

```
activity = {
  kind      = 'rest' | 'auto_explore',
  owner     = 'command' | 'auto_combat',
  command   = <MCP command> | nil,      -- command owner only
  native    = <p.resting | p.running>,  -- the native handle that means "alive"
  dialog    = <native dialog> | nil,    -- the activity's own popup
  status    = 'starting'|'running'|'stopping'|'stopped'|'failed',
  reason    = <stop reason> | nil,
  turns     = <int>, max_turns = <int|nil>,
}
```

The session holds at most one: `s.native_activity`. A descriptor provides:

| hook | meaning |
| --- | --- |
| `guards(env)` | pre-start native guards; returns a refusal result or nil |
| `start(env)` | invoke the native entrypoint; sets `activity.native`/`dialog` |
| `stepAllowed(env)` | per-step gate (budget / control / failed-cleanup quarantine) |
| `stop(env, reason)` | invoke the native stop entrypoint |
| `ownsDialog(activity, dialog)` | the activity's own popup (rest/running) |
| `describe(activity)` | observer/receipt summary |
| `kindLabel` | `task.rest` / `task.auto_explore` |

The module exposes `NativeActivity.start/stop/live/ownsDialog/describe/reap`
and `phase(session, player)`. Runtime keeps the MCP command receipt fields in
sync (`command.native_rest`, `command.rest_dialog`, `command.turns_executed`,
`command.stop_reason`, …) so the ledger/snapshot surface is unchanged, but all
of the *logic* now lives in the module.

### Ownership and the pump

- A **command-owned** activity is registered on `s.native_activity` and keeps
  the existing MCP receipt semantics; `settle`/`finish` finalize it.
- An **auto-combat-owned** activity is registered on `s.native_activity` with
  `owner='auto_combat'`; it has no MCP command. `nativePhase` treats it as
  `settling` (not "unowned"), `revoke`/`clearUnownedNativeActivity` never
  cancels it, the rest/run callbacks route to it, and the frame pump skips the
  normal controller step while it is live. When the native handle disappears,
  `NativeActivity.reap` finalizes the activity (log + clear) and the controller
  resumes on the next opportunity.

### Executor ↔ controller semantics

- The auto-combat executor maps policy actions `rest`/`auto_explore` to
  `NativeActivity.start`. If the activity is still alive afterwards it returns
  `{status='native_pending'}`; the controller enters `waiting_native` and never
  resubmits. When the native process ends, `phase()` becomes `ready` and the
  controller starts a fresh opportunity.
- An interaction/popup during the activity stops it and surfaces the popup; the
  controller pauses with `player_interaction` (the popup must be answered by the
  human or via `tome.respond`/`tome.dismiss`), exactly like other actions.
- All real attempts keep counting against the per-opportunity budget; a
  rejected/refused start is not retried as-is.

## 3. Schema additions

- `PolicySchema.ACTIONS` gains `rest`, `auto_explore`, `change_level`.
- New optional top-level `permissions = { change_level = <bool, default false> }`.
- `then` for `rest` accepts an optional `max_turns` (1..1000); `then` for the
  other activity actions rejects `talent`/`target`.
- `change_level` is rejected unless `permissions.change_level == true`
  (`change_level_not_enabled`).
- `emergency:true` may only use self-preservation actions (`use_talent`/`attack`);
  `rest`/`auto_explore`/`change_level`/`wait` are rejected as emergency rules
  (`emergency_not_self_preservation`). This keeps the §5.4 critical layer honest.

## 4. Non-goals

No P2/P3 work: no new predicates/selectors, no decision replay, no extra class
adapters, no assistant translation. `change_level` is gated but deliberately not
enabled by any built-in preset.

## 5. Implementation status

- `overload/mod/mcp_bridge/NativeActivity.lua` is the new registry; `Runtime.lua`
  no longer branches on `command.action.type=='rest'/'auto_explore'` for the
  lifecycle. The rest/run callbacks (`beforeRestStep`, `afterRestStep`,
  `markRestInterruption`, `onRestStop`, `onRestStopError`), `nativePhase`,
  `busy`, `clearUnownedNativeActivity`, `revoke`, the dialog boundary and
  `settle` all delegate to the module. The read-only `dry_run` host shares the
  same `autoCombatReads` and the read-only host never executes.
- Schema (`rest`/`auto_explore`/`change_level` + `permissions`), catalogue
  (`ACTIONS` adapters + `change_level` gate), evaluator (`max_turns` carried into
  the act decision) and the executor adapter (`reads.execute` in `Runtime.lua`)
  are wired. The controller reuses its existing `native_pending` wait, so a live
  activity is never resubmitted.
- A frame pump skips the normal controller step while an auto-combat activity is
  live, and `NativeActivity.reap` finalizes it when the native handle ends.

### Validation

- Lua: 30 suites, `test_native_activity` **17** checks, policy **38**,
  catalogue **30**, controller **57**, tasks **65** (incl. an auto-combat-owned
  rest through the pump).
- Native probe: **17/17** now includes `rest-policy` (a data policy that starts,
  owns and yields a real native rest: `wait_native` → `stopped`) and
  `explore-policy` (the native `enemies_in_sight` guard is enforced and declared).
- Python: 33 tests; both `--check` generators green; `dist` repackaged.
