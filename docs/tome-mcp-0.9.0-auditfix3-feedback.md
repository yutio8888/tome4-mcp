# 0.9.0 auditfix3 — NEW-03 / NEW-04 settlement-time progression recheck

Review round: `fix/progression-settlement-recheck` (branch continuing from reviewed head
`48a379a2`). Disposition of the two P1 findings from the fresh review
(`tmp/mcp-play-support/review-auditfix2.md`, sha256
`5419f2915d05b9cb097f896ff1abe31cd48d02d1d727436afc6a929f470940be`). NEW-02 stays fixed
(untouched this round); NEW-01's synchronous checks stay in place and are now backed by a
settlement-time re-validation.

## NEW-03 (P1) — deferred `game:onTickEnd` undo can no longer publish a false success

The reviewer showed that a replaced-but-callable `on_levelup_close` can schedule the undo
with the real native pattern `game:onTickEnd(...)` (official talents do this too,
`data/talents/psionic/solipsism.lua:48`), so both synchronous checks inside
`Progression.execute` see the requested delta, `progression_applied` is returned, and the
queued callback later restores the pre-operation state while `Runtime` settles from
`command.action_ok` without re-running the postcondition.

Fix (`overload/mod/mcp_bridge/Progression.lua`, `overload/mod/mcp_bridge/Runtime.lua`):

- When a mutation is accepted (`ok=true`), `Progression.execute`/`executeUnlearn` attach a
  **postcondition descriptor** to the outcome: `{pool, expected_points, operation, target,
  expected_value}`. Runtime copies it onto the command
  (`command.progression_postcondition`, in-memory only, never serialized/saved).
- Runtime re-validates it **at settlement time** in the `phase=='ready'` branch of
  `settle()` — after the native tick-end queue has drained (`onTickEndExists()` would keep
  the phase `'settling'`) and `root.done` holds, i.e. after every owned deferred callback
  has already run, and before `finish(...,'completed',...)` publishes success.
- A mismatch settles as a **typed uncertain failure**
  (`native_progression_mismatch`, `uncertain=true`, `action_ok=false`, lease revoked,
  session quarantined like every other partial-mutation path); a recheck that cannot read
  the final state settles as `progression_execution_error` + `uncertain=true`. Success is
  only published when the drained final state still matches the claim.
- No identity/digest/source gate was reintroduced: `Progression.checkPostcondition` calls
  the same live, total, type-safe reads used during execute (`rawLevel`,
  `categoryTargetValue`, `p.stats`, `p[pool]`). Missing/wrong-typed/non-finite values are
  typed mismatches (`points`/`target`), never errors.

## NEW-04 (P1) — wrong-typed mastery can no longer escape untyped

`targetValue` computed `((mastery or 0)+1)` for `learn_category` before validating the
value, and the after-`unload` call site was outside any `pcall`; a callable unload that
leaves the category known with a string mastery escaped `Progression.execute` after the
category point was already spent.

Fix:

- New `categoryTargetValue(p,category)`: validates `type`/finiteness **before** any
  arithmetic (`mastery==nil → 1`, finite number → `mastery+1`, anything else → `nil` = typed
  mismatch). Used by `targetValue` and by the settlement checker.
- The expected-value computation refuses a wrong-typed mastery on a locked category with a
  clean pre-mutation `progression_state_unknown` refusal (nothing spent yet).
- Both after-unload rechecks (write path and respec path) are now `pcall`-protected: any
  error becomes a typed `progression_execution_error` + `uncertain=true` failure, never an
  escaping error, never `ok=true`.

## Regressions added

- `tests/test_progression.lua` (+14 checks): descriptor coverage for all four write
  operations (`spend_stat`, `learn_talent`, `learn_category` unlock and mastery improve,
  `unlearn_talent`) with live recheck pass/mismatch cases (pool restored, target restored,
  wrong-typed raw level), typed `invalid_postcondition` for malformed descriptors, the
  callable-unload string-mastery typed uncertain failure (previously an escaping
  arithmetic error after spending the point), a live-hook wrong-type corruption between
  mutation and check, and the clean pre-mutation refusal.
- `tests/test_runtime.lua` (+7 checks, end-to-end through the Runtime settlement path): a
  growth action that performs a real mutation and schedules a real `game:onTickEnd` undo
  (the native pattern) settles as `failed` / `uncertain` /
  `native_progression_mismatch` / `action_ok=false` after the queue drains, quarantines
  the session, and cannot be bypassed by reconnect; the same action without the undo
  settles `completed` — success only when the drained final state matches the claim.

## Acceptance evidence (all commands run in the worktree)

