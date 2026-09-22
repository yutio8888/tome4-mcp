#!/usr/bin/env python3
"""Native P1a auto-combat acceptance: the §14 scenarios in the real engine.

Starts a fresh isolated ToME run with the production bridge and the test-only
`tome-auto-combat-probe`. The probe drives the production controller against the
production host (audited reads + the real Actions.execute executor) and emits one
`[AutoCombatProbe]` record per declared check. Expected signals are declared in
the probe before the run; this runner only collects and reports them.
"""
from __future__ import annotations

import argparse
import os
import json
import time
import traceback
from pathlib import Path

from runtime import DEFAULT_DEPS, DEFAULT_SOURCE, WORKSPACE, Runtime, sha

ADDON = Path(os.environ["TOME_MCP_ADDON_DIR"]) if os.environ.get("TOME_MCP_ADDON_DIR") else WORKSPACE / "game/addons/tome-mcp-bridge"


def configure_policy_only(runtime: Runtime) -> None:
    """Use the engine's settings loader; its Lua sandbox has no os.getenv."""
    setting = runtime.home / '.t-engine/4.0/settings/mcp-test.cfg'
    with setting.open('a') as stream:
        stream.write('\ntome_mcp_sysfix_policy_probe = true\n')
    metadata_path = runtime.session / 'input.json'
    metadata = json.loads(metadata_path.read_text())
    metadata.update(sysfix_policy=True, sysfix_policy_setting_sha256=sha(setting))
    metadata_path.write_text(json.dumps(metadata, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", help="new name; existing results are never overwritten")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--deps", type=Path, default=DEFAULT_DEPS)
    parser.add_argument("--addon-archive", type=Path,
                        help="load the production addon from this .teaa instead of the source directory")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument('--policy-only', action='store_true',
                        help='run SYSFIX policy cases with real native submission outcomes only')
    args = parser.parse_args()

    runtime = Runtime(args.session, args.source.resolve(), args.deps.resolve(),
                      addon_archive=args.addon_archive.resolve() if args.addon_archive else None,
                      extra_addons={"auto-combat-probe": ADDON / "tests/native/tome-auto-combat-probe"})
    if args.policy_only:
        configure_policy_only(runtime)
    error = None
    started = time.monotonic()
    checks: list[dict] = []
    done: dict | None = None
    try:
        runtime.start()
        runtime.wait_ready(timeout=args.timeout)
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            records = runtime.records()
            errors = [r for r in records if r.get("kind") == "error"]
            assert not errors, errors
            checks = [r for r in records if r.get("kind") == "auto_combat_check"]
            done = next((r for r in records if r.get("kind") == "auto_combat_done"), None)
            if done:
                break
            assert runtime.process.poll() is None, "Game exited before auto-combat scenarios finished"
            time.sleep(0.1)
        assert done is not None, "auto-combat scenarios did not finish"
        if args.policy_only:
            assert done.get("suite") == "sysfix-policy", "wrong native probe suite selected"
    except Exception:
        error = traceback.format_exc()
    finally:
        runtime.close()

    content = "\n".join(path.read_text(errors="replace") for path in runtime.log_paths)
    passed = (error is None and done is not None and done.get("passed") is True
              and "Lua Error:" not in content and "[COROUTINE] error" not in content)
    result = {
        "passed": passed,
        "suite": "sysfix-policy" if args.policy_only else "auto-combat",
        "probe_sha256": sha(ADDON / 'tests/native/tome-auto-combat-probe/overload/mod/SysfixPolicyProbe.lua')
            if args.policy_only else sha(ADDON / 'tests/native/tome-auto-combat-probe/overload/mod/AutoCombatProbe.lua'),
        "source_module_sha256": {str(p.relative_to(ADDON)): sha(p)
                                 for p in sorted((ADDON / 'overload/mod/auto_combat').rglob('*.lua'))}
            if not args.addon_archive else None,
        "addon_load_mode": "dist" if args.addon_archive else "source",
        "addon_archive_sha256": sha(args.addon_archive) if args.addon_archive else None,
        "elapsed_seconds": time.monotonic() - started,
        "error": error,
        "done": done,
        "checks": checks,
        "lua_error": "Lua Error:" in content or "[COROUTINE] error" in content,
        "game_log_sha256": sha(runtime.session / "game.log"),
        "candidate_sha256": sha(runtime.session / "candidate.zip"),
    }
    (runtime.session / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(dict(passed=passed, checks=len(checks),
                          evidence=str(runtime.session),
                          game_log_sha256=result["game_log_sha256"])))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
