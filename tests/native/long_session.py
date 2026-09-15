#!/usr/bin/env python3
"""G-02: prove the v4 ledger accepts and settles more than the old 4096-command
limit, then recovers and refuses to replay an evicted command.

This is an isolated native fixture run (the probe arena), not a campaign or a
claim about ordinary play. Usage:
    python3 tests/native/long_session.py m5-long-01 --count 5000
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from runtime import DEFAULT_DEPS, DEFAULT_SOURCE, Runtime
from run import Wire

TERMINAL = {"completed", "failed", "cancelled", "needs_input"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session")
    parser.add_argument("--count", type=int, default=5000)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--deps", type=Path, default=DEFAULT_DEPS)
    args = parser.parse_args()
    runtime = Runtime(args.session, args.source, args.deps)
    wire = None
    error = None
    summary: dict = {}
    started = time.monotonic()
    try:
        runtime.start()
        runtime.wait_ready()
        wire = Wire(runtime.port, [])
        connection = wire.call("connect", {"token": runtime.token})
        session = connection["session_id"]
        token = connection["control_token"]
        snapshot = wire.call("observe", {"session_id": session})
        accepted = 0
        for index in range(1, args.count + 1):
            command_id = snapshot["history"]["next_command_id"]
            assert command_id, snapshot["history"]
            record = wire.call("act", {"session_id": session, "control_token": token,
                                       "command_id": command_id,
                                       "expected_revision": snapshot["revision"],
                                       "action": {"type": "wait"}})
            deadline = time.monotonic() + 15
            while record["status"] not in TERMINAL:
                assert time.monotonic() < deadline, record
                record = wire.call("status", {"session_id": session, "command_id": command_id})
            assert record["status"] == "completed", record
            accepted += 1
            snapshot = record.get("snapshot") or wire.call("observe", {"session_id": session})
            if index % 500 == 0:
                print(json.dumps({"accepted": accepted, "seq": snapshot["history"]["last_accepted_seq"],
                                  "evicted": snapshot["history"]["evicted_through_seq"]}), flush=True)
        history = snapshot["history"]
        native_actions = runtime.latest_state()["actions"]
        assert accepted == args.count
        assert history["last_accepted_seq"] >= args.count
        assert history["evicted_through_seq"] > 0
        assert history["retained_count"] <= 256
        # A disconnect and explicit reconnect keeps the same game session.
        wire.close()
        time.sleep(0.3)
        wire = Wire(runtime.port, [])
        reconnected = wire.call("connect", {"token": runtime.token})
        assert reconnected["session_id"] == session
        # An evicted command is expired, never replayed.
        expired = wire.raw("status", {"session_id": session, "command_id": "cmd-1"})
        assert not expired.get("ok") and expired["error"]["code"] == "command_history_expired", expired
        assert expired["error"].get("accepted") is True and expired["error"].get("recovery") == "do_not_replay"
        # A used identity with a different action is a conflict, and the native
        # action counter must not move.
        before_actions = runtime.latest_state()["actions"]
        conflict = wire.raw("act", {"session_id": session, "control_token": token,
                                    "command_id": command_id, "expected_revision": snapshot["revision"],
                                    "action": {"type": "move", "direction": 6}})
        assert not conflict.get("ok") and conflict["error"]["code"] == "command_conflict", conflict
        time.sleep(0.2)
        assert runtime.latest_state()["actions"] == before_actions
        summary = {"accepted": accepted, "last_accepted_seq": history["last_accepted_seq"],
                   "evicted_through_seq": history["evicted_through_seq"],
                   "retained_count": history["retained_count"],
                   "reconnect_same_session": True, "expired_cmd1": True, "conflict_no_replay": True,
                   "native_actions_before_conflict": before_actions, "native_actions": native_actions}
    except Exception:
        import traceback
        error = traceback.format_exc()
        print(error, flush=True)
    finally:
        if wire:
            wire.close()
        runtime.close()
    elapsed = time.monotonic() - started
    result = {"passed": error is None, "error": error, "elapsed_seconds": elapsed, **summary}
    (runtime.session / "long-session.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({"passed": result["passed"], "accepted": summary.get("accepted"),
                      "elapsed_seconds": round(elapsed, 1), "evidence": str(runtime.session)}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
