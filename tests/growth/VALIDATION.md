# Ordinary growth and item acceptance — 0.4.0

Validated on 2026-09-15 against the frozen 0.4.0 source and formal archive.
The archive contains 15 production files and has SHA-256
`ff627dd0a9c686b27da034e86db0a5b3bc3ce075e1feeb7858aa1dc16e2c9a74`.
Every archive file matches the frozen source runtime byte for byte. Both runs
use identical frozen Python-server and test-driver hashes.

[Structured summary and all hashes](../../validation/2026-09-15-growth/growth-summary.json)

## Final results

| Run | Checks | Unique action commands | Completed | Expected refusals | Duplicate replays |
| --- | ---: | ---: | ---: | ---: | ---: |
| [Source, category unlock](../../../../../tmp/tome-mcp-validation/sessions/growth-source-final-01/result.json) | 91 | 76 | 63 | 13 | 7 |
| [Formal package, category mastery](../../../../../tmp/tome-mcp-validation/sessions/growth-package-final-01/result.json) | 92 | 73 | 59 | 14 | 7 |

There were 83 and 80 `tome.act` calls respectively when duplicate replays are
included. All expected refusals preserve player state, consume no energy, and
advance no world turns. Both runs finished without Lua errors.

Both start from separate copies of the recorded level 3 Cornac Berserker at
`(64,36)` in Trollmire 2, with 9 attribute, 5 class, 4 generic and 1 category
points. `cheat=false`; no fixture, skill/item injection or attribute editing is
used. All gameplay requests use the official MCP SDK and native addon actions.
Native Ctrl+S is used solely to save.

## Growth verified in the actual character

| Property | Before | After |
| --- | ---: | ---: |
| Strength | 15 | 20 |
| Constitution | 13 | 17 |
| Stunning Blow raw level | 1 | 3 |
| Warshout raw level | 1 | 3 |
| Rush raw level | 0 | 1 |
| Heavy Armour Training raw level | 1 | 2 |
| Vitality raw level | 0 | 3 |
| Unspent attribute / class / generic / category points | 9 / 5 / 4 / 1 | 0 / 0 / 0 / 0 |

The source run unlocks `cunning/dirty`. The package run improves
`technique/2hweapon-assault` mastery from 1.3 to 1.5, then verifies that a second
improvement is refused. Category operations preserve raw talent levels.

The runner checks point-result metadata, native one-point costs, class versus
generic pools, new Rush learning cooldown, and unchanged cooldowns when
upgrading previously known talents. Each pool has an idempotency replay.
Unknown IDs, insufficient points, Death Dance's level requirement, Heavy Armour
Training's strength requirement, and Bloodthirst's category level requirement
are tested against the actual saved character.

## Natural item and native energy

Both runs find a naturally occurring **iron greatmaul**, move to it, pick it up,
equip it in MAINHAND, remove it to inventory, then equip it again. The initial
iron greatsword remains owned in the backpack. Pickup, equip, and unequip each
have a duplicate-command check. The single-object pickup and ordinary equipment
operations each consume the native 1,000 energy. Distant pickup, equipping an
already worn item, and removing a backpack item are correctly refused.

The greatmaul is initially reported as unidentified, with unknown detail fields
omitted. It is identified during ordinary approach/actions before the underfoot
inspection preceding pickup. This does not establish pickup as the specific
identification trigger. The raw stages are retained in each `natural-item.json`.

Natural enemies encountered during the search are handled with the character's
existing combat skills; each run records three native-log kills. No new level
or full campaign completion is required for this acceptance.

## Save, reload, and historical evidence

Both runs log native `Saving done.`, produce a changed, loadable, non-cheat
`game.teag`, and load a separate copy of that new save. Growth, category state,
owned items and equipment survive. Both end at full 178.225 life and 106 stamina.
Battle Companion remains `idle/actions=0`, including after reload. The reloaded
game has a new session ID and rejects the preceding session ID without changing
native state. The first newly saved test copy remains byte-identical after the
reload.

Persistence comparisons omit session-local object IDs. They allow only native
floating-point serialization roundoff (absolute 1e-9, relative 1e-12); point
counts, talent levels and item states remain exact. Raw before/after snapshots
are retained in `saved-state.json` and `reloaded-state.json`.

Both original historical save sets retain all six files unchanged. After both
final runs, all 13 files hashed by the first trial report and all 24 files hashed
by the continuation report still match. Supporting BC/DA/birth addons and the
engine are checked against recorded hashes before each runtime starts. Frozen
server and harness sources, input manifests and detailed evidence hashes are
included in the summary.

## Driver regressions and retained diagnostics

The source-provenance suite passes 11 tests; persistence comparison passes 5.
The old level 1 loader also passes its unchanged campaign driver's 10-check
read-only preflight. Level 3 baseline preflight passes 8 checks and candidate
progression/item read-only inspection passes 11 checks, all without actions.

Two earlier candidate failures are preserved:

- `growth-source-candidate-01`: the test driver reused a revision from before
  an intentional distant-pickup refusal. The bridge correctly returned
  `stale_revision`; the driver now observes again before moving.
- `growth-source-candidate-02`: all gameplay and native saving/reloading worked,
  but exact comparison rejected experience changing from
  `12.379999999999999` to `12.38` during native serialization. The comparison now
  uses the stated tolerance, with regressions proving real point, skill and
  item changes remain detectable.

`growth-source-candidate-03` subsequently passes 91 checks and 66 unique
actions. The two final runs above include additional point-result and session
checks and are the release evidence. Root-run native, interoperability and
production unit regressions are recorded separately; this report does not
double-count them.
