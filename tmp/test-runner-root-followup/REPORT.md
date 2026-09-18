# [Dev] P3 follow-ups N1 + N2 — ready for review

- Worktree: `/workspace/t-engine4/game/addons/tome-mcp-bridge-runner`
- Branch: `fix/test-runner-root` (off `main@122ba09`), **merge=no**
- Follow-up source: P2-1 review report sha256
  `8e67e3917d0fc9b7339d6cc25c2256b6562539ff9bf8e43583aa54c7e05487a2`
  (TODO #62; both P3, non-blocking).
- `allow_auto_combat_execution` stays `false`; game core untouched.

## Per-finding

| finding | Result | Exact command | Raw artifact + sha256 |
| --- | --- | --- | --- |
| **N1** `PolicyLog.add` dropped the client-visible `landing` on `movement_retry` | **PASS** | `TOME_MCP_ADDON_DIR=$PWD luajit -O2 tmp/test-runner-root-followup/n1_probe.lua` | `n1-before.log` `ce57bb26…` (nil), `n1-after.log` `93250bbb…` (`landing=4,2`) |
| **N1** regression coverage (fails pre-fix, passes post-fix) | **PASS** | `luajit -O2 tests/test_auto_combat_catalog.lua` + `…_service.lua` | `n1-regression-prefix.log` `7ebc966d…` (both exit 1), `n1-regression-postfix.log` `2dd9fe97…` (71 + 112) |
| **N2** `tests/run.sh` silently ran the MAIN checkout from an alternate worktree | **PASS** | `bash tests/run.sh` from this worktree (+ sentinel) | `n2-before.log` `521b1bcf…` (`task_root=/workspace/t-engine4`, sentinel 0), `n2-after-sentinel.log` `d44e48a5…` (this addon_dir, sentinel 1) |
| **N2** canonical checkout not weakened | **PASS** | fixed `tests/run.sh` copied into `game/addons/tome-mcp-bridge`, run there | `canonical-fixed.log` `e0b09b7d…` (41 suites) |
| Lua 41/41 (absolute paths) | **PASS** | `for f in $(grep -oE 'tests/test_[a-z_]+\.lua' tests/run.sh \| sort -u); do (cd /workspace/t-engine4 && luajit -O2 "$ADDON/$f"); done` | `lua-absolute.log` `e0a2e294…` (41/41) |
| Lua 41/41 (fixed `tests/run.sh` from THIS worktree) | **PASS** | `bash tests/run.sh` | `lua-runner.log` `abb470ea…` (41/41, `addon_dir=…/tome-mcp-bridge-runner`) |
| Python 39 | **PASS** | `PYTHONPATH=server/src /workspace/t-engine4/tmp/tome-mcp-venv/bin/python -m unittest discover -s server/tests -v` | `python-tests.log` `74356ecf…` (`Ran 39 tests … OK`) |
| 3 generator `--check` | **PASS** | `generate_native_seams.py --check` / `generate_effect_manifest.py --check` / `generate_protocol.py --check` | `generator-checks.log` `f153814c…`; `generators-recheck.log` (`seams=0 manifest=0 protocol=0`) |
| dist repackage + parity 68/68 | **PASS** | `python3 tools/package.py` | `package.log`, `parity.log` `a6de4b49…` (68/68, 0 mismatches, 2 changed files) |

## dist

- baseline dist sha256 (at `main@122ba09`): `6d68fdfd559f89a34bb8e006a9e7be06cb2666d91e07937e036917e1b9088819`
- **new dist sha256: `24b993278b4159668912df3c35fe1bddbd55964918b6eac6bc412553c40c6c6f`**
- 68 production files; archive == manifest == on-disk; idempotent on re-run.
- Files whose archive content differs from `HEAD`: only the 2 production files
  edited here (`AutoCombatService.lua`, `PolicyLog.lua`).

Note: this worktree has no `server/.venv`; Python tests were run with the shared
`/workspace/t-engine4/tmp/tome-mcp-venv/bin/python` (has `mcp==2.2.0`). Running
the system `python3` gives 2 `ModuleNotFoundError: mcp` errors for the
server-importing modules — an environment artifact, not a regression.

## N1 detail

The refused landing was dropped in **two** places, so fixing only `PolicyLog`
would not have made it client-visible:

1. `overload/mod/auto_combat/PolicyLog.lua` — added `landing=event.landing` to the
   allowlisted entry fields (next to the other movement/action fields).
2. `overload/mod/auto_combat/AutoCombatService.lua` — the controller `notify`
   callback now also passes `landing=event.landing` into `withContext`, so the
   value reaches `PolicyLog.add` in the first place.

End-to-end probe (`n1_probe.lua`, production controller → service notify →
PolicyLog):

```
# before
movement_retry keys: action=move,generation=1,kind=movement_retry,native_result=blocked,policy_hash=…,reason=blocked,rule=approach,seq=1
landing present: nil
# after
movement_retry keys: …,kind=movement_retry,landing=4,2,native_result=blocked,…
landing present: 4,2
```

## N2 detail

`tasks_root` used `$(dirname "$0")/../../../..`, which from
`…/tome-mcp-bridge-runner/tests` resolves to `/workspace/t-engine4` and then runs
`game/addons/tome-mcp-bridge/tests/*` (the MAIN checkout). The fixed runner:

```bash
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
addon_dir=${TOME_MCP_ADDON_DIR:-$(cd "$script_dir/.." && pwd)}
addon_dir=$(cd "$addon_dir" && pwd)
game_root=$(cd "$addon_dir/../../.." && pwd)
cd "$game_root"
echo "tests/run.sh: addon_dir=$addon_dir game_root=$game_root"
# every suite is "$addon_dir/tests/<file>.lua"
```

Before/after proof:

| | `task_root`/`addon_dir` | sentinel in this worktree's `test_json.lua` observed? |
| --- | --- | --- |
| before (`HEAD:tests/run.sh`) | `/workspace/t-engine4` → ran main's tests | **no (0)** |
| after (`tests/run.sh`) | `…/tome-mcp-bridge-runner` | **yes (1)** |

`TOME_MCP_ADDON_DIR` override verified (`addon_dir=/workspace/t-engine4/game/addons/tome-mcp-bridge`).
Running the fixed script from the canonical checkout still executes 41/41 suites
(`canonical-fixed.log`), so canonical behaviour is unchanged.

## Status

**ready for review** (not self-accepted/merged). Branch `fix/test-runner-root`,
`merge=no`; changes scoped to N1 + N2 only.
