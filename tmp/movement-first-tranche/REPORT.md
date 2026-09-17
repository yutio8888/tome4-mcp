# [Dev] movement-first-tranche rev 1 — ready for review

- Branch: `feat/movement-first-tranche` (pushed to origin)
- New head: `2e5dae2de2286c2f9a839b077c8390e03018caa5`
- PR: create at https://github.com/yutio8888/tome4-mcp/pull/new/feat/movement-first-tranche
- Baseline `main@a3b3a9a`; artifact `dist/tome-mcp-bridge.teaa`
  - baseline sha `7035d6026488df5e612d72ab4a745bcd2892af25fdfa5f0f2ee7e01282e4c09e`
  - new sha `d4a3affe48c6cee479f69d785533105e9c3470aae32d5b7b3e032670b233c916`
  - 67 production files; `allow_auto_combat_execution` still `false`.

## Per-ID

| ID | Result | Exact command(s) | Artifact path + sha256 |
| --- | --- | --- | --- |
| MOV-1 | PASS | `tests/test_auto_combat_policy.lua` (97), `test_auto_combat_catalog.lua` (60), `test_auto_combat_movement.lua` (34), `test_effect_manifest.lua` (348), `tools/generate_effect_manifest.py --check` | `tmp/movement-first-tranche/generator-checks.log` `2503208f26358c11c18060261b70491e476054b8e2281485592a8142d60e4ab4` |
| MOV-2 | PASS | `test_auto_combat_movement.lua`, `test_auto_combat_execution.lua` (12), `test_runtime.lua` (179), probe `movement:step-executes` | `tmp/movement-first-tranche/probe-source-result.json` `aa676ff33fca60460fdd96dc4403204431dc602bb60df14e41555990c93e45f9` |
| MOV-3 | PASS | `test_auto_combat_movement.lua`, `test_runtime.lua`, probe `movement:grid-annotation` / `movement:random-annotation` | same probe artifact |
| MOV-4 | PASS | `test_auto_combat_guard.lua` (45), `test_runtime.lua` | `tmp/movement-first-tranche/lua-suite.log` `94dd9a9ee690c2752ddc2669ff7c988005064320eaf5ac01eec5b7e1a4ed96fa` |
| MOV-5 | PASS | `test_auto_combat_policy.lua`, `test_auto_combat_catalog.lua` | lua-suite.log |
| MOV-6 | PASS | `bash tests/run.sh` (40 suites), Python 39, 3× `--check`, probes/acceptance source+dist | `tmp/movement-first-tranche/` (see table below) |

## Evidence table (raw)

| Command | Result | File + sha256 |
| --- | --- | --- |
| `bash tests/run.sh` | 40 suites green | `lua-suite.log` `94dd9a9ee690c2752ddc2669ff7c988005064320eaf5ac01eec5b7e1a4ed96fa` |
| Python unittest | 39 OK | `python-tests.log` `c0a6a40ed8d021f6d3f91c44c0bbb9539a4e47a0c2522f6d4a767bd94def83a9` |
| 3 generator `--check` | 3/3 exit 0 | `generator-checks.log` `2503208f26358c11c18060261b70491e476054b8e2281485592a8142d60e4ab4` |
| probe source | 94/94 | `probe-source-result.json` `aa676ff33fca60460fdd96dc4403204431dc602bb60df14e41555990c93e45f9` |
| probe dist | 94/94 | `probe-dist-result.json` `8f63519f41af74862adc00e49eaac0b362144f45a729670d07d7417f3beecc77` |
| native acceptance source | 100/100 | `acceptance-source-result.json` `63eb2f35b0321badd88ceafe3f8e01d3bc830571b155515c49270fe87f7bda3d` |
| native acceptance dist | 100/100 | `acceptance-dist-result.json` `59c4de6198bb781946fdb72e57e0fa3df67d04e0e8744cd210417d2d14c1c4a8` |

## Invariants

Budget / `native_pending` non-resubmission / manual-input lease revocation /
owner arbitration / read-only `dry_run` / deterministic tie-breaks (no RNG) /
native-final resolution / scene-change pause+reset+explicit-restart — all
covered by the green suites and unchanged.

## Capability / unsupported (with reasons)

- Multi-prompt `target_plan`: schema-valid; executor prefills one native prompt,
  a second becomes a native interaction and the run pauses/hands off.
- `known_safe` hazard: no canonical hazard manifest -> `unknown` => fails closed;
  policy may pick `avoid_known`/`any`.
- Phase Door TL4/TL5, Blink, Displacement Shield, Vault, Dimensional Step,
  Shadowstep, Giant Leap: adapters not yet source-reviewed (capability gap).
- Moving/swapping another actor: typed multi-actor semantics not implemented.

## Deferred / notes

- Real teleport native execution not probed: the probe character is a Berserker
  without a teleport talent; the random-landing annotation is asserted through
  the production `plan` path.
- Real `change_level` native automation is covered by the controller
  production-path test + the existing bridge `change_level` native path; the
  auto-combat probe asserts the executed plain step.
- Next stage: fresh reviewer, then dispatcher.
