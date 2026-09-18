# Auto-combat movement native settlement — P0 (Rush deadlock)

Date: 2026-09-18. Branch `fix/auto-movement-native-settlement` off `main@3d78590`.
Role: `[Dev]`. Findings F1 (P0), F3 (P2) and F4 (P2) from the S1 Rush report
(`tmp/mcp-play-support/agent-ham-s1rush-report.md`).

## 1. Reproduction (pre-fix)

Berserker (Halfling, Insane), policy rule `use_talent T_RUSH target=nearest_hostile`
with `enemy_distance∈[2,6]`, enemy at distance 3. The auto pump submits **one**
native `use_talent`; `game.log` logs `... rushes out!`; then the world tick and
revision freeze, phase stays `settling`, `run={actions=0,attempts=1,state="waiting_native",
reason="native_pending"}` forever, t-engine spins at ~500% CPU, the native target
cursor stays on screen, `observe` reports `dialogs=[]` and no interaction, and
there is no Lua traceback.

### Mechanism (verified)

`Actions.lua` installed a `p.getTarget` wrapper that consumed **only the first**
native request and then restored the real `Player:getTarget`
(`Actions.lua:219-275`). Rush asks for a target **twice**: `ActorTalents.useTalent`
calls `logTalentMessage` → `useTalentMessage` → `self:getTarget()` (before the
action), and then `Rush.action` calls `getTargetLimited` → `getTarget`.
The message-path request consumed the one-shot prefill; the action-path request
fell through to `game:targetGetForPlayer`, which entered exclusive targeting and
`coroutine.yield()`ed. The auto pump has no mechanism to answer or surface that
UI, so the invocation never settled — an unbounded `waiting_native`.

The manual slot works because `Runtime.execute` leaves the native request visible
as an `awaiting_native_input` interaction; `respond{type:actor}` resumes it.

## 2. Fix

### 2.1 Authoritative native target (F1, primary)

A new internal action flag `authoritative_target` (validated as boolean) makes the
decided target answer **every** native `getTarget` request for the whole
invocation, driving the same native `force_target` path the manual slot exercises.
For each request the wrapper still:

- records the native target geometry once (shape/range/radius/selffire/…),
- evaluates the native **range** guard and the native **self-target warning** —
  a genuinely invalid target is answered as a native target **cancel** (nil
  coordinates) with a typed code (`target_out_of_range` / `self_target_warning` /
  `target_out_of_bounds`), never bypassed,
- records `command.target_cancelled` so the executor maps the typed reason.

The auto host sets `authoritative_target=true` whenever it lowers an actor or grid
plan (`Runtime.lua` `reads.execute`), for an actor request, a grid request, and a
plain auto actor-target talent with no movement plan alike. It does **not** use the
engine `force_target` field (`force_actor`/`force_grid` were removed from the auto
host): force_target is installed inside native `prepareUse` and bypasses the native
target request, whereas the bridge's own wrapper evaluates the native range /
self-warning guard **for each request** of the invocation and only then answers —
strictly safer, and the reason later requests are answered too. Remote commands keep
the legacy one-shot prefill (their later prompts are answerable interactions).

This is a structural fix at the executor boundary; it is talent-independent and
also covers the message-then-action pattern any such talent may have.

### 2.2 Transparent fallback + bounded typed abort (F1, safety net)

If a native request still opens a UI the executor will not answer, the invocation
is surfaced through `observe.auto_combat.pending_interaction` with the manual
slot's interaction shape (`kind`, `shape`, `range`, `answer_types`, …), so a caller can see it.
Independently, `Runtime.onFrame` runs `guardAutoInvocation`: a live auto
invocation that exceeds a bounded number of **ticks / wall time / frames**
(`AUTO_NATIVE_TIMEOUT_TICKS=200`, `AUTO_NATIVE_TIMEOUT_MS=15000`,
`AUTO_NATIVE_TIMEOUT_FRAMES=600`) is aborted typed:

- cancel the native target UI through its own cancel path
  (`Interactions.cancelTarget`) or dismiss a non-target popup,
- release the invocation / root and clear any lingering target handle,
- release the lease and stop the controller (`AutoCombatService.nativeAbort`),
- settle with the typed code `native_timeout`.

A live multi-turn native task (rest / auto_explore) is legitimate settling and is
never aborted. The bound only decides "the native leaf call never settled"; it is
not a strategic rule.

### 2.3 Typed policy-log event (F4)

`AutoCombat:nativeAborted` records a `native_aborted` decision and notifies the
service; `PolicyLog.add` now carries `action`, `elapsed_ticks` and
`elapsed_frames`. The event includes the action, talent, target and elapsed
ticks/frames, so the stall is no longer invisible in `tome.policy_log` / `replay`.
`observe.auto_combat.last_native_abort` exposes the last abort to a caller.

### 2.4 `berserker_p2` movement rule (F3)

The stale "the policy action set has no move rule" comment is replaced. The preset
now closes a visible foe outside melee:

- `rush` (priority 40): `T_RUSH` toward the bound hostile when known, off
  cooldown, `stamina >= 22` and `enemy_distance` in `[2,6]`, using the
  `native_landing` destination the movement adapter already supports;
- `approach` (priority 30): a deterministic `toward` step for every other
  visible non-melee foe.

These are **preset defaults**, not plugin-level restrictions: a policy author can
still choose anything the executor supports. The preset passes the schema and the
catalogue.

## 3. Tests

| Layer | Test | Assertion |
| --- | --- | --- |
| Unit (`test_talent_query.lua`) | authoritative actor/grid prefill | every native request returns the decided target; no native UI; landed postcondition; range/self-target guards preserved; validation of the flag |
| Production (`test_runtime.lua`) | stalled auto invocation | no resubmission while pending; typed `native_timeout` within the bound; typed log event with action/talent/elapsed; lease released; session ready again |
| Controller (`test_auto_combat_controller.lua`) | `nativeAborted` | typed decision + notify + rejection with action/talent/target/elapsed |
| Service (`test_auto_combat_service.lua`) | `nativeAbort` | typed log event reaches `tome.policy_log`; lease released; run stopped |
| Pilot (`test_auto_combat_pilots.lua`) | `berserker_p2` F3 | Rush in window; approach out of window / no Rush / no stamina |
| Native probe | `movement-talents:rush-settles` | Rush settles on the first opportunity, no active target UI |
| Regression | full Lua suite | one-opportunity budget, `native_pending` non-resubmission, manual lease revocation, dry-run non-execution stay green |

## 4. Invariants preserved

- `allow_auto_combat_execution` stays `false` by default; live execution is still
  opt-in.
- No game core file is modified; all changes stay in the addon.
- No strict runtime-entry auditing; live getters/builders are called directly.
- The bounded abort covers only "the native call never settled" — not strategy.
