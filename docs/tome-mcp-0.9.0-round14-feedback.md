# Round 14 feedback (0.9.0) — unowned native rest, terminal popup adoption

Round 14 died at Ruins of Kor'Pul level 1 after levelling to 2. It reported two
blocking bugs.

## Fixed in this round

| # | Report | Fix |
| --- | --- | --- |
| 1 | The bridge got stuck in an **unowned** native "Resting" state: `phase=unavailable`, every action `not_ready`, and the character was killed while unable to act | A native rest/run started outside a bridge command is now cancelled on the next write: `tome.act` calls `clearUnownedNativeActivity` (native `restStop`/`runStop`) and re-syncs before rejecting, and `tome.stop` cancels it too. The snapshot exposes `native_activity` (`rest_owned`/`rest_unowned`/`run_unowned`) and `cancelled_native_activity`, and `not_ready` carries a hint. |
| 2 | The death `List` menu was still not a top-level `interaction`, so `dismiss` returned `dialog_not_closed` | Two gaps: the session-root adoption required a live `control_token` (already released at death), and a dialog already owned by the terminal command stayed on the dead invocation. Adoption no longer requires the lease, `Interactions.reown`/`reownAll` move terminal-command dialogs to the session root, and a native `List` menu (`dialog.c_list`) is adopted as a `dialog.choice` so `observe.interaction` lists the death menu options and `tome.dismiss` selects one. |

`observation.dialogs` already exposed the death menu entries
(`kind:"list_menu"`, `options`) from round 13; the missing piece was the
interaction handle, now fixed. Non-terminal revokes (`stop`, lease change) keep
their dialogs on the command so `respond`/receipt semantics are unchanged.

## Evidence

- Round-14 death state: `dialogs=[{kind:"list_menu", options:[Message Log,
  Character dump, Restart the same character, Restart with a new character,
  Exit to main menu]}]` with `interaction:null`.
- `game.log`: `Resting starts...` / `Rested for 1 turns.` followed by
  `Degenerated skeleton warrior killed MCP_agent-ham-insane-14`.

## Tests

Runtime 83→86 (unowned-rest cancellation), Interactive Runtime 107
(dismissTop verification, list-menu adoption, terminal re-own). Lua 18 suites,
Python 32, protocol and native-seam checks green.

## Still open

- **G-03** ordinary finite flow remains driver-limited.
- A live death run is the final confirmation of the menu selection path.
