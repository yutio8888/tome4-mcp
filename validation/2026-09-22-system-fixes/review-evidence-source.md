# SYSFIX evidence independent review (updated exact recheck)

Status: `incomplete` / recommendation `incomplete`, solely because the coordinator has not yet delivered the final SYS-07 index, replacement package, and indexed native evidence. Role: fresh `[Review]`, read-only product review. No new finding was identified in the exact EVIDENCE-REV-01/02 recheck.

Original candidate source was detached `d42d071dde6d9f5b993bb13d4e5e5a10d440727a` against baseline `caefa9a94af85dabd73c0d7e74ef764081b1fb3e`. Its archive `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/artifacts/candidate-1831b912.teaa` had independently observed SHA-256 `1831b912ddc94f5d43a22bb3032391d135a862440f9ea38dda8e972974600fcc`. That archive is historical only and contains neither the reviewed evidence-gate fixes nor the ongoing runtime fixes. The amended recheck source was the clean detached tree `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/workspaces/recheck-evidence-02/game/addons/tome-mcp-bridge` at `638d1533fdeddba301d81fb59136d9afb569ff13`; no replacement package claim was made or reviewed.

## Finding disposition

### EVIDENCE-REV-01 · formerly P1 · `CLOSED` / `PASS` at source-tooling layer

Original issue: the checker at candidate `d42d071...` accepted dead or unrelated branches containing density-validation and footprint-copy tokens, so it could emit A/B PASS even when live validation/forwarding was disabled.

Exact repair ancestry was verified as `06f393fd603483720c8506c4f3d12bf17f443359`, integrated into recheck HEAD `638d153...`. The amended checker constrains registered density/copy evidence to the intended function/control scope and requires a closed terminal copy path. Independent results:

- The original combined dead-branch scratch now returns `1` with `FAIL A.density`, `FAIL A.density-keys`, `FAIL B.copy`, `FAIL B.copy-fields`, and `FAIL B.copy-terminal`.
- The unmodified source returns `0`, labels only A/B as structural PASS, and leaves C/D/E as `REVIEW`.
- `tests/test_boundary_rules.py -v` returns `0` with 22 cases, including live real-CLI negatives for dead/unrelated density and copy scopes.

This closes the exact false-positive trigger. The checker is deliberately bounded and is not claimed to prove arbitrary Lua semantics.

### EVIDENCE-REV-02 · formerly P1 · `CLOSED` / `PASS` at source-tooling layer

Original issue: at candidate `d42d071...`, appending `spec.no_restrict=nil` after the registered forwarding loop still passed the checker, all boundary tests, and the then-current Guard suite even though a mandatory engine-read field was erased.

Exact repair ancestry was verified as `ca4e24ac338e6730385097221209902b678d77ef`, integrated into recheck HEAD `638d153...`, together with the terminal-copy checker repair. Independent results:

- The original `spec.no_restrict=nil` scratch now returns `1` with `FAIL B.copy-terminal`.
- The boundary suite covers all 15 post-copy field erasures plus bracket/rawset/rebinding and in-loop clobber forms.
- The production-path oracle calls the real `Guard.copyFootprintFlags` and `Guard.footprintSpec`, independently declares all 15 mandatory fields, verifies explicit `false`, scalars, tables and callback identity, and invokes all three callbacks.
- An independent harness erased each mandatory field after the live copy loop and ran the real Guard test: all `15/15` mutants returned `1`, and every failure named the erased field.

This closes the exact later-clobber trigger at source/tooling level. It does not claim native execution or package parity.

## Requirement verdicts

- SYS-05: `PASS` at the pinned offline source/tooling layer on `638d153...`. The unmodified A/B checker passes; original REV-01/02 counterexamples fail; 22 boundary tests, the 426-check Guard suite, and all 15 independent field-erasure mutations support the result. C/D/E remain explicitly `REVIEW`, not structural PASS.
- SYS-06: `PASS` at source/real-CLI layer. All 17 manifest tests pass, including the original dangling-reference counterexample, missing/wrong hashes/files across evidence/raw/artifacts, malformed and duplicate JSON, duplicate paths/ids/gates/references, invalid status/ref types, path escape/scope, legacy formats, and explicit absolute archive verification.
- Unified entry: `PASS` at offline source/integration layer. The brief-specified `tests/run.sh` invocation returned `0`; it ran the A/B checker, 22 boundary tests, 17 manifest tests, Lua suites including Guard 426 and system-fixes 620, 45 Python tests, and all three generators. This is not native/game evidence.
- SYS-07: `NOT_OBSERVED` / pending final index. The old `1831...` archive remains historical only. The final evidence must preserve, index, and correctly disposition all three disclosed native failures: `policy-source01` (sandbox getter startup, zero checks), `policy-source02` (8 PASS / 1 FAIL, real pending-final-status loss), and `core-source01` (113 checks / overall FAIL, volatile-UID oracle). No failed or superseded row may be promoted to PASS without applicable replacement evidence.

## Recheck evidence

- Controlling amendment: `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/review-evidence-recheck-02-brief.md`, SHA-256 `5a89f8c3f65497c126a19ae248a675e858c25b9211264d371d61f3fc29fce7af`.
- Detailed independent results: `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/review-evidence/recheck02-results.md`, SHA-256 `1d7d08f21f398deb4c569fedf3f81c78f6396b7a86c8c0b5e1190250a2b69502`.
- Raw 15-field mutation results: `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/review-evidence/recheck02-guard-mutation-results.json`, SHA-256 `6365e8de6fcec34ac5521ce3ab83d5f05d1c5e2f5ea9631d1b53af02e3b1acba`.
- Review-only mutation harness: `/workspace/t-engine4/tmp/mcp-system-fixes-20260922/review-evidence/recheck02_guard_mutations.py`, SHA-256 `9dac3223056350e0eae1e521651fd227fbd6544418b4781eed66901bd4acf8a4`.
- Fixed-file hashes: checker `683de8b622f75da7e3eee7900ca3a858f5bac09b07f6a8bd0530a4fd9790d5f4`; boundary tests `72ad53208dd1686be9fcf25a81c14c8a9419e0aa379b4da9aed5d5fafd7b8be8`; Guard test `9cbfe4d32854724e710fbcf7d856784bc3566931c9710d52afbfe9e0502bb800`.

## Pending / next owner

Coordinator `f7a2979c-7b83-4a32-855f-d698ef2daf0a` owns the replacement build and final SYS-07 evidence/index delivery. This reviewer must then verify source/package applicability, hashes, raw native results/logs, failure preservation and supersession semantics before any final complete recommendation. Runtime/protocol scope remains with the separately assigned reviewer.
