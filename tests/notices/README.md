# Natural quest notices and item use acceptance

Run with the MCP SDK environment from the repository root. Every session name
must be new. [CampaignRuntime](../campaign/runtime.py) verifies the published
Lv3 source and supporting addons before making an independent copy. No gameplay
probe, attribute changes, granted items or injected rewards are used.

```sh
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/notices/run.py notices-new \
  --addon-archive /workspace/t-engine4/game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa

tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/notices/run.py notices-handoff-new \
  --handoff --addon-archive /workspace/t-engine4/game/addons/tome-mcp-bridge/dist/tome-mcp-bridge.teaa
```

The driver repeats the recorded allocation of already-earned growth points.
Navigation, combat targets, pickups and replies use current MCP observations.
Enemy AI and drops differ between native runs; this is not a deterministic
combat replay. The driver can retreat through the observed entrance, recover
with native rest and return. Combat deaths fail the run and remain in evidence.

The ordinary run fights Prox, closes the resulting QuestPopup, walks onto actual
loot, closes stacked artifact LorePopup windows, picks up Rod of Recall and the
paper that grants Hidden treasure, and answers each native notice separately.
It checks increasing question sequence, retained execution ownership, reconnect,
duplicate actions and duplicate answers. Actual artifact count can vary; the
three different native layers from paper pickup are checked together. Rod is
activated through generic use_item and saved with its real ongoing Recall effect.
This verifies activation, not the eventual 40-turn transfer to the world map.

`--handoff` hands the first natural notice to the player, closes it with one native
Escape, reconnects, and verifies that historical needs_input stays unchanged
while execution releases and experience is not awarded twice. Check the recorded
native_ui and quest text to identify which actual reward this run covered.

Reload and pickup recovery use a further independent copy of a passing natural
run's own save. The original Lv3 source and the derived source both remain intact:

```sh
tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/notices/recovery.py notices-reload-new \
  tmp/tome-mcp-validation/sessions/notices-new

tmp/tome-mcp-venv/bin/python game/addons/tome-mcp-bridge/tests/notices/recovery.py notices-pickup-new \
  tmp/tome-mcp-validation/sessions/notices-handoff-new --pickup-handoff
```

Recovery checks persisted level, experience, life, stats, effects and inventory;
a new session contains no old invocation. Pickup recovery reaches the real Rod
left on the ground, confirms it is already owned while its tutorial is open,
hands off, closes via Escape and verifies command deduplication cannot add a
second Rod. That branch requires a source which saved after the kill and before
the Rod was picked up.

Game logs, input provenance, frozen addon/server code, full MCP transcript and
result JSON remain in the new session directory. The native test runtime chooses
a free X display during setup: start runtimes sequentially, or wait for one to
finish startup before starting another, to avoid a display-selection race.

The focused [interaction suite](../interactions/README.md) additionally uses
explicit test-only native items to exercise multi-question item use, cancellation,
charge accounting, wear refusal, consumable cleanup and use_talent items. Its
fixture coverage is separate from these naturally obtained rewards.
