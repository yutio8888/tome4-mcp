# [Dev] movement-first-tranche rev 3 — ready for review

- Branch: `feat/movement-first-tranche` (PR #15), pushed.
- New head: `25421dcc2bd072d88ab5cc89871b387d29b7eec7` (rev 2 was `b705489`).
- Artifact `dist/tome-mcp-bridge.teaa`: rev2 `317213c3282547e1b93fbcf9328abadb07c950e6381a72001588add8b9b1a60a`
  → rev3 `36d5868724c81ffce84553723c271b44257469f940ff6f7118b880ed6e22f4b4` (67 files).
- `allow_auto_combat_execution` stays `false`.

## Per-finding (all PASS)

| ID | Fix | Regression evidence |
| --- | --- | --- |
| MFT-REV-03 | `EffectManifest.verify` rejects an actor `target_plan[].selector` contradicting the action binding (`target_plan_selector_mismatch`); planner returns the same typed reason defensively | `test_auto_combat_catalog.lua`, `test_auto_combat_movement.lua` |
| MFT-REV-05 | dry-run uses a distinct `instant_attempts` (guard-rejected candidates do not charge an instant slot) and pauses on `unsupported_target_plan` like live | `test_auto_combat_service.lua` (instant parity + multi-prompt pause) |
| MFT-REV-07 | `PolicyLog.add` stores the movement annotation + risk detail via a depth/key-bounded projection; `tome.policy_log`/`replay` reconstruct them | `test_auto_combat_catalog.lua`, `test_auto_combat_service.lua` (controller → log/replay) |
| MFT-REV-08 | unknown/unavailable effective level fails closed for a level-scoped variant (`unsupported_movement_variant`, `unknown=true`); Displacement Shield structured entry added | `test_auto_combat_movement.lua`, `test_effect_manifest.lua` |
| MFT-REV-09 | probe settles each native movement task and asserts the final postcondition (Rush reaches target, Tumble lands on the requested cell, Phase Door moves; real stair scene lifecycle). Actor/grid single-target lowering uses the engine `force_target` path (`Actions` `force_actor`/`force_grid`) so every native target request is answered | `test_actions.lua`, `probe-source-result.json` / `probe-dist-result.json` |
| MFT-NEW-01 | Q4 prose corrected in the tranche doc and the `AutoCombatGuard` header (permit within tolerance, reject above, fail closed only for an incalculable footprint) | doc + guard header |

MFT-REV-01/02/04/06 and R-1…R-6 re-ran green (no regression).

## Raw evidence (`tmp/movement-first-tranche/rev3/`)

| Command | Result | File + sha256 |
| --- | --- | --- |
| `bash tests/run.sh` | 40 suites green | `lua-suite.log` `fc5b31a3d4a6df43370cb9e48c4f352cfb1952c038da64d1b90e9e5d7033a29c` |
| Python unittest | 39 OK | `python-tests.log` `3187ac53112ab03ff4e385fcef148d6bb1958672bd7ff03ba6216d93ec413811` |
| 3 generator `--check` | 3/3 exit 0 | `generator-checks.log` `2503208f26358c11c18060261b70491e476054b8e2281485592a8142d60e4ab4` |
| probe source `rev3-final-src` | 105/105 | `probe-source-result.json` `3eb51759b893e82e85707efcae85cbd5ea97758af2de1f12114fd8f7b382aa1c` |
| probe dist `rev3-final-dist` | 105/105 | `probe-dist-result.json` `b14783364c26e79147b8dee12415deba01767f49bf40c72fe17074bc6c66b1b0` |
| acceptance source `rev3-final-accept-src2` | 100/100 | `acceptance-source-result.json` `78b0d9632173ce0d7a5e3c0473386223846dccabaa9ef501b3a66e2f28076fa1` |
| acceptance dist `rev3-final-accept-dist` | 100/100 | `acceptance-dist-result.json` `863b1306d817a0637ccaacc97886be532793a115fabf7f21220c5eba85129eda` |

(The first source acceptance attempt hit a startup/port flake at
`fragmented_tcp_connect_returns_ready`; the retry `rev3-final-accept-src2`
passed 100/100. Dist passed on the first attempt.)

## Invariants

One action per opportunity; attempt/instant budgets; `native_pending` never
resubmitted; manual input revokes; owner arbitration; read-only `dry_run`;
deterministic tie-breaks (no RNG); native resolution final; scene change
pause/reset with explicit restart — all green.

Next stage: reviewer `4ba89dc2` re-check, then dispatcher.
