# S2 rev6 — S2-FIX5: pre-prompt native refusal must not fabricate `unexpected_target_request`

Branch `fix/s2-false-deviation` off `main@e51fe8a` (dedicated worktree
`game/addons/tome-mcp-bridge-s2fix5`). Dev model **B** (rotation; the Dev sequence
last used A). Report of the live defect:
`tmp/mcp-play-support/agent-ham-s2arch-01-report.md`
(sha256 `4a25b2bcfde5b6a7152e070c9894b88853774c6db8e8147d743d6b50fcd6d67d`, §8):
10 legal-policy pauses with `reason=unexpected_target_request`, **no `detail`
field**, one per entry-refused submission (`Phase Door is still on cooldown for
11 turns.` in the game log, no second cast, no second target request).

## Root cause (verified in code, two independent symptoms)

**Symptom 1 — the fabricated deviation.** `Actions.lua`'s settle check compared
the number of answered prompts (`observed`) against `#queue` without checking
whether the invocation ever entered the targeting flow. A native entry that
refuses before any prompt (cooldown / no energy / `on_pre_use` `return false`
— `ActorTalents.lua:169-172`, before the coroutine and before any `getTarget`)
leaves `observed==0` while `#queue==2`, so the check reported "the first declared
prompt was missing" and fabricated `unexpected_target_request` +
`target_cancelled`, which the controller turned into a pause. Zero observed
prompts means the native flow never started: there is no prompt to compare
against, and the correct outcome is the ordinary native rejection.

**Symptom 2 — the `detail`-less pause event.** The dispatcher's hypothesis
(a record lacking `expected`/`observed`) was close but not exact: the settle
record already carried `expected`/`observed`/`skippable`. What the policy log
actually saw was the controller's **bare `M:pause(reason)` notify** — the sync
deviation branch only `self:record`-ed its detailed event into the in-memory
decision ring, and `record` never notifies, so the only event that reached
`PolicyLog` was `pause`'s `{kind='paused',reason=...}` with **no `rule` and no
`detail`** (matching the raw `alllog.json` events exactly: no `rule`, no
`detail`). Path 2 (`nativeDeviated`) was never affected.

## Fix

1. **`overload/mod/mcp_bridge/Actions.lua`** — the queue wrapper now tracks
   `raised` (set when the flow actually raised a prompt through `getTarget`).
   The settle-time missing-entry rule applies **only after `raised`**. A
   pre-prompt refusal settles with zero observed prompts: no
   `sequence_deviation`, no `target_cancelled`, no handback — the ordinary
   `native_rejected` outcome with its own structured cooldown `missing`/`hint`
   (or the no-energy classification) flows through unchanged. A genuine
   mid-sequence abort (first prompt answered, second never raised) still
   deviates, and the trailing-`optional` `reduced=true` rule keeps its meaning.
2. **Deviation shape gate**: new `Actions.validateDeviation(record)` requires,
   per typed reason, the identifying fields (`unexpected_target_request`:
   `expected`/`observed`/`skippable`; `movement_request_kind_unknown`:
   `expected`/`observed`/`skippable`/`handed_back`;
   `movement_request_value_unknown`: `expected`/`observed`/`index`/`request`/
   `dependency`). Every emission site (`deviate`, `valueUnknown`,
   `requestKindUnknown`, the settle check) asserts the shape before the record
   can be stored, so a malformed record can never be emitted. `valueUnknown`
   now also carries `expected`/`observed`/`skippable` (its `index`/`request`/
   `dependency` are kept).
3. **`overload/mod/auto_combat/AutoCombat.lua`** — the synchronous deviation
   pause now notifies the typed event itself (`kind='paused'`, `rule`,
   `detail=boundedDetail(...)`), then moves to paused so `pause` deduplicates:
   **exactly one** log event per deviation, carrying rule + detail. The old
   bare, detail-less notify is gone for every deviation path.

