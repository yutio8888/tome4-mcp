#!/usr/bin/env python3
"""Official-MCP acceptance from the ordinary Trollmire exit save.

No fixture addon, stat edits, learned talents, or native action injection is used.
Navigation and combat decisions consume only returned MCP observations.
"""
from __future__ import annotations

import argparse
import asyncio
from collections import Counter, deque
import json
import os
from pathlib import Path
import re
import sys
import time
import traceback

from mcp import Client, StdioServerParameters

from runtime import CampaignRuntime, DEFAULT_SESSION

STUN = "T_STUNNING_BLOW_ASSAULT"
SHOUT = "T_WARSHOUT_BERSERKER"
HEAL = "T_INFUSION:_HEALING_3"
REGEN = "T_INFUSION:_REGENERATION_1"
WILD = "T_INFUSION:_WILD_2"
REQUIRED_TALENTS = {STUN, SHOUT, HEAL, REGEN, WILD}
DIRECTIONS = {7: (-1, -1), 8: (0, -1), 9: (1, -1), 4: (-1, 0),
              6: (1, 0), 1: (-1, 1), 2: (0, 1), 3: (1, 1)}
FINAL = {"completed", "failed", "cancelled", "needs_input"}


def redact(value):
    if isinstance(value, dict):
        return {k: "<redacted>" if "token" in k else redact(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def compact(snapshot: dict) -> dict:
    return {k: snapshot.get(k) for k in ("phase", "control", "session_id", "level_instance_id",
            "revision", "world_tick", "scene", "player", "actors", "battle_companion")}


def distance(a: dict, b: dict) -> int:
    return max(abs(a["x"] - b["x"]), abs(a["y"] - b["y"]))


class Campaign:
    def __init__(self, runtime: CampaignRuntime, client: Client):
        self.runtime, self.client = runtime, client
        self.connection = None
        self.current = None
        self.checks = []
        self.commands = []
        self.successful_talents = set()
        self.rest_tested = False
        self.rest_bound_tested = False
        self.rest_enemy_tested = False
        self.minimum_life = float("inf")
        self.counter = 0
        self.transcript = (runtime.session / "campaign-mcp.jsonl").open("w")
        self.decisions = (runtime.session / "decisions.jsonl").open("w")
        self.level_id = None
        self.memory = {}
        self.visits = Counter()
        self.blocked = set()
        self.encounter_waits = 0
        self.event_cursor = 0
        self.event_entries = []
        self.event_gaps = []

    def check(self, condition: bool, name: str, **details) -> None:
        self.checks.append(dict(name=name, passed=bool(condition), **redact(details)))
        print(json.dumps(dict(check=name, passed=bool(condition)), ensure_ascii=False), flush=True)
        assert condition, self.checks[-1]

    async def call(self, tool: str, args: dict | None = None, *, allow_error: bool = False) -> dict:
        args = args or {}
        reply = await self.client.call_tool(tool, args, read_timeout_seconds=90)
        value = reply.structured_content
        self.transcript.write(json.dumps(redact(dict(tool=tool, args=args, response=value,
                                                     mcp_error=reply.is_error)), ensure_ascii=False) + "\n")
        self.transcript.flush()
        if reply.is_error or not isinstance(value, dict) or not value.get("ok"):
            if allow_error:
                return dict(error=value or {"message": str(reply.content)})
            raise AssertionError(redact(dict(tool=tool, response=value, content=str(reply.content))))
        return value["result"]

    def update(self, snapshot: dict) -> None:
        self.current = snapshot
        player = snapshot.get("player")
        if player:
            self.minimum_life = min(self.minimum_life, player["life"])
        if snapshot.get("level_instance_id") != self.level_id:
            self.level_id = snapshot.get("level_instance_id")
            self.memory.clear()
            self.visits.clear()
            self.blocked.clear()
        for cell in (snapshot.get("map") or {}).get("cells", []):
            if cell.get("known"):
                self.memory[(cell["x"], cell["y"])] = cell
        (self.runtime.session / "observed.json").write_text(json.dumps(redact(snapshot), ensure_ascii=False, indent=2))

    async def connect(self, mode: str = "control") -> dict:
        self.connection = await self.call("tome.connect", dict(mode=mode))
        if self.connection.get("snapshot"):
            self.update(self.connection["snapshot"])
        return self.connection

    async def observe(self) -> dict:
        snapshot = await self.call("tome.observe", dict(session_id=self.connection["session_id"], radius=12,
                                                         events_after=self.event_cursor))
        page = snapshot
        for _ in range(32):
            events = page.get("events", {})
            if events.get("gap"):
                self.event_gaps.append(dict(after=self.event_cursor, oldest=events.get("oldest_cursor")))
            self.event_entries.extend(events.get("entries", []))
            self.event_cursor = events.get("cursor", self.event_cursor)
            if not events.get("has_more"):
                break
            page = await self.call("tome.observe", dict(session_id=self.connection["session_id"], include_map=False,
                                                         events_after=self.event_cursor))
        else:
            raise AssertionError("Visible log pagination did not finish")
        self.update(snapshot)
        return snapshot

    async def act(self, action: dict, reason: str, before: dict | None = None) -> dict:
        before = before or await self.observe()
        assert before["phase"] == "ready", compact(before)
        if before["control"] != "remote":
            await self.connect()
            before = await self.observe()
        self.counter += 1
        args = dict(session_id=self.connection["session_id"], control_token=self.connection["control_token"],
                    command_id=f"campaign-{self.counter:05d}", expected_revision=before["revision"],
                    action=action, wait_ms=10000)
        self.decisions.write(json.dumps(dict(command_id=args["command_id"], action=action, reason=reason,
                                            before=compact(before)), ensure_ascii=False) + "\n")
        self.decisions.flush()
        result = await self.call("tome.act", args)
        deadline = time.monotonic() + 90
        while result.get("status") not in FINAL:
            assert time.monotonic() < deadline, result
            await asyncio.sleep(0.05)
            result = await self.call("tome.status", dict(session_id=args["session_id"], command_id=args["command_id"]))
        if result.get("snapshot"):
            self.update(result["snapshot"])
        else:
            await self.observe()
        record = {k: v for k, v in result.items() if k != "snapshot"}
        record.update(action=action, before=compact(before), after=compact(self.current))
        self.commands.append(record)
        print(json.dumps(dict(command=args["command_id"], action=action, status=result["status"],
                              code=result.get("code"), life=self.current.get("player", {}).get("life"),
                              stop_reason=result.get("stop_reason")), ensure_ascii=False), flush=True)
        if action["type"] == "move" and self.current.get("player"):
            p, q = before["player"], self.current["player"]
            if (p["x"], p["y"]) == (q["x"], q["y"]) and not self.enemies(self.current):
                dx, dy = DIRECTIONS[action["direction"]]
                self.blocked.add((p["x"] + dx, p["y"] + dy))
            self.visits[(q["x"], q["y"])] += 1
        if action["type"] == "use_talent" and result["status"] == "completed":
            self.verify_talent(action["talent_id"], before, self.current, result)
        assert self.current.get("phase") not in {"terminal", "needs_input"}, compact(self.current)
        return dict(result, request=args)

    def talents(self, snapshot: dict) -> dict:
        return {t["id"]: t for t in snapshot.get("talents", [])}

    def ready_talent(self, snapshot: dict, tid: str) -> bool:
        talent = self.talents(snapshot).get(tid, {})
        return bool(talent.get("supported") and talent.get("cooldown") == 0)

    def verify_talent(self, tid: str, before: dict, after: dict, command: dict) -> None:
        if tid in self.successful_talents:
            return
        old = self.talents(before)[tid]
        new = self.talents(after)[tid]
        self.check(old["cooldown"] == 0 and new["cooldown"] > 0, "native_talent_cooldown_" + tid)
        p, q = before["player"], after["player"]
        if tid in {STUN, SHOUT}:
            self.check(q["resources"]["stamina"]["value"] < p["resources"]["stamina"]["value"]
                       and command["energy_spent"] > 0, "native_talent_stamina_energy_" + tid)
        if tid == HEAL:
            self.check(q["life"] > p["life"] and command["energy_spent"] == 0
                       and before["world_tick"] == after["world_tick"], "native_healing_infusion_heals_without_turn")
        if tid == REGEN:
            self.check(command["energy_spent"] > 0 and "EFF_REGENERATION" in {e["id"] for e in q.get("effects", [])}
                       and q.get("life_regen", 0) > p.get("life_regen", 0), "native_regeneration_infusion_effect_and_energy")
        if tid == WILD:
            self.check(command["energy_spent"] == 0 and before["world_tick"] == after["world_tick"]
                       and "EFF_PAIN_SUPPRESSION" in {e["id"] for e in q.get("effects", [])},
                       "native_wild_infusion_effect_without_turn")
        self.successful_talents.add(tid)

    @staticmethod
    def enemies(snapshot: dict) -> list[dict]:
        player = snapshot["player"]
        enemies = []
        for actor in snapshot.get("actors", []):
            reaction = actor.get("reaction")
            hostile = reaction < 0 if isinstance(reaction, (int, float)) else actor.get("faction") == "enemies"
            if hostile:
                enemies.append(actor)
        return sorted(enemies, key=lambda actor: (distance(player, actor), actor.get("life", 0), actor["id"]))

    def walkable(self, xy: tuple[int, int]) -> bool:
        cell = self.memory.get(xy)
        return bool(cell and xy not in self.blocked and cell.get("blocked") is not True
                    and cell.get("char") not in {"#", "?", " "})

    def route(self, snapshot: dict, target: dict | None = None) -> int | None:
        p = snapshot["player"]
        origin = p["x"], p["y"]
        occupied = {(a["x"], a["y"]) for a in snapshot.get("actors", [])}
        queue = deque([origin])
        first = {origin: None}
        lengths = {origin: 0}
        candidates = []
        while queue:
            xy = queue.popleft()
            if xy != origin:
                if target and max(abs(xy[0] - target["x"]), abs(xy[1] - target["y"])) == 1:
                    return first[xy]
                unknown = sum((xy[0] + dx, xy[1] + dy) not in self.memory for dx, dy in DIRECTIONS.values())
                if not target and (unknown or self.visits[xy] == 0):
                    score = lengths[xy] + self.visits[xy] * 8 - min(unknown, 3) * 2
                    candidates.append((score, lengths[xy], xy, first[xy]))
            for direction, (dx, dy) in DIRECTIONS.items():
                nxt = xy[0] + dx, xy[1] + dy
                if nxt in first or nxt in occupied or not self.walkable(nxt):
                    continue
                first[nxt] = direction if xy == origin else first[xy]
                lengths[nxt] = lengths[xy] + 1
                queue.append(nxt)
        return min(candidates)[-1] if candidates else None

    async def preflight(self) -> None:
        tools = await self.client.list_tools()
        self.check({"tome.connect", "tome.observe", "tome.act", "tome.status"} <= {t.name for t in tools.tools},
                   "official_mcp_client_initialized")
        await self.connect("observe")
        initial = await self.observe()
        self.check(initial["phase"] == "ready" and initial["player"]["name"] == "MCP_campaign-play-01",
                   "recorded_ordinary_character_loaded")
        self.check((initial["player"]["x"], initial["player"]["y"]) == (64, 18)
                   and initial["player"]["max_life"] == 132 and initial["player"]["life"] == 132,
                   "original_exit_position_and_unmodified_life")
        self.check(REQUIRED_TALENTS <= self.talents(initial).keys(), "original_birth_talents_present")
        self.check(initial["player"].get("level") == 1 and initial["player"].get("exp", -1) >= 0
                   and [initial["player"].get(k) for k in ("unused_stats", "unused_talents", "unused_generics", "unused_talents_types")]
                   == [3, 3, 2, 1], "original_unspent_birth_progression_is_observable")
        self.check({item["name"] for item in initial["player"].get("equipment", [])}
                   >= {"iron greatsword", "brass lantern", "iron mail armour"}, "original_equipment_is_observable")
        self.check(initial.get("battle_companion", {}).get("actions") == 0
                   and initial.get("battle_companion", {}).get("state") == "idle", "battle_companion_stays_idle")
        await asyncio.sleep(0.25)
        second = await self.observe()
        self.check(second["world_tick"] == initial["world_tick"] and second["player"] == initial["player"],
                   "read_only_campaign_observation_preserves_character")
        brief = await self.call("tome.observe", dict(session_id=self.connection["session_id"], include_map=False,
                                                     events_after=self.event_cursor))
        self.check(brief.get("map_omitted") is True and brief.get("map") is None
                   and brief["world_tick"] == second["world_tick"] and brief["player"] == second["player"],
                   "compact_observe_omits_map_without_native_changes")
        self.check(not brief["events"]["entries"] and brief["events"]["cursor"] == self.event_cursor,
                   "visible_log_cursor_replay_has_no_duplicate_events")

    async def cross_level(self) -> None:
        await self.connect()
        before = await self.observe()
        self.check(all(self.talents(before)[tid].get("supported") for tid in REQUIRED_TALENTS),
                   "all_five_original_core_talents_supported")
        self.check(before.get("scene", {}).get("zone_id") == "trollmire"
                   and before["scene"]["level"] == 1, "scene_identifies_trollmire_one")
        result = await self.act({"type": "change_level"}, "Use the recorded ordinary staircase through MCP.", before)
        self.check(result["status"] == "completed" and result.get("code") == "level_changed"
                   and self.current["level_instance_id"] != before["level_instance_id"]
                   and self.current.get("scene", {}).get("zone_id") == "trollmire"
                   and self.current["scene"]["level"] == 2, "mcp_change_level_enters_actual_trollmire_two")
        self.check(self.current["control"] == "manual", "level_change_revokes_control")
        await self.connect()
        result = await self.act({"type": "wait"}, "Verify a normal native action after the real level transition.")
        self.check(result["status"] == "completed" and result["energy_spent"] > 0
                   and self.current["scene"]["level"] == 2, "ordinary_action_after_level_change")

    async def rest(self, before: dict) -> None:
        maximum = 5 if not self.rest_bound_tested else 150
        result = await self.act({"type": "rest", "max_turns": maximum}, "Recover through bounded native rest.", before)
        self.check(result.get("turns_executed", -1) >= 0 and result["turns_executed"] <= maximum,
                   "native_rest_respects_requested_bound", turns=result.get("turns_executed"), maximum=maximum,
                   reason=result.get("stop_reason"))
        if result.get("stop_reason") == "max_turns":
            self.check(result["turns_executed"] == maximum, "native_rest_reports_exact_bound")
            self.rest_bound_tested = True
        if result["turns_executed"] > 0 and not self.rest_tested:
            self.check(self.current["world_tick"] > before["world_tick"], "bounded_rest_advances_original_world")
            after_tick = self.current["world_tick"]
            duplicate = await self.call("tome.act", result["request"])
            observed = await self.observe()
            self.check(duplicate["command_id"] == result["command_id"] and observed["world_tick"] == after_tick,
                       "bounded_rest_duplicate_does_not_repeat_turns")
            self.rest_tested = True

    async def rest_with_hostile(self, before: dict) -> None:
        actor = self.enemies(before)[0]
        inspected = await self.call("tome.inspect", dict(session_id=self.connection["session_id"], kind="actor", id=actor["id"]))
        self.check(inspected.get("id") == actor["id"] and isinstance(inspected.get("level"), (int, float))
                   and isinstance(inspected.get("rank"), (int, float)) and "speed" in inspected
                   and "effects" in inspected and "base_combat" in inspected and "base_resists" in inspected,
                   "naturally_visible_hostile_has_native_inspect_details", actor=inspected)
        result = await self.act({"type": "rest", "max_turns": 5},
                                "Verify native rest refuses a naturally observed hostile.", before)
        self.check(result["status"] == "completed" and result.get("turns_executed") == 0
                   and result.get("stop_reason") == "native_stopped" and bool(result.get("native_message"))
                   and self.current["world_tick"] == before["world_tick"],
                   "native_rest_with_visible_hostile_stops_without_turn", native_message=result.get("native_message"))
        self.rest_enemy_tested = True

    async def play(self, maximum: int) -> None:
        for _ in range(maximum):
            snapshot = await self.observe()
            assert snapshot["phase"] == "ready", compact(snapshot)
            p = snapshot["player"]
            assert p["life"] > (p.get("die_at") or 0), "The ordinary campaign character died"
            enemies = self.enemies(snapshot)
            missing = REQUIRED_TALENTS - self.successful_talents
            recovered = (p["life"] >= p["max_life"] - 0.01
                         and p["resources"]["stamina"]["value"] >= p["resources"]["stamina"]["max"] - 0.01
                         and all(self.talents(snapshot)[tid]["cooldown"] == 0 for tid in REQUIRED_TALENTS))
            if not missing and self.rest_tested and self.rest_bound_tested and self.rest_enemy_tested and not enemies and recovered:
                self.check(snapshot.get("battle_companion", {}).get("actions") == 0,
                           "campaign_combat_remains_mcp_owned")
                event_text = "\n".join(event.get("text", "") for event in self.event_entries if event.get("op") in {"append", "update"})
                cursors = [event["cursor"] for event in self.event_entries]
                self.check(not self.event_gaps and cursors == sorted(set(cursors))
                           and " killed " in event_text and " damage." in event_text,
                           "incremental_player_visible_log_contains_actual_combat", events=len(cursors))
                self.check(True, "ordinary_campaign_combat_recovery_loop_complete", actions=self.counter,
                           minimum_life=self.minimum_life, final=compact(snapshot))
                return
            hurt = p["max_life"] - p["life"]
            nearest = enemies[0] if enemies else None
            nearby = distance(p, nearest) if nearest else 1000
            if nearest and not self.rest_enemy_tested:
                await self.rest_with_hostile(snapshot)
                continue
            if hurt > 5 and self.ready_talent(snapshot, HEAL) and (HEAL in missing or p["life"] < p["max_life"] * .75):
                await self.act(dict(type="use_talent", talent_id=HEAL), "Use the original healing infusion after natural damage.", snapshot)
                continue
            if nearest and nearby <= 2 and self.ready_talent(snapshot, WILD) and (WILD in missing or p.get("effects")):
                await self.act(dict(type="use_talent", talent_id=WILD), "Use native wild infusion protection/cleansing in combat.", snapshot)
                continue
            if hurt > 2 and self.ready_talent(snapshot, REGEN) and (REGEN in missing or p["life"] < p["max_life"] * .85):
                await self.act(dict(type="use_talent", talent_id=REGEN), "Apply the original regeneration infusion after natural damage.", snapshot)
                continue
            stamina = p["resources"]["stamina"]["value"]
            if nearest:
                if nearby <= 3 and stamina >= 40 and self.ready_talent(snapshot, SHOUT) and SHOUT in missing:
                    await self.act(dict(type="use_talent", talent_id=SHOUT, target_id=nearest["id"]),
                                   "Aim the native Warshout cone at the observed enemy.", snapshot)
                    continue
                if nearby <= 1:
                    self.encounter_waits = 0
                    if stamina >= 15 and self.ready_talent(snapshot, STUN):
                        await self.act(dict(type="use_talent", talent_id=STUN, target_id=nearest["id"]),
                                       "Use native Stunning Blow against an adjacent enemy.", snapshot)
                    else:
                        await self.act(dict(type="attack", target_id=nearest["id"]), "Attack the adjacent observed hostile.", snapshot)
                    continue
                self.encounter_waits += 1
                if self.encounter_waits <= 5:
                    await self.act(dict(type="wait"), "Let the observed enemy approach without entering more terrain.", snapshot)
                else:
                    direction = self.route(snapshot, nearest)
                    assert direction, "No known route to the visible enemy"
                    await self.act(dict(type="move", direction=direction), "Approach an observed stationary enemy over known terrain.", snapshot)
                continue
            self.encounter_waits = 0
            if not recovered:
                await self.rest(snapshot)
                continue
            direction = self.route(snapshot)
            assert direction, "No known walkable frontier remains in the observed map"
            await self.act(dict(type="move", direction=direction), "Explore a frontier using only MCP-known walkable terrain.", snapshot)
        raise AssertionError(dict(message="Campaign acceptance action bound reached", missing=sorted(REQUIRED_TALENTS - self.successful_talents),
                                  rest_tested=self.rest_tested, rest_enemy_tested=self.rest_enemy_tested,
                                  rest_bound_tested=self.rest_bound_tested, actions=self.counter))

    async def stop(self) -> None:
        if self.connection and self.connection.get("control_token"):
            await self.call("tome.stop", dict(session_id=self.connection["session_id"],
                                             control_token=self.connection["control_token"]), allow_error=True)

    def close(self) -> None:
        self.transcript.close()
        self.decisions.close()
        (self.runtime.session / "visible-log-events.jsonl").write_text(
            "".join(json.dumps(event, ensure_ascii=False) + "\n" for event in self.event_entries))


async def main(args) -> int:
    runtime = CampaignRuntime(args.session, args.source_session,
                              args.addon_archive.absolute() if args.addon_archive else None)
    campaign = None
    error = None
    started = time.monotonic()
    try:
        runtime.start()
        deadline = time.monotonic() + 60
        while "[MCP Bridge] Listening" not in (runtime.session / "game.log").read_text(errors="replace"):
            assert runtime.process.poll() is None, "Native game exited during ordinary save load"
            assert time.monotonic() < deadline, "MCP listener did not start"
            await asyncio.sleep(.05)
        await asyncio.sleep(.3)
        params = StdioServerParameters(command=sys.executable, args=["-m", "tome_mcp"], env={**os.environ,
            "PYTHONPATH": str(runtime.server_source),
            "TOME_MCP_PORT": str(runtime.port), "TOME_MCP_TOKEN": runtime.token})
        async with Client(params) as client:
            campaign = Campaign(runtime, client)
            await campaign.preflight()
            if not args.preflight_only:
                await campaign.cross_level()
                await campaign.play(args.max_actions)
            await campaign.stop()
    except Exception:
        error = traceback.format_exc()
        print(error, flush=True)
    finally:
        if campaign:
            campaign.close()
        runtime.close()
    content = (runtime.session / "game.log").read_text(errors="replace")
    unchanged = runtime.source_unchanged()
    lua_error = "Lua Error:" in content or "[COROUTINE] error" in content
    combat = [line for line in content.splitlines() if line.startswith("[LOG]") and
              any(word in line.lower() for word in ("damage", " killed ", "disarmed", "infusion", "stunned"))]
    (runtime.session / "player-visible-combat.log").write_text("\n".join(combat) + "\n")
    kills = [re.sub(r"#.*?#", "", line.split(" killed ", 1)[1]).split("!", 1)[0]
             for line in combat if " killed " in line and "MCP_campaign-play-01" in line]
    result = dict(passed=error is None and unchanged and not lua_error, error=error,
                  original_save_unchanged=unchanged, lua_error=lua_error,
                  normal_campaign=True, cheat=False, gameplay_fixture=False,
                  elapsed_seconds=time.monotonic()-started, preflight_only=args.preflight_only,
                  checks=campaign.checks if campaign else [], commands=campaign.commands if campaign else [],
                  successful_talents=sorted(campaign.successful_talents) if campaign else [],
                  visible_log_events=len(campaign.event_entries) if campaign else 0,
                  visible_log_gaps=campaign.event_gaps if campaign else [],
                  submitted_actions=campaign.counter if campaign else 0, native_log_kills=kills,
                  minimum_observed_life=campaign.minimum_life if campaign and campaign.current else None,
                  last_snapshot=redact(campaign.current) if campaign else None)
    (runtime.session / "result.json").write_text(json.dumps(redact(result), ensure_ascii=False, indent=2))
    print(json.dumps(dict(passed=result["passed"], checks=len(result["checks"]), actions=result["submitted_actions"],
                          evidence=str(runtime.session)), ensure_ascii=False), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session")
    parser.add_argument("--source-session", type=Path, default=DEFAULT_SESSION)
    parser.add_argument("--addon-archive", type=Path)
    parser.add_argument("--max-actions", type=int, default=300)
    parser.add_argument("--preflight-only", action="store_true")
    raise SystemExit(asyncio.run(main(parser.parse_args())))
