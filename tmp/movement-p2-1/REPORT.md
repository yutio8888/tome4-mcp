# [Dev] P2-1 alternative deterministic landing + P3-2 denied cooldown — ready for review

- Worktree: `/workspace/t-engine4/game/addons/tome-mcp-bridge-approach`
- Branch: `fix/approach-alternative-landing` (off `main@c4b40bc`), pushed, PR #19
- Production head (code + dist): `2c7a88e2b690c984cf660aab792c3277391485ad`; the docs-only dev-report commit sits on top of it (branch tip reported to the dispatcher).
- dist artifact: `dist/tome-mcp-bridge.teaa`
  - baseline sha `2f7c15e41740bd60674242b9703d34945bbf9ab7883015618790dc7edbf89a9e`
  - new sha `6d68fdfd559f89a34bb8e006a9e7be06cb2666d91e07937e036917e1b9088819`
  - 68 production files; manifest == archive == HEAD; 0 parity diffs
- `allow_auto_combat_execution` stays `false`; game core untouched.
- Source report: `tmp/mcp-play-support/agent-ham-s1rush2-report.md`
  sha256 `298c1cbf66bd4975cfde36213d3c24ce64ef2ff1395a43ac1881196900ecdd1c`.

## Per-finding

| finding | Result | Exact command(s) | Artifact path + sha256 |
| --- | --- | --- | --- |
| P2-1 (deterministic landing natively rejected → try next feasible adjacent step) | **PASS** | `tests/test_auto_combat_movement.lua`, `tests/test_auto_combat_service.lua`; native probe `movement-fallback` | `tmp/movement-p2-1/probe-src-05.log` `cf79cd3725a3fc672b73900f840e0b59a403693c6260a53bf48486207d9cf56c`; `tmp/movement-p2-1/probe-dist-03.log` `fdfb797a679567299f5d756106ea4312ba64f29a7a18162a5c16ae29cc3521cd` |
| P3-2 (structured cooldown on denied manual use_talent) | **PASS** | `tests/test_actions.lua`; native acceptance `native_cooldown_rejection_reports_structured_cooldown` | `tmp/movement-p2-1/accept-src-03.log` `a61369224b83dc1d4a18f3d7d6643af1ddbf0352bbc0aa78eac72a126f648f70`; `tmp/movement-p2-1/accept-dist-02.log` `12263066fe5be327acce6c5fb6cf58c4bb010495ea1808476740dcbcf40f1a64` |
| (c) invariants: one-opportunity budget, native_pending non-resubmission, manual lease revocation, dry-run non-execution, deterministic tie-breaks | **PASS** | `bash tests/run.sh` (41 suites) | `tmp/movement-p2-1/lua-suite.log` `9287d740b54804bc06a900eabd7d88c44748656e9ceb5bc3203e21bd48a13ad8` |

## Evidence table (raw)

| Command | Result | File + sha256 |
| --- | --- | --- |
| 41 Lua suites (`tests/run.sh` adapted to this worktree) | 41/41 green | `lua-suite.log` `9287d740…` |
| Python unittest | 39 OK | `python-tests.log` `c1fc4e9076becae677e9058290df37f5a050b5a3f40dbd577771c55836d56f73` |
| 3 generator `--check` (native seams / effect manifest / protocol) | 3/3 exit 0 | `generator-checks.log` `f1f5cf7e9e89c0ee781fa44fe63285fc9117dc7451329a589b6c4d04f964c6ac` |
| auto-combat native probe source (`p21-src-05`) | **123/123** | `probe-src-05.log` `cf79cd3725a3fc672b73900f840e0b59a403693c6260a53bf48486207d9cf56c` |
| auto-combat native probe dist (`p21-dist-03`) | **123/123** | `probe-dist-03.log` `fdfb797a679567299f5d756106ea4312ba64f29a7a18162a5c16ae29cc3521cd` |
| native acceptance source (`p21-accept-src-03`) | **101/101** | `accept-src-03.log` `a61369224b83dc1d4a18f3d7d6643af1ddbf0352bbc0aa78eac72a126f648f70` |
| native acceptance dist (`p21-accept-dist-02`) | **101/101** | `accept-dist-02.log` `12263066fe5be327acce6c5fb6cf58c4bb010495ea1808476740dcbcf40f1a64` |

Raw `result.json` copies: `p21-src-05-result.json`, `p21-dist-03-result.json`,
`p21-accept-src-03-result.json`, `p21-accept-dist-02-result.json`, `p21-prefix-02-result.json`.

## Before/after native reproduction

The probe scenario `movement-fallback` blocks the real straight `toward` landing
with a cloneable terrain tile and drives the production controller through the
production executor:

- **Before** (production code reverted to `c4b40bc`, new probe kept; addon copy at
  `/workspace/t-engine4/tmp/p21-prefix-addon`): FAIL —
  `movement-fallback:moves {"action":"stopped","reason":"no_available_action"}`,
  `movement-fallback:alternative` FAIL (second plan re-selects the blocked cell),
  `movement-fallback:retry-recorded` FAIL. Artifact `probe-prefix-02.log`
  `17ec7d406fc26562cc1679fd7bf42f3d8bf3dae4fb2bf8b1d601ecf8f17490bf`.
- **After**: PASS — `{"action":"acted","attempts":2,"before":"3,3","after":"4,3",
  "blocked":"4,2"}`, `movement_retry` recorded with native code `blocked`.

## Test matrix (required)

| Required test | Where |
| --- | --- |
| (a) best landing natively rejected → alternative used, character moves (postcondition asserted) | `test_auto_combat_movement.lua` §4a (host-level: `h.moved=='58,6'`); native probe `movement-fallback:moves` (real engine postcondition) |
| (b) all alternatives rejected/infeasible → `no_available_action` (honest stop) | `test_auto_combat_movement.lua` §4a (two blocks) |
| (c) one-opportunity budget | `test_auto_combat_controller.lua` §budget + §4a budget-bound block |
| (c) `native_pending` non-resubmission | `test_auto_combat_controller.lua`, `test_auto_combat_host.lua`, `test_runtime.lua` |
| (c) manual lease revocation | `test_auto_combat_controller.lua`, `test_auto_combat_service.lua` |
| (c) dry-run non-execution | `test_auto_combat_service.lua` (`executed=false`, `side_effects='none'`) |
| (c) deterministic tie-breaks (no RNG) | `test_auto_combat_movement.lua` §1 (RNG disabled) + exclude alternate |
| P3-2 structured cooldown | `test_actions.lua` (cooldown/off-cooldown), native acceptance check |
| non-deterministic landing unchanged (Rush/teleport) | `test_auto_combat_movement.lua` §4a non-deterministic block; native `movement-talents` still green |

## Invariants

One native action per opportunity; per-opportunity attempt/instant budgets;
`native_pending` never resubmitted; manual input revokes the lease; owner
arbitration; read-only `dry_run`; deterministic tie-breaks (no RNG);
native-final resolution; scene change pauses/resets + explicit restart — all
covered by the green suites and unchanged.

## Scope note

Fallback selection is **not** a strategy restriction: it does not forbid any
action; it excludes only a coordinate the engine itself just refused, then applies
the policy's own declared accept conditions. Restrictions remain preset defaults;
unknown outcomes are still annotated. Rush/teleport (`bounded`/`random`) have no
single-coordinate key and keep their existing behavior.

## Status

**ready for review** (not self-accepted/merged). Branch pushed, PR #19 open.
