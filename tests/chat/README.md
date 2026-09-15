# Native Chat acceptance

Run from the repository root with the installed MCP environment. Each command
requires a new session name and preserves its input, result, logs and transcript.
Start native runtimes sequentially so each Xvfb display is reserved before the
next constructor selects one.

```sh
# Actual engine Chat UI; isolated, explicitly labelled gameplay fixture.
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/chat/fixture.py chat-fixture-new --addon-archive game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa

# Ordinary escort from the published Lv5 world-map save; no gameplay fixture.
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/chat/run.py chat-natural-new --addon-archive game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa

# Upgrade and reload the latest published Lv6 Kor'Pul2 save independently.
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/chat/run.py chat-lv6-new --load-only --addon-archive game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa
```

## Fixture

`fixture.py` uses actual `engine.Chat`, `engine.dialogs.Chat`, ToME's Chat UI,
real engine scheduling, and official MCP protocol 2 through stdio. The test
addon defines forty visible choices plus a hidden condition, an automatic page,
a reward, a notice above the farewell, and a second conversation raised by an
NPC after the player has already moved. It checks read purity, duplicate labels,
paging, absent cancellation, reconnect, page identities, duplicate actions and
responses, once-only stat changes, and native keyboard handoff.

A separate fixture context invokes the **unmodified native `escort-quest.lua`**
and `EscortRewards` with the divination reward. MCP selects the visible Willpower
+5 option, checks it once before farewell, repeats the action and response, and
closes the actual “Thank you.” page. This verifies native reward code; it does
not claim the fixture NPC was naturally escorted. The fixture and its talent,
quest context and party settings never enter the production package or normal
campaign test.

## Ordinary campaigns

`runtime.py` verifies the six published campaign source records through 0.6.1,
including report references, exact save files, native engine and supporting addon
hashes. The escort test starts from **campaign-play-v060-02**, level 5 at World
of Eyal `(28,13)`, before the reported escort. The load-only test starts from
**campaign-play-v061-01**, level 6 at Kor'Pul2 `(10,16)`, after the reported
Willpower reward. Both use fresh runtime and home copies, cheat=false, and no
probe or injected gameplay state. The latter must not replay the earlier reward.
Native save serialization rounds the published experience value
`296.5400000000005` to `296.54`; numeric experience uses a small comparison
tolerance, while position, level, stats, inventory and other checked fields
remain exact.

The ordinary driver navigates only from MCP observations, including remembered
observations of the escort. It chooses the actual visible stat reward, preferring
Willpower when offered. It reconnects explicitly after changing level, retains
the original command, and checks duplicate action/response stability on each
native notice and Chat page. It then saves through native Ctrl+S and reloads a
second copy to verify the reward and absence of a pending command.

Dungeon generation and escort type vary across new native runs; a published
world save does not freeze the next map generation's RNG. This small controller
can lose an escort in combat, or find no escort on that floor. Those are retained
failed attempts, not passing Chat evidence or campaign completion. The final
0.7.0 successful run escorted a lost warrior, selected Strength +5, and completed
all 63 actions plus offer/reward/farewell. The separate native reward fixture
covers the reported seer's Willpower +5 branch. All original saves stay intact.

See [0.7.0 evidence](../../validation/2026-09-15-chat/summary.json) for the exact
passing sessions, previous attempts, package hash and frozen driver sources.
