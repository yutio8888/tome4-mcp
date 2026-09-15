#!/usr/bin/env python3
"""Exercise production bridge TCP and original game actions in a new native home."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import traceback

from runtime import DEFAULT_DEPS, DEFAULT_SOURCE, WORKSPACE, Runtime, sha


class Wire:
    def __init__(self, port: int, transcript: list):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sock.settimeout(8)
        self.reader = self.sock.makefile("rb")
        self.sequence = 0
        self.transcript = transcript

    def packet(self, op: str, args: dict) -> dict:
        self.sequence += 1
        return dict(v=3, id=f"r-{self.sequence}", op=op, args=args)

    def send(self, packet: dict, fragmented: bool = False) -> None:
        self.transcript.append(dict(direction="request", message=packet))
        data = json.dumps(packet, separators=(",", ":")).encode() + b"\n"
        if fragmented:
            for part in (data[:1], data[1:5], data[5:-1], data[-1:]):
                self.sock.sendall(part)
                time.sleep(0.025)
        else:
            self.sock.sendall(data)

    def receive(self, packet: dict) -> dict:
        line = self.reader.readline()
        assert line, "Bridge closed the TCP connection"
        response = json.loads(line)
        self.transcript.append(dict(direction="response", message=response))
        assert response["v"] == 3 and response["id"] == packet["id"], response
        return response

    def raw(self, op: str, args: dict, fragmented: bool = False) -> dict:
        packet = self.packet(op, args)
        self.send(packet, fragmented)
        return self.receive(packet)

    def call(self, op: str, args: dict, fragmented: bool = False) -> dict:
        response = self.raw(op, args, fragmented)
        assert response.get("ok"), response
        return response["result"]

    def batch(self, operations: list[tuple[str, dict]]) -> list[dict]:
        packets = [self.packet(op, args) for op, args in operations]
        data = b""
        for packet in packets:
            self.transcript.append(dict(direction="request", message=packet))
            data += json.dumps(packet, separators=(",", ":")).encode() + b"\n"
        self.sock.sendall(data)
        return [self.receive(packet) for packet in packets]

    def close(self) -> None:
        self.reader.close()
        self.sock.close()


class Acceptance:
    TERMINAL = {"completed", "failed", "cancelled", "needs_input"}

    def __init__(self, runtime: Runtime):
        self.runtime = runtime
        self.checks = []
        self.transcript = []
        self.wire = None
        self.session_id = self.control_token = None
        self.sequence = 0

    def check(self, condition: bool, name: str, **details) -> None:
        record = dict(name=name, passed=bool(condition), **details)
        self.checks.append(record)
        print(json.dumps(dict(name=name, passed=bool(condition)), ensure_ascii=False), flush=True)
        assert condition, record

    def connect(self, fragmented: bool = False) -> dict:
        if self.wire:
            self.wire.close()
        self.wire = Wire(self.runtime.port, self.transcript)
        result = self.wire.call("connect", {"token": self.runtime.token}, fragmented)
        if self.session_id:
            self.check(result["session_id"] == self.session_id, "tcp_reconnect_preserves_game_session")
        self.session_id = result["session_id"]
        self.control_token = result["control_token"]
        return result

    def observe(self) -> dict:
        return self.wire.call("observe", dict(session_id=self.session_id))

    def action_args(self, action: dict, snapshot: dict | None = None) -> dict:
        self.sequence += 1
        if snapshot is None:
            snapshot = self.observe()
        return dict(session_id=self.session_id, control_token=self.control_token,
                    command_id=f"native-{self.sequence}", expected_revision=snapshot["revision"], action=action)

    def finish(self, result: dict) -> dict:
        deadline = time.monotonic() + 15
        while result["status"] not in self.TERMINAL:
            assert time.monotonic() < deadline, result
            time.sleep(0.03)
            result = self.wire.call("status", dict(session_id=self.session_id, command_id=result["command_id"]))
        return result

    def act(self, action: dict) -> tuple[dict, dict, dict]:
        before = self.observe()
        self.check(before["phase"] == "ready", "action_starts_ready", action=action)
        args = self.action_args(action, before)
        result = self.finish(self.wire.call("act", args))
        self.check(result["status"] == "completed", "native_command_completed", action=action, result=result)
        after = result.get("snapshot") or self.observe()
        self.check(after["phase"] == "ready", "command_finishes_ready", action=action)
        return before, result, args

    def native_state(self) -> dict:
        time.sleep(0.2)
        return self.runtime.latest_state()

    def run(self) -> None:
        self.runtime.wait_ready()
        birth = self.runtime.records()
        perception = [r for r in birth if r.get('kind') == 'visibility_check']
        self.check(len(perception)==9 and all(r['passed'] for r in perception),
                   'native_world_and_dungeon_perception_regressions', checks=perception)
        self.check(any(r.get("kind") == "birth_started" for r in birth)
                   and any(r.get("kind") == "birth_complete" and r.get("new_character") for r in birth),
                   "fresh_native_birth_no_imported_save")
        result = self.connect(fragmented=True)
        self.check(result["snapshot"]["phase"] == "ready", "fragmented_tcp_connect_returns_ready")
        native_before = self.native_state()
        first = self.observe()
        responses = self.wire.batch([("observe", dict(session_id=self.session_id)),
                                     ("observe", dict(session_id=self.session_id))])
        self.check(all(r.get("ok") and r["result"] == first for r in responses),
                   "multiple_tcp_packets_repeat_identical_observation")
        inspected = self.wire.call("inspect", dict(session_id=self.session_id, kind="talent", id="T_LIGHTNING"))
        self.check(bool(inspected), "inspect_native_lightning")
        native_after = self.native_state()
        stable_fields = ("x", "y", "life", "mana", "energy", "world_tick", "actions", "enemy_acts", "lightning_cd", "adrenaline_cd")
        self.check(all(native_before[k] == native_after[k] for k in stable_fields),
                   "observe_inspect_preserve_native_state", before=native_before, after=native_after)
        purity = [r for r in self.runtime.records() if r.get("kind") == "observation_check"]
        self.check(any(r.get("method") == "capture" for r in purity)
                   and any(r.get("method") == "inspect" for r in purity)
                   and all(r.get("passed") for r in purity),
                   "native_observer_calls_no_rng_perception_or_talent_prechecks")
        hidden = self.wire.raw("inspect", dict(session_id=self.session_id, kind="actor", id="not-visible"))
        self.check(not hidden.get("ok"), "inspect_unknown_actor_rejected")
        visible = [a for a in first["actors"] if a.get("name") == "MCP target dummy"]
        self.check(len(visible) == 1 and all(a.get("name") != "MCP hidden dummy" for a in first["actors"]),
                   "observer_includes_perceived_enemy_and_excludes_hidden_fixture")
        fixture = next(r for r in birth if r.get("kind") == "arena_ready")
        prefix, separator, suffix = visible[0]["id"].rpartition(str(fixture["enemy_uid"]))
        self.check(bool(separator), "native_actor_id_is_fixture_reference")
        hidden_id = prefix + str(fixture["hidden_uid"]) + suffix
        hidden = self.wire.raw("inspect", dict(session_id=self.session_id, kind="actor", id=hidden_id))
        self.check(not hidden.get("ok"), "inspect_real_hidden_actor_by_guessed_id_rejected")

        before, command, original = self.act({"type": "wait"})
        after = command.get("snapshot") or self.observe()
        self.check(command["energy_spent"] > 0 and after["world_tick"] > before["world_tick"],
                   "wait_consumes_native_energy_and_advances_world")
        state = self.native_state()
        self.check(state["enemy_acts"] > native_before["enemy_acts"], "native_enemy_scheduler_runs")
        repeated = self.wire.call("act", original)
        self.check(repeated["command_id"] == command["command_id"] and repeated["status"] == "completed",
                   "completed_command_id_returns_existing_result")
        self.check(self.native_state()["actions"] == state["actions"], "duplicate_does_not_repeat_native_action")
        conflict = dict(original, action={"type": "move", "direction": 4})
        response = self.wire.raw("act", conflict)
        self.check(not response.get("ok") and response["error"]["code"] == "command_conflict", "command_id_conflict_rejected")
        stale = self.action_args({"type": "wait"}, before)
        response = self.wire.raw("act", stale)
        self.check(not response.get("ok") and response["error"]["code"] == "stale_revision", "stale_revision_rejected")

        before, command, _ = self.act({"type": "move", "direction": 6})
        after = command.get("snapshot") or self.observe()
        self.check(after["player"]["x"] == before["player"]["x"] + 1
                   and after["player"]["y"] == before["player"]["y"], "native_move_changes_requested_coordinate")
        state = self.native_state()
        before, command, _ = self.act({"type": "use_talent", "talent_id": "T_ADRENALINE_SURGE"})
        after = command.get("snapshot") or self.observe()
        current = self.native_state()
        self.check(command["energy_spent"] == 0 and after["world_tick"] == before["world_tick"]
                   and after["revision"] > before["revision"] and current["adrenaline_cd"] > 0
                   and current["adrenaline_active"] and current["energy"] == state["energy"],
                   "native_instant_talent_updates_effect_cooldown_revision_without_world_tick")

        state = self.native_state()
        self.act({"type": "use_talent", "talent_id": "T_HEAL"})
        current = self.native_state()
        self.check(current["life"] > state["life"] and current["mana"] < state["mana"], "native_heal_changes_life_and_mana")
        snapshot = self.observe()
        targets = [a for a in snapshot["actors"] if a.get("name") == "MCP target dummy"]
        self.check(len(targets) == 1, "native_perceived_enemy_available")
        target_id = targets[0]["id"]
        state = self.native_state()
        self.act({"type": "use_talent", "talent_id": "T_LIGHTNING", "target_id": target_id})
        current = self.native_state()
        self.check(current["enemy_life"] < state["enemy_life"] and current["mana"] < state["mana"]
                   and current["lightning_cd"] > 0, "native_lightning_damage_resource_cooldown")
        cooldown_before = self.observe()
        cooldown_args = self.action_args({"type": "use_talent", "talent_id": "T_LIGHTNING", "target_id": target_id}, cooldown_before)
        rejected = self.finish(self.wire.call("act", cooldown_args))
        cooldown_after = self.observe()
        self.check(rejected["status"] == "failed" and rejected["energy_spent"] == 0
                   and cooldown_after["world_tick"] == cooldown_before["world_tick"],
                   "native_cooldown_rejection_does_not_consume_turn")
        unknown = self.finish(self.wire.call("act", self.action_args({"type": "use_talent", "talent_id": "T_NO_SUCH_TALENT"})))
        self.check(unknown["status"] == "failed" and unknown.get("code") in {"talent_not_learned", "invalid_talent"},
                   "unknown_talent_rejected_before_execution")
        self.act({"type": "move", "direction": 6})
        self.act({"type": "attack", "target_id": target_id})
        self.check(any(r.get("kind") == "native_action" and r.get("method") == "attackTarget"
                       for r in self.runtime.records()), "native_melee_entry_invoked")

        original = self.action_args({"type": "wait"})
        state = self.native_state()
        accepted = self.wire.call("act", original)
        self.wire.close()
        time.sleep(0.3)
        self.connect()
        recovered = self.finish(self.wire.call("status", dict(session_id=self.session_id, command_id=accepted["command_id"])))
        current = self.native_state()
        self.check(recovered["status"] in {"completed", "cancelled"} and current["actions"] - state["actions"] <= 1,
                   "disconnect_status_recovers_without_replaying_action", status=recovered["status"])
        original["control_token"] = self.control_token
        self.wire.call("act", original)
        self.check(self.native_state()["actions"] == current["actions"], "reconnect_duplicate_cannot_replay_action")

        original = self.action_args({"type": "wait"})
        state = self.native_state()
        response = self.wire.batch([("act", original), ("stop", dict(session_id=self.session_id, control_token=self.control_token))])
        self.check(all(r.get("ok") for r in response), "queued_action_and_stop_accepted")
        # stop may retain the read channel; explicit reconnect is always allowed.
        self.wire.close()
        time.sleep(0.2)
        self.connect()
        cancelled = self.wire.call("status", dict(session_id=self.session_id, command_id=original["command_id"]))
        self.check(cancelled["status"] == "cancelled" and self.native_state()["actions"] == state["actions"],
                   "stop_cancels_unstarted_native_action")

        snapshot = self.observe()
        old_control = self.control_token
        self.runtime.input.press("Shift_L")
        time.sleep(0.3)
        self.check(self.wire.sock.recv(1) == b"", "real_x11_key_disconnects_existing_controller")
        self.wire.close()
        self.connect()
        stale_control = self.action_args({"type": "wait"})
        stale_control["control_token"] = old_control
        response = self.wire.raw("act", stale_control)
        self.check(not response.get("ok") and self.observe()["revision"] > snapshot["revision"],
                   "real_x11_key_revokes_old_control_and_revision")
        self.runtime.input.press("Escape")
        time.sleep(0.3)
        self.wire.close()
        self.connect()
        dialog = self.observe()
        self.check(dialog["phase"] == "needs_input", "native_escape_menu_reports_needs_input", phase=dialog["phase"])
        self.runtime.input.press("Shift_L")
        time.sleep(0.3)
        self.check(self.wire.sock.recv(1) == b"", "real_dialog_key_disconnects_existing_controller")
        self.connect()
        dialog = self.observe()
        response = self.wire.raw("act", self.action_args({"type": "wait"}, dialog))
        self.check(not response.get("ok"), "native_dialog_blocks_world_action")
        self.runtime.input.press("Escape")
        time.sleep(0.3)
        self.wire.close()
        self.connect()
        self.check(self.observe()["phase"] == "ready", "native_dialog_close_restores_ready")

    def run_mcp(self, python: Path) -> None:
        self.wire.close()
        self.wire = None
        time.sleep(0.2)
        environment = dict(os.environ)
        environment.update(PYTHONPATH=str(Path(__file__).resolve().parents[2] / "server/src"),
                           TOME_MCP_TOKEN=self.runtime.token, TOME_MCP_PORT=str(self.runtime.port))
        result = subprocess.run([str(python), str(Path(__file__).with_name("mcp_smoke.py"))],
                                env=environment, capture_output=True, text=True, timeout=45)
        (self.runtime.session / "mcp.log").write_text(result.stdout + result.stderr)
        self.check(result.returncode == 0, "official_mcp_stdio_native_integration", stderr=result.stderr)
        evidence = json.loads(result.stdout)
        self.check(evidence["passed"], "official_mcp_all_checks_passed")
        self.checks.extend(evidence["checks"])

    def run_reload(self) -> None:
        self.connect()
        old_session = self.session_id
        saved_before = sum(r.get("kind") == "save_complete" for r in self.runtime.records())
        self.runtime.input.chord("Control_L", "s")
        deadline = time.monotonic() + 30
        while sum(r.get("kind") == "save_complete" for r in self.runtime.records()) <= saved_before:
            assert self.runtime.process.poll() is None, "Game exited during save"
            assert time.monotonic() < deadline, "Native Ctrl+S save did not complete"
            time.sleep(0.05)
        self.check(self.wire.sock.recv(1) == b"", "native_ctrl_s_save_revokes_control")
        self.wire.close()
        self.wire = None
        original_home = self.runtime.home
        save_root = original_home / ".t-engine/4.0/tome/save"

        def save_hashes(root: Path) -> dict:
            return {str(p.relative_to(root)): sha(p) for p in root.rglob("*") if p.is_file()}

        original_hashes = save_hashes(save_root)
        self.check(bool(original_hashes) and any(p.endswith("game.teag") for p in original_hashes),
                   "native_ctrl_s_produces_game_save")
        self.runtime.restart_from_saved_copy()
        deadline = time.monotonic() + 90
        while not any(r.get("kind") == "reload_ready" for r in self.runtime.records()):
            assert self.runtime.process.poll() is None, "Reload exited before ready"
            errors = [r for r in self.runtime.records() if r.get("kind") == "error"]
            assert not errors, errors
            assert time.monotonic() < deadline, "Native load did not finish"
            time.sleep(0.05)
        time.sleep(0.2)
        state = self.native_state()
        time.sleep(0.5)
        idle = self.native_state()
        self.check(state["actions"] == 0 and idle["actions"] == 0 and idle["world_tick"] == state["world_tick"],
                   "native_reload_does_not_restore_automatic_commands", before=state, after=idle)
        reload_log = (self.runtime.session / "reload.log").read_text(errors="replace")
        self.check('"kind":"birth_started"' not in reload_log, "reload_uses_own_saved_character_without_new_birth")
        self.wire = Wire(self.runtime.port, self.transcript)
        connected = self.wire.call("connect", dict(token=self.runtime.token))
        self.check(connected["session_id"] != old_session, "native_reload_creates_new_session_and_rebinds_same_port")
        self.session_id = connected["session_id"]
        self.control_token = connected["control_token"]
        response = self.wire.raw("observe", dict(session_id=old_session))
        self.check(not response.get("ok") and response["error"]["code"] == "session_mismatch", "old_session_rejected_after_native_load")
        response = self.wire.raw("status", dict(session_id=self.session_id, command_id="official-mcp-wait"))
        self.check(not response.get("ok") and response["error"]["code"] == "unknown_command", "old_command_history_not_serialized")
        self.check(original_hashes == save_hashes(save_root), "original_fixture_save_unchanged_by_reload")
        self.check(original_hashes == save_hashes(self.runtime.home / ".t-engine/4.0/tome/save"),
                   "reload_does_not_rewrite_copied_fixture_save")
        self.act({"type": "wait"})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", help="new name; existing results are never overwritten")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--deps", type=Path, default=DEFAULT_DEPS)
    parser.add_argument("--mcp-python", type=Path, default=WORKSPACE / "tmp/tome-mcp-venv/bin/python")
    parser.add_argument("--addon-archive", type=Path, help="load a packaged .teaa instead of the production source directory")
    args = parser.parse_args()
    runtime = Runtime(args.session, args.source.resolve(), args.deps.resolve(),
                      args.addon_archive.resolve() if args.addon_archive else None)
    acceptance = Acceptance(runtime)
    error = None
    started = time.monotonic()
    try:
        runtime.start()
        acceptance.run()
        acceptance.run_mcp(args.mcp_python.absolute())
        acceptance.run_reload()
    except Exception:
        error = traceback.format_exc()
        print(error, flush=True)
    finally:
        if acceptance.wire:
            acceptance.wire.close()
        runtime.close()
    content = "\n".join(path.read_text(errors="replace") for path in runtime.log_paths)
    result = dict(passed=error is None and "Lua Error:" not in content and "[COROUTINE] error" not in content,
                  elapsed_seconds=time.monotonic() - started, checks=acceptance.checks, error=error,
                  lua_error="Lua Error:" in content or "[COROUTINE] error" in content,
                  native_records=runtime.records())
    (runtime.session / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    # Tokens are local test credentials; redact them even from isolated evidence.
    transcript = json.dumps(acceptance.transcript, ensure_ascii=False, indent=2).replace(runtime.token, "<redacted>")
    (runtime.session / "wire.json").write_text(transcript)
    print(json.dumps(dict(passed=result["passed"], checks=len(result["checks"]), evidence=str(runtime.session))))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
