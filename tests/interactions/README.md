# Native interactive talent acceptance

Run from the repository root, using the Python environment containing the pinned
MCP SDK. Native runtime/dependency setup is shared with [the native suite](../native/README.md).
Every session name must be new; all characters and save directories are isolated.

```sh
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/interactions/run.py interaction-source-new

tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/interactions/run.py interaction-package-new \
  --addon-archive game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa

tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/interactions/run.py interaction-combo-new \
  --addon-archive game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa --companions
```

The driver uses official MCP stdio for every remote action and answer. Test-only
native fixtures provide learned talents, a stationary enemy, inventory, a golem,
and controlled callbacks. A native enemy is introduced after three Refit steps
to check genuine hostile interruption without consuming gems. They are excluded from the production archive. The
engine itself performs targeting, dialogs, talents, movement, resources, cooldowns,
rest, save and load. Fixtures keep the golem clear of Rush's path and use a numeric
never_move value compatible with native Daze.

Coverage includes real Rush; level-5 Phase Door's two prompts; Precise Strikes
on/no-op/off; custom confirmation meanings; forty native list entries with duplicate
labels and pagination; both native inventory dialog classes; pre-spent energy,
post_action input and nested talents; native self-target warnings; Catapult Trap's
already-placed object surviving aim cancellation; Fearless Cleave direction input;
explicit reconnect; manual handoff and stop; deferred native save and copied-save
load; real Refit Golem's 21 native waiting steps, resurrection and 15 gems; task
interruption, 1000-step budget, and final callback opening another target prompt.

The 0.6 suite adds native item cancellation, two target questions, single charge
and energy spending, duplicate requests, wear requirements, consumable removal,
and a use_talent item. It also checks a spent turn behind simplePopup,
simpleLongPopup and a deferred QuestPopup, then closes them in actual stack order;
ShowLore's native exit is covered separately. Natural rewards and item pickup
recovery are covered by the [notice suite](../notices/README.md).

Generic admission also covers passive/unknown rejection, instant and no-input
talents, cooldown refusal, and a generated healing inscription ID. The last test
intentionally raises `mcp-expected-after-resume-error` after a five-mana mutation.
Its `##Use Talent Lua Error## T_MCP_TEST_ERROR` diagnostic is expected. The API must
report uncertainty, preserve the mutation, quarantine writes and return an applied
receipt without repeating the callback. Other native errors fail acceptance.

Observation, interaction descriptions and task descriptions are checked against
RNG, perception, talent precheck/description and item naming callbacks. Read-only
checks do not alter native state. The three-addon variant additionally proves that
Battle Companion cannot start after the lease is stopped while an old invocation
still waits for manual input.

Physical test input is limited to native cancel/manual handoff, save, and isolated
fixture keys: F9 requests save; F11 enables immediate direction input; F12 prepares
the golem/rest scenario; normal-mode F10 prepares the interrupted Refit scenario; target-mode F10 attempts
normal Battle Companion start.
These commands and diagnostics are test-only and are never part of MCP capabilities.

`result.json`, `mcp.json`, `input.json`, native logs and a frozen `candidate.zip`
remain under `tmp/tome-mcp-validation/sessions/<session>/`. Command IDs and response
IDs are retained in transcripts; the authentication secret is redacted. Natural
campaign acceptance is separate: [growth suite](../growth/README.md).

The Lua interactive-runtime suite uses a controlled native producer with the real
Runtime, Interactions and InvocationTracker to test queued-answer races, stale
revisions, duplicate/conflicting IDs, stop, physical input, disconnect, scene change,
death, manual barriers, response budgets and ignored coroutine-resume errors.

The Lua shell runner uses optimization level 2, matching game/loader/pre-init.lua.
The standalone system LuaJIT's default level 3 intermittently failed an inventory
fixture using repeatedly replaced synthetic class environments; the level-2
diagnostic passed 30/30, and full native runs use the engine's own configuration.

The 0.6.1 suite adds nine native world/dungeon perception fixtures, summarized
by one additional acceptance check. It freezes the Python server and driver in
the new session and records their hashes. The ordinary world-map save, actual
navigation, TCP reconnect and copied-save reload are tested separately by the
[world-map suite](../worldmap/README.md).
