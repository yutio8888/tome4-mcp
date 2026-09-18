# Round 9 feedback (0.9.0) — `observe.sections`, talent geometry, error ergonomics

> **Historical feedback, non-normative.** This is a past round's processing record. Its remaining TODO
> "**A3** function-level dependency closure" (and any pristine-identity/purity framing) is **superseded** by
> `AGENTS.md` and `docs/tome-mcp-auto-combat-plugin-design.md` §8.3: the project does not gate runtime reads on
> function identity/digest/dependency closure, and is not responsible for other addons' replacements. Only an
> unobtainable value (missing/error/`nil`/invalid return) makes a field `unknown`. Historical results preserved.

Round 9 played a Halfling / Celestial-Anorithil / Insane / Roguelike game
(session `agent-ham-insane-09`) and exercised the round-8 additions
(`inspect kind="character"`, compact `observe.player`, `observe.sections`,
`{"status":...}`, `{"dismiss":...}`, `isError` mapping). This note records what
was found and what changed in response. Raw evidence (console `play-mcp.jsonl`)
stays in the harness and is not committed.

## Fixed in this round

| # | Report | Fix |
| --- | --- | --- |
| 1 | `observe.sections` containing `effects` (or any unknown domain) returned an empty `result` and dropped `phase/actionable/control_lease/revision` | `effects/sustains/resources/stats` are now first-class sections; a player sub-field keeps the `player` container pruned to the requested fields plus identity scalars. The play console no longer summarizes a bridge error into `{}` — it surfaces the error. |
| 2 | Concurrent commands on one session silently crossed responses (map call received the observe reply) | `send.sh` injects a unique `__rid`, the console echoes it, and the wrapper matches its own reply line. |
| 3 | `inspect(kind="talent")` reported `range/cost/target_geometry/requires_target` as `null`; geometry only appeared on `act` | `inspect talent` now advertises the static `range/radius/target_shape/requires_target/current_costs/base_costs/affordable/cooldown_remaining/readiness` at the top level and a static `target_geometry`. `TalentQuery` also falls back to a table target's `range/radius`. |
| 4 | `selffire` was always `"unknown"` | `Details.selffire` reports an explicit `selffire` when the native spec has one; a missing value is `false` only for shapes that cannot contain their origin (`beam/hit/bolt/arrow`) and `"unknown"` otherwise. **Correction (round 19, commit `dd350a0`):** a missing area-shape `selffire` is no longer inferred as `true`; Searing Light targets a ball cursor but deals a hit with `addEffect(..., selffire=false, friendlyfire=false)`, so it has no self-damage. `"unknown"` means "not stated", not "dangerous". |
| 5 | `sections` returned 19-null stubs for omitted domains; unknown section names were silently accepted | Omitted domains are absent (no null stubs); unknown section names return `invalid_sections`. |
| 6 | `ok:true` + `status:"failed"` + `accepted:true` was easy to misread | `CommandView.action_ok` is now emitted (authoritative outcome), documented in the results schema; `accepted` keeps its "admitted" meaning. |
| 7 | `dismiss` with no popup was double-wrapped in `result._error` with no hint | The console unwraps a bridge error into a top-level `{"ok":false,"error":{...}}`; `no_pending_interaction` carries `details.hint`. |
| 8 | `invalid_filter` did not say which keys were allowed | `invalid_filter` now carries `details.allowed_filters = {allowed_keys, required_keys}`. |
| 9 | `inventory_id` looked like a slot but is the container index (two items shared `1`) | Items also expose `container_id` (same value) so `slot` stays the unambiguous position. |
| 10 | `inspect(kind="talent")` used `talent_not_learned` for an id that does not exist | A missing definition now returns `unknown_talent`; a known-but-unlearned talent keeps `talent_not_learned`. |
| 11 | Character panel lacked gold/encumbrance/cooldowns | `Details.player` now adds `gold`, `encumbrance={used,max}` and `cooldowns=[{id,name,remaining}]` (raw stored values). |

`errors.schema.json` (adds `interaction_id`) and `results.schema.json` (adds
`action_ok`) were updated minimally; `tools/generate_protocol.py --check` stays
green.

## Still open (unchanged)

- ~~**A3** function-level dependency closure for CMP-01/03.~~ **Superseded (v1.6, see banner):** no runtime
  identity/digest/closure gate; source records are advisory re-review telemetry only.
- **A4** explicit isolated-state recovery (`abandon`/`reset invocation`).
- **A5** command-staff chat coroutine compatibility (still blocklisted).
- **B1** `native_progression_rejected` missing fields; **B6** actor id
  stability; **B7** `target_geometry.damage_scope`; **B8** ground persistent
  effects; **B9** ego item display names.
- **D1** G-03 ordinary finite flow; **D2** G-04 native memory/latency; **D3**
  addon combination runs.
- MCP schema-level rejections still have empty `structured_content` (SDK
  validation path); only `isError` + text is available.
- `status` replies are still large and mix current vs. historical revisions.
- `progression_talents/raw_level` vs `list talents.level` mismatch was reported
  but not reproduced in the unit fixtures; needs a live check.
