# S2 rev7 — S2-FIX5-R1: the zero-prompt exemption must not excuse a success

Branch `fix/s2-zeroprompt-success` off `d44ce697` (= the reviewed S2-FIX5 head) in
the dedicated worktree `game/addons/tome-mcp-bridge-s2fix6`. Dev model **A**
(rotation; the Dev sequence last used B). Reviewed input:
`tmp/mcp-play-support/review-s2-fix5.md` sha256
`415faac48ae61956700aad11d5fef8f11f59da8a625c819c1dae7dd23babf632`
(verdict DO_NOT_MERGE, exactly one P1: S2-FIX5-R1). merge=no.

## Finding (P1) and fix

**S2-FIX5-R1.** The S2-FIX5 settle gate was `raised` alone (`Actions.lua:795-796`),
so **every** zero-prompt return was exempt from the missing-entry rule. `raised`
distinguishes "a prompt happened" from "no prompt happened", but not a legitimate
pre-prompt **refusal** from a successful native return. A descriptor declaring
non-optional entries could return `true` without raising any prompt and be
reported as `action_complete` with an empty `target_sequence`, no deviation and
no pause — the policy-decided actor/grid values were never consumed yet the
controller logged success and continued.

**Fix** (`overload/mod/mcp_bridge/Actions.lua`, settle block): the exemption is
narrowed to a pre-prompt native **FAILURE**.

```lua
local preflightRefusal=not raised and not value
if queue and command and not command.sequence_deviation
    and not yielded and not preflightRefusal then
```

- zero-prompt **failure** (cooldown / no energy / `on_pre_use` `return false` /
  plain falsy body return) ⇒ `preflightRefusal=true` ⇒ ordinary
  `native_rejected` (with its own cooldown `missing`/`hint` or the no-energy
  classification), no `sequence_deviation`, no `target_cancelled` — the S2-FIX5
  behaviour kept;
- zero-prompt **truthy** return on a declared non-optional sequence ⇒ the
  missing-entry rule fires ⇒ typed `unexpected_target_request` at the first
  missing entry (`expected={index,request}`, `observed={index,request=nil}`,
  `skippable=false`), `target_cancelled='unexpected_target_request'`, the result
  is `ok=false`/`uncertain=true` and the controller pauses instead of continuing;
- one-or-more prompts raised then a mid-sequence abort (including a falsy return)
  ⇒ typed deviation at the missing index (unchanged; `raised` no longer needed to
  reach it);
- trailing `optional` not raised ⇒ `reduced=true` (unchanged), including the
  case where it is the **only** missing entry and the native return is truthy;
- every deviation still passes `assertDeviation` (unchanged).

**Default is fail-closed.** No reviewed talent can legitimately return a truthy
zero-prompt result against a curated `request_then_landing` program, so no
`zero_prompt_success` allowance was added to any descriptor. The only curated
`request_sequence` consumers in ToME 1.7.6 are the three Phase Door cells
(`EffectManifest.lua:349,361,374`), all of which raise their declared prompts
unconditionally on the branch the resolver already read: the actor prompt is
gated on `getTalentLevel(t) >= 4` (`spells/conveyance.lua:82`, matched by the
`talent_level` variant axis) and the landing prompt on
`getTalentLevel(t) >= 5 or attr('phase_door_force_precise')`
(`conveyance.lua:108`, matched by the `at_least=5` / `attr` axes). Neither gate
is state-dependent on a live read that the resolver could have missed, so a
zero-prompt truthy return would mean the native body was replaced/drifted — a
case that must deviate, not silently complete.

## Tests (committed)

`tests/test_auto_combat_sequence.lua` (ordered sequence 169 checks, +15):

| Case | Assertion |
| --- | --- |
| §16c zero prompts + truthy return, non-optional 2-entry | NOT `action_complete`; typed `unexpected_target_request` at index 1 with `expected`/`observed`/`skippable==false`; empty `target_sequence`; `target_cancelled` set |
| §16d zero prompts + falsy return (plain body) | ordinary `native_rejected`, no deviation, no `target_cancelled` |
| §16e one prompt then falsy return | typed deviation at the missing index 2 (stays green) |
| §16b trailing `optional` not raised | `reduced=true`, no deviation (stays green) |
| §16f mixed 3-entry, only the trailing `optional` missing, truthy return | `action_complete` + `reduced=true` + `reduced_reason` + no deviation |

Existing regressions kept green: S2-FIX5 cooldown refusal (§16), mid-sequence
abort, deviation shape gate (§15, 11 malformed records rejected).

