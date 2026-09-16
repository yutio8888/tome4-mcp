# 0.9.0 round-11 backlog validation (2026-09-16)

This snapshot closes the standing backlog (groups A/B/C/E plus status and schema
ergonomics) and records the native acceptance gates D1-D3.

## Backlog closed (commits `0c32129`..`0f30c0`+)

| Item | Outcome |
| --- | --- |
| C snapshot trimming | Compact `observe`/`act`/`status`: talent briefs + inventory/equipment counts; full projection via `inspect`/`observe detail=full`/`tome.list`; `act`/`status`/`respond`/`dismiss` omit map cells unless `include_map=true`. |
| B7 damage scope | `target_geometry.damage_scope` (+ `residual_area_radius`) pre-act and post-act. |
| B8 ground effects | `observe.ground_effects` lists map overlay effects (kind/damage type/remaining/radius). |
| B9 ego names | Empty-parenthesis placeholders are stripped and stored ego names kept. |
| B6 actor ids | `actor_id_scope` documents stability within a level. |
| B1 rejection fields | `native_progression_rejected` carries the static `missing` require fields. |
| A3 CMP closure | `depends_on` closure; `alterTalentCost` and resource `cost_factor` list `combatFatigue`; `closureSummary` exposed via `inspect compatibility`. |
| A4 recovery | `tome.abandon` discards a failed invocation after a native error and re-syncs (no rollback). |
| A5 Command Staff | Opt-in `allow_command_staff`; default still a clear refusal, the chat seam runs detached when enabled. |
| E console key | `key` polls to a settled/stuck action-style status. |
| status | `compact=true` omits snapshot/history/collection refs. |
| schema errors | Every MCP error now carries `{"ok":false,"error":{"code":"invalid_argument"}}` structured content, including validation failures, while keeping strict input schemas. |
| raw_level | Verified live: learned talent `raw_level=2`, unlearned `0` (the round-10 report was a misread). |

## D2 G-04 measurement (live, 200 observe round-trips)

- p50 32.97 ms, p95 40.80 ms, p99 45.61 ms, max 49.85 ms.
- Python console RSS 72,084 KB.
- Lua heap 33,434 KB (fresh session); 39,972 KB after 902 ordinary actions.

`observe.lua_heap_kb` is now part of every snapshot so the long-session trend is
observable. Source: `tmp/mcp-play-support/d2-bench.json`.

## D3 addon combination

`tests/campaign/run.py` loads Battle Companion and Danger Alert and asserts
`battle_companion_stays_idle` while MCP owns control. All 17 bridge checks pass
with both addons present.

## D1 G-03 ordinary flow

Run `campaign-d1-long`: **902 submitted ordinary actions**, all 17 bridge checks
passed (birth, equipment, read-only observation, log cursor, 5 supported core
talents, Trollmire 1→2 change level, native rest refusals, hostile inspect,
combat log). This is a large increase over the m5 522-command run.

**Still partial / driver-limited (not a bridge defect):** the acceptance driver
did not use the five core talents (`successful_talents` empty) and only changed
level once. The character stayed at full life and the wolves never closed to
melee, so the talent branches never fired. Closing G-03 needs a stronger
campaign driver (aggro/pathing), not a bridge change.

The campaign harness was updated for the new contract: `detail=full` for its
equipment projection and `isError` on a terminal failed action is treated as a
structured result rather than fatal.
