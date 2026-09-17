# [Dev] movement-first-tranche rev 4 — ready for review

- Branch: `feat/movement-first-tranche` (PR #15), pushed.
- New head: `3953788d3d5002e4e4c8d7536f7e79fd614c3a6e` (rev 3 was `25421dc`).
- Artifact `dist/tome-mcp-bridge.teaa`: rev3 `36d5868724c81ffce84553723c271b44257469f940ff6f7118b880ed6e22f4b4`
  → rev4 `688ae61f89fc0452c91b19555f7d4467d319e3883674750054927e01e1445c77` (67 files).
- `allow_auto_combat_execution` stays `false`.

## MFT-REV-03 (the last open finding) — PASS, Option A

When `then.target` and `targeting.default` are both absent, the first actor
`target_plan[].selector` is now a real binding:

- `PolicyEvaluator` derives the action target from it and evaluates the rule
  condition against that actor step selector.
- `AutoCombat:rebind` treats the snapshot selector (or the policy default when
  the snapshot omitted it) as the current binding, so a nil default snapshot
  selector no longer blocks the declared binding; it re-binds and re-checks.
- `MovementPlanner`'s actor branch chooses the anchor from the step selector
  (`self` → origin; otherwise the bound target) and still returns
  `target_plan_selector_mismatch` for a contradiction with an explicit action
  selector.
- `EffectManifest.verify` uses the derived selector for the self/hostile check, so
  an omitted `self` step on a hostile talent is rejected.
- `AutoCombatService.dryRun` mirrors the rebind semantics.

### Regressions (non-tautological, omitted-action-selector case)

| Layer | Test |
| --- | --- |
| schema/catalog | `test_auto_combat_catalog.lua`: omitted hostile step accepted; omitted self step on a hostile talent rejected (`selector_not_hostile`) |
| pure planner | `test_auto_combat_movement.lua`: omitted `self` step anchors the self origin (not the pre-bound enemy); omitted hostile step uses the bound target |
| production controller | `test_auto_combat_movement.lua`: `rebind` binds the declared actor step and the planner receives `target`/`bound_target` accordingly (self → no enemy binding) |
| dry-run | `test_auto_combat_service.lua`: dry-run binds the declared actor step selector with no action selector |

## Raw evidence (`tmp/movement-first-tranche/rev4/`)

| Command | Result | File + sha256 |
| --- | --- | --- |
| `bash tests/run.sh` | 40 suites green | `lua-suite.log` `30482fb6e52bb4c129e7ed8f6128c482f57db71d74fa1013faf7369bde5ded54` |
| Python unittest | 39 OK | `python-tests.log` `1eca7c668f68bd62c118620f38320033f711f35e243da2a9248cb6f022c42f75` |
| 3 generator `--check` | 3/3 exit 0 | `generator-checks.log` `2503208f26358c11c18060261b70491e476054b8e2281485592a8142d60e4ab4` |
| probe source `rev4-final-src` | 105/105 | `probe-source-result.json` `eb243fece8578bd23c3e9da958211dbae66bc1affba230a25d52e43b9a5f5cad` |
| probe dist `rev4-final-dist` | 105/105 | `probe-dist-result.json` `c33c499c33944805617692c93d9bd699a28fa7fb50b2fc9c90612811537f041e` |
| acceptance source `rev4-accept-src` | 100/100 | `acceptance-source-result.json` `1e607a4127a41910399f42898a0247024852f39171c46cbe327a5414a5801d63` |
| acceptance dist `rev4-accept-dist` | 100/100 | `acceptance-dist-result.json` `ec06a31c4bb3c954eafa257c473ac58dbe6edc54328e42dce4cc3f63528790d7` |

## Invariants

One action per opportunity; attempt/instant budgets; `native_pending` never
resubmitted; manual input revokes; owner arbitration; read-only `dry_run`;
deterministic tie-breaks (no RNG); native resolution final; scene change
pause/reset with explicit restart — all green. Every rev-3 PASS (MFT-REV-03
contradiction, 05, 07, 08, 09, NEW-01) and every rev-2 PASS (01, 02, 04, 06,
R-1…R-6) re-ran green.

Next stage: reviewer `4ba89dc2` final re-check, then dispatcher.
