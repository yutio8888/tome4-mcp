# Round 13 feedback (0.9.0) — death menu, walk stop semantics, static geometry

Round 13 died at level 2 in Trollmire (Insane) and reported the death menu,
`walk` stop behaviour, and static talent geometry. Raw evidence is in
`tmp/mcp-play-support/agent-ham-insane-13-report.md`.

## Fixed in this round

| # | Report | Fix |
| --- | --- | --- |
| 1 | The death popup had no top-level `interaction` (only a text widget) and `dismiss` returned `dismissed:true/scope:native_dialog` without closing it | `InteractionDetails.dialogs` now exposes a native `List` menu (`dialog.c_list`) as `kind:"list_menu"` with its entries; `Interactions.adoptNotice` adopts such a dialog as a `dialog.choice` interaction, so `observe.interaction` lists the death menu options and `tome.dismiss` selects one (`option_id`). `Interactions.dismissTop` now verifies the dialog is actually gone before reporting success and returns `false` otherwise; `tome.dismiss` answers `dialog_not_closed` with a hint instead of a false `dismissed:true`. |
| 2 | `walk` with a visible enemy returned `moved_steps:0` / `blocked_on_enemy`, so the character could not move or flee | The console now treats `stop_on_enemy:"visible"` as "stop for an adjacent or newly appeared enemy"; enemies already visible at the start no longer freeze the walk. Stop reasons are `enemy_adjacent`/`enemy_visible`/`not_ready`, and walk entries carry `action_ok`/`hint`. |
| 3 | `inspect` reported `direct_hit`/`selffire:false`/`damage_scope:"single"` for Searing Light, but the runtime target is a self-hitting `ball` (`selffire:true`, area) | `direct_hit` is no longer used to infer self-fire safety or a single-target scope. Only an explicit `selffire` or a known shape decides; a function target stays `"unknown"`. `direct_hit` is still exposed as a stored field. |
| 4 | `observe` did not expose the zone name/depth | The snapshot scene now carries `zone_id`, `zone_name`, `zone_depth` and `level`, and the play console summary includes `scene`. |
| 5 | `mapjson.legend` lacked terrain characters | The console builds the legend from the returned cells (`char → name`) and merges it with the fixed player/unknown entries. |

## Documented, not changed

- Consecutive `move` commands can report `energy_spent:0` with a position change
  when energy carried over from the previous action. This is the native energy
  model; the world tick and action result stay authoritative.

## Still open

- **G-03** ordinary finite flow remains driver-limited (documented in
  `validation/0.9.0/r11-2026-09-16/summary.md`).
- Live death-menu selection is covered by unit tests; a real death run is the
  next confirmation.
