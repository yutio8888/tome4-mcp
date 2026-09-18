# [Dev] movement-first-tranche rev 2 — ready for review

- Branch: `feat/movement-first-tranche` (PR #15), pushed.
- New head: `b705489b903797fc80e9319616a657083fc1a561` (rev 1 was `2e5dae2`).
- Artifact `dist/tome-mcp-bridge.teaa`: rev1 `d4a3affe48c6cee479f69d785533105e9c3470aae32d5b7b3e032670b233c916`
  → rev2 `317213c3282547e1b93fbcf9328abadb07c950e6381a72001588add8b9b1a60a` (67 files).
- `allow_auto_combat_execution` stays `false`.

## Per-finding (all PASS)

| ID | Fix | Regression evidence |
| --- | --- | --- |
| MFT-REV-01 | explicit `policy.mode` (`on_no_enemy` stop\|evaluate_rules, `on_low_hp` pause\|emergency_only\|evaluate_rules`); strict presets data-expand the old behaviour; `emergency` is a scheduling label only; evaluate_rules executes declared actions at low HP; no global flee gate | `test_auto_combat_policy.lua` (mode/emergency move+rest), `test_auto_combat_movement.lua` (low-HP kite), `test_auto_combat_controller.lua` |
| MFT-REV-02 | `EffectRisk.measure` numeric aggregation; guard compares with `max_selffire_risk`, permits within tolerance and reports measurement/threshold/provenance; above/incalculable rejects | `test_effect_risk.lua`, `test_auto_combat_guard.lua`, `test_runtime.lua`, `test_auto_combat_service.lua` |
| MFT-REV-03 | per-request target_plan validation; `EffectManifest.verify` compares order with the adapter; planner consumes the first request; multi-prompt pauses `unsupported_target_plan` | `test_auto_combat_policy.lua`, `test_auto_combat_movement.lua`, `test_effect_manifest.lua` |
| MFT-REV-04 | deterministic rejects bounded+random; hazard polarity true=known/false=safe/unknown | `test_auto_combat_movement.lua`, `test_runtime.lua` |
| MFT-REV-05 | dry-run runs the same bounded deny/fall-through loop as live | `test_auto_combat_service.lua` |
| MFT-REV-06 | `level_changed` preserved independently of status; any scene transition stops/resets and refuses resume | `test_auto_combat_execution.lua`, `test_auto_combat_movement.lua` |
| MFT-REV-07 | movement annotation + guard detail reach `PolicyLog`/replay (bounded) | `test_auto_combat_movement.lua` |
| MFT-REV-08 | structured `EffectManifest.UNSUPPORTED` + Phase Door `unsupported_variants`; runtime typed reject; capabilities publish | `test_effect_manifest.lua`, `test_auto_combat_movement.lua` |
| MFT-REV-09 | native probes execute Rush / Tumble / Phase Door and a real native change_level stair fixture (two-level `mcp-test` arena) | `probe-source-result.json` / `probe-dist-result.json` |

R-1…R-6 "found correct" items re-ran green (full Lua/Python + both native suites).

## Raw evidence (`tmp/movement-first-tranche/rev2/`)

| Command | Result | File + sha256 |
| --- | --- | --- |
| `bash tests/run.sh` | 40 suites green | `lua-suite.log` `f0b2a15be907e0695961b324a3570a0e229f48945e2a4499775090dacd0f43bb` |
| Python unittest | 39 OK | `python-tests.log` `3d84718e933f1e7c0dde65fc1882c911e65d7d27e3f7aa041031699156e4717e` |
| 3 generator `--check` | 3/3 exit 0 | `generator-checks.log` `2503208f26358c11c18060261b70491e476054b8e2281485592a8142d60e4ab4` |
| probe source `rev2-src-11` | 105/105 | `probe-source-result.json` `73ea4364492cf3c2885e71ae42245d4c9b3557237d0e0a7b1f7ebdc625d0f620` |
| probe dist `rev2-dist-01` | 105/105 | `probe-dist-result.json` `907b4961036810c157e4349f45f47c75415d8aa1245a6c0a78281482f5f47c0e` |
| acceptance source `rev2-accept-src` | 100/100 | `acceptance-source-result.json` `378635c2897c85d77463cc4c25b567022c01a84ff1e66191ed787f7f28fb1079` |
| acceptance dist `rev2-accept-dist` | 100/100 | `acceptance-dist-result.json` `ab94474352988416fd728c308792e49e597fb6abb666513b4b38055ac1f54d2c` |

## Invariants

One action per opportunity; attempt/instant budgets; `native_pending` never
resubmitted; manual input revokes; owner arbitration; read-only `dry_run`;
deterministic tie-breaks (no RNG); native resolution final; scene change
pause/reset with explicit restart — all green.

Next stage: reviewer `4ba89dc2` re-check, then dispatcher.
