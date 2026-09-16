# Round 12 feedback (0.9.0) — action_ok, top-level interactions, journal re-render

Round 12 played a Halfling / Celestial-Anorithil / Insane character to level 3
and Trollmire 4 (`level-4`, `(11,24)`), completing the Alchemist escort and
several fights, then stopped after failing to find the boss. Its report is
summarized below with the fixes applied.

## Fixed in this round

| # | Report | Fix |
| --- | --- | --- |
| 1 | `native_rejected`/`blocked` failures returned `action_ok: null` or omitted it, contradicting `failed ⇒ action_ok:false` | The Lua `or` chain `(completed and true) or (failed and false) or nil` collapses `false` to `nil`. `commandView` now branches explicitly so `status=failed ⇒ action_ok=false`. |
| 2 | `native_rejected` (e.g. `use_item` Scrying Orb) carried no hint | `CommandView.hint` explains common terminal codes; `use_item` rejections add a native message that distinguishes "no bridge-visible activation" from a native refusal, and `hint` points at `activation.present`/the log. |
| 3 | A command-owned Chat/Quest interaction appeared only in `pending_command.interaction`; top-level `observe.interaction` was null | `observe` mirrors the pending command's interaction to the top level and sets `interaction_scope='owned by the pending command; answer it with tome.respond'`. |
| 4 | A chat answer returned `code:level_changed` and released the lease (`release_reason:scene_changed`) | The parent command was a `change_level` whose escort chat completed the transition, so the code and release are correct. The respond result now also exposes `parent_action` so the inherited code is unambiguous. |
| 5 | The `events` stream intermittently replayed early-level log lines | `Journal.update` keyed lines by row object identity; a level-change re-render rebuilds every row with unchanged text and re-emitted `remove`+`append`. It now compares the ordered visible text and re-keys without replaying. |
| 6 | `inspect` reported Moonlight Ray `damage_scope:"single"` though it is a multi-target beam | `damageScope` checks `beam → line` before `direct_hit → single`. |
| 7 | `observe.talents` brief entries lacked `level` | The play console summary now includes `level`, `mode` and `base_cooldown`. |
| 8 | `character.encumbrance` had no numeric value | It now includes `items_total` (sum of stored per-item `encumber`) plus the stored `max_bonus`, with a scope note; the native strength/effect-scaled total is deliberately not evaluated. |

`results.schema.json` declares the new `hint`/`parent_action` fields; the
protocol check stays green. Tests: Journal 29→30, Observer 94→95, Runtime
82→83, Interactive Runtime 103→104.

## Still open (unchanged)

- **G-03** ordinary finite flow: driver-limited (902 actions, all bridge checks
  pass, but the campaign driver does not force melee/talent use or a second
  descent). Not a bridge defect.
- **B5** weapon-body `def` documentation; **B6** actor-id stability remains a
  documented property.
- `status` payload and MCP schema-error ergonomics were already addressed in
  round 11.