| Check | Result | Command / evidence |
| --- | --- | --- |
| Lua suites 42/42 | PASS | `TOME_MCP_ADDON_DIR=<wt> bash tests/run.sh` → exit 0 (Progression 264 checks, Runtime 248); `tmp/mcp-play-support/auditfix3/lua-suite.log` sha256 `bdee61ad108bf43ece0d06c182b23050215bd5d996b5ccb0ab7a55a2f50ef4c0` |
| Python 39 | PASS | `PYTHONPATH=<wt>/server/src tmp/tome-mcp-venv/bin/python -m unittest discover -s <wt>/server/tests` → `Ran 39 tests ... OK`; `tmp/mcp-play-support/auditfix3/python-tests.log` sha256 `70e3889e2ea460cc08268b1ebf2be310b7df4d6a269096ed70e00bf5cea479f8` |
| three `--check` | PASS | `tools/generate_native_seams.py --check`, `tools/generate_effect_manifest.py --check`, `tools/generate_protocol.py --check` → all exit 0; `tmp/mcp-play-support/auditfix3/generator-checks.log` sha256 `85475261343d5f27aec72f802f6af80a66ae150876c4cdf74cf7b3c059b5fa6b` |
| package parity | 68/68 | `python3 tools/package.py` → 68 files; dist `tome-mcp-bridge.teaa` sha256 `ca1cc6f92c8d036b13d5ae22de16002c83d69f674ee048055521c37aac9fcea3`; independently re-hashed 68/68 archive entries against the source tree, 0 divergent |
| auto-combat probe source | 177/177 PASS | `TOME_MCP_ADDON_DIR=<wt> python3 tests/native/auto_combat_run.py auditfix3-probe-src-01`; session `tmp/tome-mcp-validation/sessions/auditfix3-probe-src-01` (result.json sha256 `6bd3b622cd1f2fee9e0e144a19211743b4702fa395c964fa4ed9d15bdef1f780`, game.log sha256 `7ad2687c9f4f1ea0026972675f30b25486810df58f76204247a653a0e498ee77`); log `tmp/mcp-play-support/auditfix3/probe-source.log` sha256 `4bd66221c473c13faf4accf93d6a2d63d5a06193c13b99718c4f374164c0da34` |
| auto-combat probe dist | 177/177 PASS | same + absolute `--addon-archive <wt>/dist/tome-mcp-bridge.teaa` → `auditfix3-probe-dist-01` (result.json sha256 `d3b631986b28a65ab2f87d5c5112da4b8bc73a8accf0273e0a65dfcd88eaefd9`, game.log sha256 `04efad43b720346e5d039525ffacf65a8ce29c26fa9cd2e07f8671b7256cd788`); log sha256 `69c8b61560bb9db28d9f935681c9ebda0536cc1c49ca66adbb835850b5dd9b56` |
| native acceptance source | 101/101 PASS | `TOME_MCP_ADDON_DIR=<wt> python3 tests/native/run.py auditfix3-accept-src-01`; session `auditfix3-accept-src-01` (result.json sha256 `024c597eea6c67ff69e91f5c9c76c2c2d54a6e871fbe82ec295db841c6de07c3`, game.log sha256 `3f6690109a7cbc317665579c971bdd6bf3c13a056d5cc503377fa6d2a2ae8c65`); log sha256 `6825c543d7a9583f37c8582fbe681dc66b5772843e3f2abf5e3da8ac2211089c` |
| native acceptance dist | 101/101 PASS | same + absolute `--addon-archive` → `auditfix3-accept-dist-01` (result.json sha256 `db386bec8900f383049c9830fd7d0320d6f51b63c8c912ac6e6cb324fd941d98`, game.log sha256 `b64df265ad7db5fd326bfaf16bd703a439da1853e3e45f80446a94887b77ff5b`); log sha256 `20ea6250879eb196dda3cb85eef290eb070bc9062530db834e6fa3f2adaa2ed7` |
| sessions reaped | PASS | `harness/console/reap-session.sh --all` then `--list` → empty before reporting |

No flake reruns were needed: `fragmented_tcp_connect_returns_ready` and
`movement-talents:tumble-execute` both passed on the first run in source and dist sessions.

## Invariants

Unchanged: reads never submit actions and never expose player-unknown information;
one-opportunity budget; `native_pending` never resubmitted; manual input revokes the
lease; `dry_run` never executes; deterministic tie-breaks; **no identity/digest/closure
gate** (replaced-but-callable entrypoints are called and used); missing/erroring/
non-finite/wrong-typed values stay typed `progression_*` reasons. No protocol field added,
no game-core change, no generated file hand-edited, runtime state never enters the
savefile (`progression_postcondition` is command-memory only), `allow_auto_combat_execution`
stays `false`.