`tests/native/tome-auto-combat-probe/overload/mod/AutoCombatProbe.lua`,
`movement-sequence` (j) — a REAL native entry whose `action` returns `true`
without ever calling `getTarget`, driven through the production `useTalent` and
the auto slot: executor layer `status='uncertain'`,
`code='unexpected_target_request'`, deviation `expected.index==1` /
`observed.request==nil` / `skippable==false`, empty `target_sequence`; controller
layer (real controller + production executor, `phase` overridden per the
sync-scenario convention) pauses with the typed reason and its bounded detail and
consumes no action budget. New signals
`sd_zero_prompt_success_deviated` + `sd_zero_prompt_success_paused`
(`movement-sequence` now 177 checks).

## Acceptance evidence (all commands run in the worktree)

| Check | Result | Command / evidence |
| --- | --- | --- |
| Lua suite 42/42 | PASS | `TOME_MCP_ADDON_DIR=<wt> bash tests/run.sh` → exit 0, 42 suites; `tmp/mcp-play-support/s2fix6/lua-suite.log` sha256 `1b6db7922406c78aa42634ce9ad62232105cc076b9a68f5ad65cf3b7f1b536dc` |
| Python 39 | PASS | `PYTHONPATH=<wt>/server/src tmp/tome-mcp-venv/bin/python -m unittest discover -s <wt>/server/tests` → `Ran 39 tests ... OK`; `tmp/mcp-play-support/s2fix6/python-tests.log` sha256 `ad3d28423c0b164ec69325b1498dd1ff77cf692607290101adb2c95ee6f6d479` |
| three `--check` | PASS | `tools/generate_native_seams.py --check`, `tools/generate_effect_manifest.py --check`, `tools/generate_protocol.py --check` → all exit 0; `tmp/mcp-play-support/s2fix6/generator-checks.log` sha256 `e1d5e9521ee532cfe6509322435578424e093e09c0e3c98c42d70c6edde878d1` |
| package parity | 68/68 | `python3 tools/package.py` → 68 files; dist `tome-mcp-bridge.teaa` sha256 `453b3f56c2e40054e0f75d2ffb13f72e5f58da6b9601a12d3c55b7688d5f1ebe`; independently re-hashed 68/68 archive entries against the source tree, 0 divergent |
| auto-combat probe source | 177/177 PASS | `TOME_MCP_ADDON_DIR=<wt> python3 tests/native/auto_combat_run.py s2fix6-probe-src-01`; session `tmp/tome-mcp-validation/sessions/s2fix6-probe-src-01` (result.json sha256 `c08a1e2ee611f699c3cfdf4cec30c1a2835a5ff7204dbaa158d62ea6675c0201`, game.log sha256 `4d767acaf03d05bc8b0c982e7168be465ffa780a49589b3ed47995894183483e`); log `tmp/mcp-play-support/s2fix6/probe-source.log` sha256 `dcaae721e4c60135e39a56991b1102937c739b0a9dd31361cc8ac12e686b8441` |
| auto-combat probe dist | 177/177 PASS | same + `--addon-archive <wt>/dist/tome-mcp-bridge.teaa` → `s2fix6-probe-dist-01` (result sha256 `5b4dc86e5e45fb890dd73da6e9732a15be57ab14f0c29d4ad5ed88dacc8d4821`, game.log sha256 `7e9ad17746342ab214383336cea9dda9eaf72b3d547478158720f1bd35e5ab44`); log sha256 `179a9a4a3985f9a8b33e979502e6296c8ff1c535b147b77660bc022797ccb45f` |
| native acceptance source | 101/101 PASS | `TOME_MCP_ADDON_DIR=<wt> python3 tests/native/run.py s2fix6-accept-src-01` → passed; session `s2fix6-accept-src-01` (result sha256 `11cd32978ec76ba2b540d79f9f89a9085c738e6578d104d8132083c883bb94a0`, game.log sha256 `a3c3d16faf3db8d911ecd744abc0a2c7c93a27ec8b33c05737246908fab65df8`); log sha256 `03109635d2c935ce157cd41d22eb24678fd2924767b76fbf389c8b9f23b37b52` |
| native acceptance dist | 101/101 PASS | same + absolute `--addon-archive` → `s2fix6-accept-dist-01` (result sha256 `2fef2d1f23dcf1d871d5a8d2789d7a69e5211b4b79d7b3466dc41199bbc60743`, game.log sha256 `34489afbcaa9fb87957d736f988096b06303f058d96188d40ec24bb5b1c6f663`); log sha256 `8ffb627b0010dc25e9aef5845ca7fb7d70d86c43df351d766465c58c586a3ae6` |
| sessions reaped | PASS | `reap-session.sh --all` then `--list` → empty before reporting |

No flake reruns were needed: `fragmented_tcp_connect_returns_ready` and
`movement-talents:tumble-execute` both passed on the first run in both source and
dist sessions.

Runtime invariants unchanged: no protocol field added, no game-core change, no
generated file hand-edited (`package.py` re-verified all seams), runtime state
never enters the savefile, `allow_auto_combat_execution` stays `false`, no
plugin-level strategy gate.