Kept unchanged (live-passed): two-prompt ordering, distinct answers, per-request
guards, live handback + lease release on a genuine deviation, `native_timeout`
bound, random landings never refused, the exactly-one/signature contract, and
**no** plugin-level strategy gate (the `cooldown_ready` guard stays the policy
author's choice).

## Tests

| Layer | Coverage |
| --- | --- |
| executor | `tests/test_auto_combat_sequence.lua` §15 (shape gate: complete records validate, 11 malformed records rejected with typed reasons) and §16 (cooldown-refused two-entry program → `native_rejected` + cooldown `missing`/`hint`, `sequence_deviation==nil`, `target_cancelled==nil`, empty `target_sequence`, `native_return==false`; genuine mid-sequence abort still deviates with its identifying fields; trailing-optional non-raise still reports `reduced=true`). The `runQueue` harness now shape-checks **every** deviation it surfaces. |
| controller | `tests/test_auto_combat_controller.lua`: a synchronous deviation pause logs **exactly one** event with `rule` and bounded identifying `detail` + handback evidence; an ordinary native rejection (cooldown `missing`, no deviation) never fabricates a paused/unexpected_target_request event, records `native_rejected`, and falls through. |
| native probe | `tests/native/tome-auto-combat-probe/overload/mod/AutoCombatProbe.lua`, `movement-sequence` (i): a REAL cooldown (`p.talents_cd=11`) refused by the production `useTalent` before any prompt, driven through the auto slot — executor layer: `status='rejected'`, `code='native_rejected'`, cooldown `missing` remaining=11, `sequence_deviation==nil`, empty `target_sequence`; controller layer (real controller + production executor, `phase` overridden per the sync-scenario convention): no `paused/unexpected_target_request` event, the ordinary `native_rejected` denial, run ends `stopped/no_available_action`. Signals `sd_cooldown_native_rejected` + `sd_cooldown_no_pause` (`movement-sequence` now 175 checks). |

Full existing suite kept green (42 Lua suites, Python 39, three generator
`--check` runs, native acceptance source AND dist, package parity 68/68).

## Acceptance evidence (all commands run in the worktree)

| Check | Result | Command / evidence |
| --- | --- | --- |
| Lua suite 42/42 | PASS | `TOME_MCP_ADDON_DIR=<worktree> bash tests/run.sh` → exit 0; `tmp/mcp-play-support/s2fix5/lua-suite.log` sha256 `c66b38393950139add9dc2a0f8c2f13608ea6018a925f2d97411194b371d68c4` |
| Python 39 | PASS | `PYTHONPATH=<worktree>/server/src tmp/tome-mcp-venv/bin/python -m unittest discover -s <worktree>/server/tests` → `Ran 39 tests ... OK`; `tmp/mcp-play-support/s2fix5/python-tests.log` sha256 `e16340e7b1973da60f4cd3072b5281e33d2cbbd57e7bb84f1bdb0407dac69c8d` |
| three `--check` | PASS | `tools/generate_native_seams.py --check`, `tools/generate_effect_manifest.py --check`, `tools/generate_protocol.py --check` → all exit 0; `tmp/mcp-play-support/s2fix5/generator-checks.log` sha256 `735ae0a6c97a3d67b74c67d09f67ed2b7be5c6b6fa383994dcaf864adb2ee303` |
| package parity | 68/68 | `python3 tools/package.py` → 68 files, dist `tome-mcp-bridge.teaa` sha256 `71da54ccb8f72872adf622a8c593165507dd3f9bd9c9b722a9d7e577d82e6281` |
| auto-combat probe source | 175/175 PASS | `python3 tests/native/auto_combat_run.py s2fix5-probe-src-02` → passed; session `tmp/tome-mcp-validation/sessions/s2fix5-probe-src-02` (game.log sha256 `83342249bbdd43f9e3fe50638876f1db2d2a01b0adbac303d21f7358b28e0e63`) |
| auto-combat probe dist | 175/175 PASS | same + `--addon-archive <worktree>/dist/tome-mcp-bridge.teaa` → `s2fix5-probe-dist-01` (game.log sha256 `9c1439babb20c3abff907b9598350d545d5c9b67ba367f7fa7ed27882591f863`) |
| native acceptance source | 101/101 PASS | `python3 tests/native/run.py s2fix5-accept-src-01` → passed; game.log sha256 `bc07906f731b554056179f5312b0d660a0cb9592d1df0133a1b331a4cad37aa9` |
| native acceptance dist | 101/101 PASS | `python3 tests/native/run.py s2fix5-accept-dist-01 --addon-archive <worktree>/dist/tome-mcp-bridge.teaa` → passed; game.log sha256 `0a3e45ed19aa7f1dfb52f74b773d8275b20a9ea25cfe1b2bb34bf00bbc69e9b2` |
| sessions reaped | PASS | `reap-session.sh --all` then `--list` → empty |

Probe s2fix5-probe-src-01 (failed on the controller `phase` gate, then fixed by
the sync-scenario `phase` override) was reaped; its evidence remains under
`tmp/tome-mcp-validation/sessions/s2fix5-probe-src-01`. No flake reruns were
needed for `fragmented_tcp_connect_returns_ready` or
`movement-talents:tumble-execute` this loop.

Runtime invariants unchanged: no protocol field added, no game-core change, no
generated file hand-edited (`package.py` re-verified the seams), runtime state
never enters the savefile, `allow_auto_combat_execution` stays `false`.
