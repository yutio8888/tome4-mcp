# Round 10 feedback (0.9.0) — death popups, rest interruption, action_ok

Round 10 replayed the Halfling / Celestial-Anorithil / Insane game (session
`agent-ham-insane-10`) and died at level 1 in Trollmire. It confirmed most of
the round-9 fixes and found new issues around terminal dialogs and interrupted
commands. Raw evidence stays in the harness.

## Fixed in this round

| # | Report | Fix |
| --- | --- | --- |
| P1 | Death dialog appears in `dialogs` but never as `interaction`; `dismiss` returned `no_pending_interaction`, so the session could not be closed from MCP | `Interactions.adoptNotice` now accepts a command-less session root and falls back to the dialog's `EXIT`/`ACCEPT`/`DEFAULT` virtual or a button callback, so a death popup becomes a normal `dialog.notice` interaction. `tome.dismiss` additionally falls back to `Interactions.dismissTop`, which closes the topmost native popup through its own handler (`scope:"native_dialog"`). |
| P2 | `rest` ended with `unsupported_interaction`, released the lease, and the reason was invisible (`needs_reconnect` with empty `dialogs`) | `revoke` records `s.release_reason`; `observe` now exposes `release_reason` and a human `release_hint` whenever control is released, at the top level and kept through `observe.sections`. |
| P2 | A fatal blow reported `status:"failed"` with `action_ok:true` | `action_ok` is derived from the terminal status (`completed → true`, `failed → false`, in-progress → absent) so it can never contradict `status`. |
| P2 | After death, any action returned `{"ok":true,"result":{"not_ready":{...}}}` with no code | The play console returns `{status:"failed", code:"not_ready", action_ok:false, details:{hint}}` for a not-ready action. |
| P2 | `observe.sections` still returned `talents: []` for an unrequested domain | The console summary only emits list domains that the bridge actually returned (no empty-array stubs). |
| P3 | `character` omitted `encumbrance` entirely when `max_encumber` was not finite | `encumbrance` is always present with `max_bonus`/`current` (may be null) and a scope note. |
| P3 | `selffire` was unknown for every Anorithil attack (all function targets) | `direct_hit=true` now implies `selffire=false`; table targets and the native shape default still apply. |
| P3 | Three inconsistent error shapes (`ok:false` envelope, `ok:true`+`error` object, `ok:true`+error string) | The console unwraps a result whose only key is `error`; `respond` without a pending interaction and unknown top-level keys now emit a top-level `{"ok":false,"error":{...}}`. |
| P3 | `walk` returned one cumulative snapshot per step | The console returns only the final/interrupted entry. |

`progression_talents/raw_level` vs `list talents.level` was reported again but is
not reproduced in the unit fixtures; still tracked. The documentation-only items
(`pickup` requires `item_id`, `move` accepts only `direction`, `respond` target
shape, `mapjson.cells` does not mark the player, infusions via `observe.talents`)
were folded into the round-11 prompt.

## Still open (unchanged)

A3, A4, A5, B1, B6 (actor id stability — confirmed live), B7, B8, B9, D1, D2,
D3, MCP schema-level structured errors, oversized `status` replies.
