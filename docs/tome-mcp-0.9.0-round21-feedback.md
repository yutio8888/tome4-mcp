# Round 21 feedback (agent-ham-insane-21)

Source: `tmp/mcp-play-support/agent-ham-insane-21-report.md` (Halfling/Celestial-Anorithil,
Insane, Roguelike; Trollmire 2 @ (1,8), level 2, alive). Verified good: `auto_explore` no
longer false-interrupts on the "Running..." popup; the escort `Chat respond` command works.

## Fixed
- **3-2 / 3-3 auto_explore stop reason** — when the native run ends within the first
  opportunity the command now returns the real reason instead of a bare `exploring`:
  `enemies_in_sight` (a visible hostile stopped it), `nothing_left` (no progress and
  nowhere to go, e.g. standing on the worldmap exit), or `explore_stopped` (progress
  was made and a native notice/dialog needs observation). Escorts and summons do not
  block. (`Runtime.lua`, commit `d445953`.)
- **3-1 settling observability** — `abandon` now reports the `phase` it left the game in
  and `recovery:"wait_for_ready"` while a native settlement is still in progress, so a
  caller does not mistake a successful discard for a ready lease. The settlement itself
  is native and self-heals; the bridge no longer claims otherwise.
- **3-4 piercing-beam friendly fire** — `inspect(kind="talent", target_id/x,y)` returns
  `target_geometry.friendlyfire` (explicit native value or `"unknown"`) and, when a
  friendly/neutral unit is inside the static footprint, a `friendly_fire_risk`
  `{count, targets}` warning computed from **player-visible** actors only. `use_talent`
  records `target_geometry.friendlyfire` too. (`ObservationDetails.lua`, `Observer.lua`,
  `TalentQuery.lua`, `Actions.lua`; test `test_friendly_fire.lua`.)
- **3-8 invalid_sections** — the error now carries `details.allowed_sections`.

## Acknowledged, not changed (with reason)
- **3-5 walk returns a bare array** — the console `walk` helper returns a list of step
  results; `act`/`status` return an object. Cosmetic console-level inconsistency, not a
  bridge defect. Will align in the console helper.
- **3-6 exit glyph** — `mapfull` uses `>` ("known exit") while `mapjson` uses the native
  terrain glyph `<` ("exit to the worldmap"). Both legends are accurate; left as is.
- **3-7 Healing Light cooldown 10 on learn** — native behaviour; `readiness:"blocked"` is
  the honest report.
- **3-9 `input_owner:"orphaned"`** — naming only; the value correctly means the bridge
  cannot resolve the current native UI owner.
