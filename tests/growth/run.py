#!/usr/bin/env python3
"""Ordinary Lv3 growth/item acceptance, starting from the recorded continuation."""
from __future__ import annotations

import argparse
import asyncio
from collections import deque
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import sys
import time
import traceback

from mcp import Client, StdioServerParameters

CAMPAIGN = Path(__file__).resolve().parents[1] / "campaign"
sys.path.insert(0, str(CAMPAIGN))
from runtime import CampaignRuntime, CONTINUATION_SESSION, hashes, native

spec = importlib.util.spec_from_file_location("campaign_driver", CAMPAIGN / "run.py")
campaign_driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(campaign_driver)


class Growth(campaign_driver.Campaign):
    @staticmethod
    def talent_rows(progression: dict) -> dict:
        return {talent["id"]: talent for category in progression["categories"] for talent in category["talents"]}

    @staticmethod
    def category_rows(progression: dict) -> dict:
        return {category["id"]: category for category in progression["categories"]}

    async def progression(self) -> dict:
        result = await self.call("tome.inspect", dict(session_id=self.connection["session_id"], kind="progression", id="player"))
        (self.runtime.session / "progression.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        return result

    async def submit(self, action: dict, reason: str) -> dict:
        before = await self.observe()
        assert before["phase"] == "ready", campaign_driver.compact(before)
        if before["control_source"] != "remote":
            await self.connect()
            before = await self.observe()
        self.counter += 1
        args = dict(session_id=self.connection["session_id"], control_token=self.connection["control_token"],
                    command_id=f"growth-{self.counter:05d}", expected_revision=before["revision"], action=action, wait_ms=10000)
        self.decisions.write(json.dumps(dict(command_id=args["command_id"], action=action, reason=reason,
                                            before=campaign_driver.compact(before)), ensure_ascii=False) + "\n")
        self.decisions.flush()
        result = await self.call("tome.act", args, allow_error=True)
        if "error" in result:
            error = result["error"].get("error", result["error"])
            result = dict(status="rejected", code=error.get("code"), command_id=args["command_id"], error=result["error"])
        else:
            deadline = time.monotonic() + 90
            while result.get("status") not in campaign_driver.FINAL:
                assert time.monotonic() < deadline, result
                await asyncio.sleep(.05)
                result = await self.call("tome.status", dict(session_id=args["session_id"], command_id=args["command_id"]))
        after = await self.observe()
        record = {key: value for key, value in result.items() if key != "snapshot"}
        record.update(action=action, before=campaign_driver.compact(before), after=campaign_driver.compact(after))
        self.commands.append(record)
        print(json.dumps(dict(command=args["command_id"], action=action, status=result["status"], code=result.get("code")),
                         ensure_ascii=False), flush=True)
        assert after["phase"] == "ready", campaign_driver.compact(after)
        return dict(result, request=args, before=before, after=after)

    async def rejected(self, action: dict, name: str, codes: set[str] | None = None) -> dict:
        result = await self.submit(action, name)
        self.check(result["status"] in {"rejected", "failed"} and (not codes or result.get("code") in codes)
                   and result["before"]["world_tick"] == result["after"]["world_tick"]
                   and result["before"]["player"] == result["after"]["player"]
                   and result.get("energy_spent", 0) == 0, name, code=result.get("code"))
        return result

    async def duplicate(self, result: dict, name: str) -> None:
        before = await self.observe()
        progression_before = await self.progression()
        replay = await self.call("tome.act", result["request"])
        after = await self.observe()
        progression_after = await self.progression()
        self.check(replay["command_id"] == result["command_id"] and replay["status"] == result["status"]
                   and before["world_tick"] == after["world_tick"] and before["player"] == after["player"]
                   and progression_before == progression_after, name)

    async def preflight(self) -> None:
        tools = await self.client.list_tools()
        self.check({"tome.connect", "tome.observe", "tome.inspect", "tome.act", "tome.status"}
                   <= {tool.name for tool in tools.tools}, "official_mcp_client_initialized")
        await self.connect("observe")
        initial = await self.observe()
        reference = self.runtime.source_record["expected_state"]
        player, expected = initial["player"], reference["player"]
        self.check(initial["phase"] == "ready" and player["name"] == expected["name"]
                   and player["level"] == 3, "recorded_level_three_character_loaded")
        self.check(initial["scene"] == reference["scene"]
                   and (player["x"], player["y"]) == (expected["x"], expected["y"]),
                   "recorded_trollmire_two_position_preserved")
        self.check(player["life"] == expected["life"] and player["max_life"] == expected["max_life"]
                   and player["resources"]["stamina"]["value"] == expected["stamina"]["value"],
                   "ordinary_level_three_life_and_stamina_preserved")
        self.check([player.get(key) for key in ("unused_stats", "unused_talents", "unused_generics", "unused_talents_types")]
                   == [9, 5, 4, 1] and player["stats"] == expected["stats"],
                   "natural_level_three_unspent_points_and_attributes_preserved")
        self.check({item["name"] for item in player["equipment"]} == {item["name"] for item in expected["equipment"]}
                   and campaign_driver.REQUIRED_TALENTS <= self.talents(initial).keys(),
                   "original_equipment_and_talents_preserved")
        self.check(initial.get("battle_companion", {}).get("state") == "idle"
                   and initial["battle_companion"].get("actions") == 0, "battle_companion_stays_idle")
        await asyncio.sleep(.2)
        second = await self.observe()
        self.check(second["world_tick"] == initial["world_tick"] and second["player"] == player,
                   "level_three_observation_does_not_advance_or_change_character")
        self.initial = initial

    async def inspect_candidate(self) -> None:
        before = await self.observe()
        progression = await self.call("tome.inspect", dict(session_id=self.connection["session_id"],
                                                           kind="progression", id="player"))
        items = []
        for item in before["player"].get("inventory", []) + before["player"].get("equipment", []) + before.get("ground", {}).get("items", []):
            details = await self.call("tome.inspect", dict(session_id=self.connection["session_id"],
                                                           kind="item", id=item["id"]))
            items.append(dict(observed=item, inspected=details))
        after = await self.observe()
        (self.runtime.session / "candidate-inspection.json").write_text(json.dumps(dict(
            progression=progression, ground=before.get("ground"), items=items,
            before=campaign_driver.compact(before), after=campaign_driver.compact(after)), ensure_ascii=False, indent=2))
        self.check([progression["points"][key] for key in ("stats", "class", "generic", "category")] == [9, 5, 4, 1]
                   and len(progression["stats"]) == 6 and bool(progression["categories"]),
                   "candidate_progression_inspection_exposes_original_pools_and_trees")
        self.check(before.get("ground", {}).get("pickup_scope") == "current_tile_only"
                   and len(items) >= 3, "candidate_owned_items_and_ground_are_inspectable")
        self.check(after["world_tick"] == before["world_tick"] and after["player"] == before["player"],
                   "candidate_progression_and_item_inspection_are_read_only")

    async def exercise(self) -> None:
        await self.connect()
        await self.allocate_growth()
        await self.exercise_items()
        await self.save_native()

    async def allocate_growth(self) -> None:
        original = await self.progression()
        (self.runtime.session / "growth-before.json").write_text(json.dumps(original, ensure_ascii=False, indent=2))
        await self.rejected(dict(type="learn_talent", talent_id="T_MCP_NONEXISTENT_GROWTH_TALENT"),
                            "unknown_talent_does_not_consume_points", {"talent_not_in_growth_tree"})
        await self.rejected(dict(type="learn_category", category_id="mcp/nonexistent-growth-category"),
                            "unknown_category_does_not_consume_points", {"category_not_in_growth_tree"})
        await self.rejected(dict(type="learn_talent", talent_id="T_DEATH_DANCE_ASSAULT"),
                            "talent_level_prerequisite_is_enforced", {"talent_level_requirement"})
        await self.rejected(dict(type="learn_talent", talent_id="T_ARMOUR_TRAINING"),
                            "talent_stat_prerequisite_is_enforced", {"talent_stat_requirement"})
        await self.rejected(dict(type="learn_category", category_id="technique/bloodthirst"),
                            "category_level_prerequisite_is_enforced", {"category_level_requirement"})
        for index, stat in enumerate(["str"] * 5 + ["con"] * 4):
            before = await self.progression()
            stat_before = next(entry for entry in before["stats"] if entry["stat"] == stat)
            self.check(stat_before["readiness"] == "available", "observed_stat_allocation_is_available", stat=stat)
            result = await self.submit(dict(type="spend_stat", stat=stat), "Spend one real earned attribute point.")
            after = await self.progression()
            stat_after = next(entry for entry in after["stats"] if entry["stat"] == stat)
            self.check(result["status"] == "completed" and after["points"]["stats"] == before["points"]["stats"] - 1
                       and stat_after["base"] == stat_before["base"] + 1
                       and result.get("points_spent") == 1 and result.get("point_pool") == "stats"
                       and result.get("previous_value") == stat_before["base"] and result.get("new_value") == stat_after["base"]
                       and result["before"]["world_tick"] == result["after"]["world_tick"]
                       and result.get("energy_spent") == 0, "native_single_attribute_point_is_applied", stat=stat)
            if index == 0:
                await self.duplicate(result, "duplicate_stat_command_does_not_spend_twice")
        await self.rejected(dict(type="spend_stat", stat="str"), "exhausted_stat_pool_rejects_another_point",
                            {"insufficient_stat_points"})
        plan = ["T_STUNNING_BLOW_ASSAULT", "T_RUSH", "T_WARSHOUT_BERSERKER", "T_STUNNING_BLOW_ASSAULT",
                "T_WARSHOUT_BERSERKER", "T_ARMOUR_TRAINING", "T_VITALITY", "T_VITALITY", "T_VITALITY"]
        replayed = set()
        for tid in plan:
            before = await self.progression()
            talent = self.talent_rows(before)[tid]
            self.check(talent["readiness"] == "available" and talent["supported"],
                       "observed_native_talent_allocation_is_available", talent_id=tid, observed=talent)
            pool = talent["cost"]["pool"]
            snapshot_before = await self.observe()
            prior_cooldown = self.talents(snapshot_before).get(tid, {}).get("cooldown", 0)
            result = await self.submit(dict(type="learn_talent", talent_id=tid), "Apply one native class or generic talent point.")
            after = await self.progression()
            self.check(result["status"] == "completed" and after["points"][pool] == before["points"][pool] - 1
                       and self.talent_rows(after)[tid]["raw_level"] == talent["raw_level"] + 1
                       and result.get("points_spent") == 1 and result.get("point_pool") == pool
                       and result.get("previous_value") == talent["raw_level"] and result.get("new_value") == talent["raw_level"] + 1
                       and result["before"]["world_tick"] == result["after"]["world_tick"]
                       and result.get("energy_spent") == 0, "native_talent_point_updates_level_and_correct_pool", talent_id=tid, pool=pool)
            if talent["raw_level"] > 0:
                self.check(self.talents(result["after"])[tid]["cooldown"] == prior_cooldown,
                           "existing_talent_upgrade_does_not_add_learning_cooldown", talent_id=tid)
            elif tid == "T_RUSH":
                self.check(self.talents(result["after"])[tid]["cooldown"] > 0,
                           "new_activated_talent_keeps_native_learning_cooldown")
            if pool not in replayed:
                await self.duplicate(result, "duplicate_" + pool + "_point_does_not_spend_twice")
                replayed.add(pool)
        await self.rejected(dict(type="learn_talent", talent_id="T_RUSH"), "exhausted_class_pool_rejects_another_point",
                            {"insufficient_class_points"})
        await self.rejected(dict(type="learn_talent", talent_id="T_VITALITY"), "exhausted_generic_pool_rejects_another_point",
                            {"insufficient_generic_points"})
        category_id = "cunning/dirty" if self.category_mode == "unlock" else "technique/2hweapon-assault"
        before = await self.progression()
        category = self.category_rows(before)[category_id]
        self.check(category["readiness"] == "available", "observed_category_allocation_is_available", category=category)
        result = await self.submit(dict(type="learn_category", category_id=category_id), "Apply the original Cornac category point.")
        after = await self.progression()
        changed = self.category_rows(after)[category_id]
        if self.category_mode == "unlock":
            expected = category["known"] is False and changed["known"] is True and changed["mastery_base"] == category["mastery_base"]
        else:
            expected = category["known"] is True and changed["known"] is True and math.isclose(changed["mastery_base"], category["mastery_base"] + .2)
        self.check(result["status"] == "completed" and after["points"]["category"] == before["points"]["category"] - 1 and expected
                   and result.get("points_spent") == 1 and result.get("point_pool") == "category"
                   and math.isclose(result.get("new_value", -1), changed["mastery_base"]),
                   "native_category_point_changes_expected_category", mode=self.category_mode)
        self.check({tid: row["raw_level"] for tid, row in self.talent_rows(before).items()}
                   == {tid: row["raw_level"] for tid, row in self.talent_rows(after).items()},
                   "category_allocation_preserves_raw_talent_levels")
        await self.duplicate(result, "duplicate_category_point_does_not_spend_twice")
        await self.rejected(dict(type="learn_category", category_id="technique/combat-techniques-active"),
                            "exhausted_category_pool_rejects_another_point", {"insufficient_category_points"})
        if self.category_mode == "mastery":
            await self.rejected(dict(type="learn_category", category_id=category_id), "category_mastery_cannot_be_improved_twice",
                                {"category_already_improved", "category_mastery_already_improved", "insufficient_category_points"})
        self.growth_final = await self.progression()
        (self.runtime.session / "growth-after.json").write_text(json.dumps(self.growth_final, ensure_ascii=False, indent=2))
        self.check(all(self.growth_final["points"][key] == 0 for key in ("stats", "class", "generic", "category")),
                   "all_four_earned_point_pools_are_exercised")

    async def exercise_items(self) -> None:
        snapshot = await self.observe()
        await self.rejected(dict(type="pickup", item_id="nonexistent-ground-item"),
                            "unknown_ground_item_is_rejected", {"item_not_visible_or_owned"})
        equipped = snapshot["player"]["equipment"][0]
        await self.rejected(dict(type="equip", item_id=equipped["id"]),
                            "equipping_an_already_worn_item_is_rejected", {"item_not_in_backpack"})
        backpack = snapshot["player"]["inventory"][0]
        await self.rejected(dict(type="unequip", item_id=backpack["id"]),
                            "unequipping_a_backpack_item_is_rejected", {"item_not_equipped"})
        ignored = set()
        target = None
        remote_pickup_tested = False
        for _ in range(self.max_search_actions):
            snapshot = await self.observe()
            player = snapshot["player"]
            enemies = self.enemies(snapshot)
            if enemies:
                await self.defend(snapshot, enemies[0])
                continue
            if player["life"] < player["max_life"] - .01:
                await self.act(dict(type="rest", max_turns=150), "Recover naturally before searching the cleared level.", snapshot)
                continue
            candidates = [item for item in snapshot.get("ground", {}).get("items", []) if item["id"] not in ignored]
            candidates.sort(key=lambda item: (not bool(item.get("equipment_slot")), campaign_driver.distance(player, item), item["id"]))
            if target:
                current = next((item for item in candidates if item["id"] == target["id"]), None)
                if current:
                    target = current
                elif (target["x"], target["y"]) == (player["x"], player["y"]):
                    target = None
            if not target and candidates:
                target = candidates[0]
                first_seen = dict(target)
            if target:
                if (target["x"], target["y"]) != (player["x"], player["y"]):
                    if not remote_pickup_tested and any(item["id"] == target["id"] for item in candidates):
                        await self.rejected(dict(type="pickup", item_id=target["id"]),
                                            "visible_distant_item_cannot_be_picked_up_remotely", {"item_not_underfoot"})
                        remote_pickup_tested = True
                        continue
                    direction = self.route_to_cell(snapshot, target["x"], target["y"])
                    if direction is None:
                        ignored.add(target["id"])
                        target = None
                        continue
                    await self.act(dict(type="move", direction=direction), "Approach a naturally observed ground item over known terrain.", snapshot)
                    continue
                details = await self.call("tome.inspect", dict(session_id=self.connection["session_id"], kind="item", id=target["id"]))
                if details.get("identified") is True and not details.get("equipment_slot"):
                    ignored.add(target["id"])
                    target = None
                    continue
                pickup = await self.submit(dict(type="pickup", item_id=target["id"]), "Pick up the actual natural floor item underfoot.")
                self.check(pickup["status"] == "completed", "natural_underfoot_item_is_picked_up", item=details)
                suffix = target["id"].rsplit(":object-", 1)[1]
                owned = next((item for item in pickup["after"]["player"]["inventory"] if item["id"].endswith(":object-" + suffix)), None)
                self.check(owned is not None and not any(item["id"] == target["id"] for item in pickup["after"].get("ground", {}).get("items", [])),
                           "pickup_moves_the_same_native_object_to_inventory")
                expected_energy = 0 if details.get("pile_size", 1) > 1 else 1000
                self.check(pickup.get("energy_spent") == expected_energy, "pickup_keeps_native_single_or_multiple_object_energy",
                           pile_size=details.get("pile_size"), expected_energy=expected_energy)
                await self.duplicate(pickup, "duplicate_pickup_does_not_repeat_transfer_or_energy")
                inspected = await self.call("tome.inspect", dict(session_id=self.connection["session_id"], kind="item", id=owned["id"]))
                equip = await self.submit(dict(type="equip", item_id=owned["id"]), "Wear the naturally acquired ordinary item using native requirements.")
                if equip["status"] != "completed":
                    self.check(equip.get("code") in {"native_rejected", "unsupported_item_transfer", "unsupported_equipment_slot"},
                               "unusable_natural_equipment_returns_a_clear_native_rejection", item=inspected, code=equip.get("code"))
                    ignored.add(target["id"])
                    target = None
                    continue
                worn = next((item for item in equip["after"]["player"]["equipment"] if item["id"] == owned["id"]), None)
                self.check(worn is not None and equip.get("energy_spent") == 1000
                           and equip["after"]["world_tick"] > equip["before"]["world_tick"],
                           "natural_item_is_equipped_with_native_turn_cost", item=worn)
                await self.duplicate(equip, "duplicate_equip_does_not_repeat_transfer_or_energy")
                unequip = await self.submit(dict(type="unequip", item_id=owned["id"]), "Remove the naturally acquired equipment through native inventory code.")
                self.check(unequip["status"] == "completed" and unequip.get("energy_spent") == 1000
                           and any(item["id"] == owned["id"] for item in unequip["after"]["player"]["inventory"])
                           and not any(item["id"] == owned["id"] for item in unequip["after"]["player"]["equipment"]),
                           "natural_equipment_returns_to_inventory_with_native_turn_cost")
                await self.duplicate(unequip, "duplicate_unequip_does_not_repeat_transfer_or_energy")
                rewear = await self.submit(dict(type="equip", item_id=owned["id"]), "Leave the natural item equipped for the persistence check.")
                self.check(rewear["status"] == "completed" and any(item["id"] == owned["id"] for item in rewear["after"]["player"]["equipment"]),
                           "natural_item_is_reequipped_for_native_save")
                self.natural_item = dict(first_observed=first_seen, ground=details, picked_up=inspected,
                                         equipped=next(item for item in rewear["after"]["player"]["equipment"] if item["id"] == owned["id"]))
                (self.runtime.session / "natural-item.json").write_text(json.dumps(self.natural_item, ensure_ascii=False, indent=2))
                return
            direction = self.route(snapshot)
            assert direction, "No known walkable frontier remains while searching for natural equipment"
            await self.act(dict(type="move", direction=direction), "Search the current level using only MCP-known terrain and visible ground items.", snapshot)
        raise AssertionError("Natural item search action bound reached")

    def route_to_cell(self, snapshot: dict, x: int, y: int) -> int | None:
        origin = snapshot["player"]["x"], snapshot["player"]["y"]
        occupied = {(actor["x"], actor["y"]) for actor in snapshot["actors"]}
        queue = deque([origin])
        first = {origin: None}
        while queue:
            current = queue.popleft()
            if current == (x, y):
                return first[current]
            for direction, (dx, dy) in campaign_driver.DIRECTIONS.items():
                cell = current[0] + dx, current[1] + dy
                if cell in first or cell in occupied or not self.walkable(cell):
                    continue
                first[cell] = direction if current == origin else first[current]
                queue.append(cell)
        return None

    async def defend(self, snapshot: dict, enemy: dict) -> None:
        player = snapshot["player"]
        if player["life"] < player["max_life"] * .8 and self.ready_talent(snapshot, campaign_driver.HEAL):
            await self.act(dict(type="use_talent", talent_id=campaign_driver.HEAL), "Use the original infusion after naturally received damage.", snapshot)
        elif player["life"] < player["max_life"] * .9 and self.ready_talent(snapshot, campaign_driver.REGEN):
            await self.act(dict(type="use_talent", talent_id=campaign_driver.REGEN), "Use the original regeneration infusion for natural combat recovery.", snapshot)
        elif campaign_driver.distance(player, enemy) <= 1:
            if self.ready_talent(snapshot, campaign_driver.STUN) and player["resources"]["stamina"]["value"] >= 15:
                await self.act(dict(type="use_talent", talent_id=campaign_driver.STUN, target_id=enemy["id"]), "Defend against the naturally observed adjacent enemy.", snapshot)
            else:
                await self.act(dict(type="attack", target_id=enemy["id"]), "Attack the naturally observed adjacent enemy.", snapshot)
        else:
            await self.act(dict(type="wait"), "Let the observed hostile approach before further exploration.", snapshot)

    async def save_native(self) -> None:
        for _ in range(10):
            snapshot = await self.observe()
            enemies = self.enemies(snapshot)
            if enemies:
                await self.defend(snapshot, enemies[0])
                continue
            player = snapshot["player"]
            if player["life"] >= player["max_life"] - .01 and player["resources"]["stamina"]["value"] >= player["resources"]["stamina"]["max"] - .01:
                break
            await self.act(dict(type="rest", max_turns=150), "Finish ordinary recovery before the native save.", snapshot)
        else:
            raise AssertionError("Could not reach a safe native save boundary")
        before = await self.observe()
        progression = await self.progression()
        expected = self.persistence_state(before, progression)
        content_before = (self.runtime.session / "game.log").read_text(errors="replace")
        await self.stop()
        self.runtime.input.chord("Control_L", "s")
        deadline = time.monotonic() + 60
        while "Saving done." not in (self.runtime.session / "game.log").read_text(errors="replace")[len(content_before):]:
            assert self.runtime.process.poll() is None, "Game exited before finishing the native save"
            assert time.monotonic() < deadline, "Native Ctrl+S save did not finish"
            await asyncio.sleep(.05)
        await self.connect("observe")
        saved = await self.observe()
        self.saved_progression = await self.progression()
        self.saved_state = self.persistence_state(saved, self.saved_progression)
        self.saved_session_id = saved["session_id"]
        self.check(self.saved_state == expected and saved["world_tick"] == before["world_tick"],
                   "native_save_preserves_the_final_gameplay_state")
        save = self.runtime.home / ".t-engine/4.0/tome/save"
        self.saved_hashes = hashes(save)
        description = (save / "mcp_campaign_play_01/desc.lua").read_text()
        self.check("cheat = false" in description and "loadable = true" in description
                   and self.saved_hashes["mcp_campaign_play_01/game.teag"] != self.runtime.original_hashes["mcp_campaign_play_01/game.teag"],
                   "native_save_writes_a_new_loadable_non_cheat_game")
        (self.runtime.session / "saved-state.json").write_text(json.dumps(dict(state=self.saved_state,
            progression=self.saved_progression, snapshot=saved, save_sha256=self.saved_hashes), ensure_ascii=False, indent=2))

    @staticmethod
    def persistence_state(snapshot: dict, progression: dict) -> dict:
        player = snapshot["player"]
        items = [{key: value for key, value in item.items() if key != "id"}
                 for item in player["inventory"] + player["equipment"]]
        items.sort(key=lambda item: json.dumps(item, sort_keys=True))
        return dict(scene=snapshot["scene"], player={key: player[key] for key in
            ("name", "x", "y", "level", "exp", "life", "max_life", "stats", "unused_stats", "unused_talents", "unused_generics", "unused_talents_types")},
            points=progression["points"], stats=progression["stats"],
            categories=[{key: category[key] for key in ("id", "known", "mastery_base", "improvements_used")}
                        for category in progression["categories"]],
            talent_levels={talent["id"]: talent["raw_level"] for category in progression["categories"] for talent in category["talents"]},
            owned_items=items)

    @staticmethod
    def persistence_equal(before, after) -> bool:
        """Native saves may round floating scalars; discrete game state is exact."""
        if isinstance(before, dict) and isinstance(after, dict):
            return before.keys() == after.keys() and all(Growth.persistence_equal(value, after[key]) for key, value in before.items())
        if isinstance(before, list) and isinstance(after, list):
            return len(before) == len(after) and all(Growth.persistence_equal(a, b) for a, b in zip(before, after))
        if isinstance(before, (int, float)) and not isinstance(before, bool) and isinstance(after, (int, float)) and not isinstance(after, bool):
            if isinstance(before, float) or isinstance(after, float):
                return math.isclose(before, after, rel_tol=1e-12, abs_tol=1e-9)
        return before == after

    async def verify_reload(self, client: Client) -> None:
        (self.runtime.session / "visible-log-events-before-reload.jsonl").write_text(
            "".join(json.dumps(event, ensure_ascii=False) + "\n" for event in self.event_entries))
        self.client = client
        self.connection = None
        self.event_cursor = 0
        self.event_entries = []
        self.event_gaps = []
        await self.connect("observe")
        reloaded = await self.observe()
        progression = await self.progression()
        actual = self.persistence_state(reloaded, progression)
        (self.runtime.session / "reloaded-state.json").write_text(json.dumps(dict(state=actual, progression=progression,
            snapshot=reloaded), ensure_ascii=False, indent=2))
        self.check(reloaded["phase"] == "ready" and self.persistence_equal(actual, self.saved_state),
                   "new_native_save_reloads_identical_growth_and_item_state", floating_absolute_tolerance=1e-9)
        self.check(reloaded["session_id"] != self.saved_session_id, "reloaded_game_has_a_new_native_session")
        stale = await self.call("tome.observe", dict(session_id=self.saved_session_id), allow_error=True)
        stale_error = stale.get("error", {}).get("error", {})
        after_stale = await self.observe()
        self.check(stale_error.get("code") == "session_mismatch" and after_stale["world_tick"] == reloaded["world_tick"]
                   and after_stale["player"] == reloaded["player"], "previous_session_is_rejected_without_native_changes")
        self.check(hashes(self.runtime.session / "home/.t-engine/4.0/tome/save") == self.saved_hashes,
                   "reload_preserves_the_first_saved_test_copy")
        self.check(reloaded.get("battle_companion", {}).get("state") == "idle"
                   and reloaded["battle_companion"].get("actions") == 0,
                   "growth_item_and_reload_actions_remain_mcp_owned")


async def wait_listener(runtime: CampaignRuntime, log_name: str = "game.log") -> None:
    deadline = time.monotonic() + 60
    log = runtime.session / log_name
    while "[MCP Bridge] Listening" not in log.read_text(errors="replace"):
        assert runtime.process.poll() is None, "Native game exited during ordinary save load"
        assert time.monotonic() < deadline, "MCP listener did not start"
        await asyncio.sleep(.05)
    await asyncio.sleep(.3)


def parameters(runtime: CampaignRuntime) -> StdioServerParameters:
    return StdioServerParameters(command=sys.executable, args=["-m", "tome_mcp"], env={**os.environ,
        "PYTHONPATH": str(runtime.server_source), "TOME_MCP_PORT": str(runtime.port), "TOME_MCP_TOKEN": runtime.token})


async def main(args) -> int:
    runtime = CampaignRuntime(args.session, args.source_session,
                              args.addon_archive.absolute() if args.addon_archive else None,
                              source_record=args.source_record)
    metadata = json.loads((runtime.session / "input.json").read_text())
    frozen_driver = runtime.session / "harness-source/growth"
    frozen_driver.mkdir()
    for path in Path(__file__).parent.glob("*.py"):
        shutil.copy2(path, frozen_driver / path.name)
    metadata["growth_driver_sha256"] = {path.name: native.sha(path) for path in Path(__file__).parent.glob("*.py")}
    (runtime.session / "input.json").write_text(json.dumps(metadata, indent=2))
    run = None
    error = None
    started = time.monotonic()
    try:
        runtime.start()
        await wait_listener(runtime)
        async with Client(parameters(runtime)) as client:
            run = Growth(runtime, client)
            run.category_mode = args.category_mode
            run.max_search_actions = args.max_search_actions
            await run.preflight()
            if args.inspect_candidate:
                await run.inspect_candidate()
            if not args.preflight_only:
                await run.exercise()
            await run.stop()
        if not args.preflight_only:
            runtime.restart_from_saved_copy()
            await wait_listener(runtime, "reload.log")
            async with Client(parameters(runtime)) as reloaded_client:
                await run.verify_reload(reloaded_client)
                await run.stop()
    except Exception:
        error = traceback.format_exc()
        print(error, flush=True)
    finally:
        if run:
            run.close()
        runtime.close()
    content = "\n".join(path.read_text(errors="replace") for path in runtime.log_paths)
    unchanged = runtime.source_unchanged()
    lua_error = "Lua Error:" in content or "[COROUTINE] error" in content or "stack traceback:" in content
    result = dict(passed=error is None and unchanged and not lua_error, error=error,
                  preflight_only=args.preflight_only, source_record=runtime.source_record["id"],
                  normal_campaign=True, cheat=False, gameplay_fixture=False,
                  historical_sources_unchanged=runtime.historical_sources_unchanged(),
                  source_save_unchanged=unchanged, lua_error=lua_error,
                  elapsed_seconds=time.monotonic()-started, checks=run.checks if run else [],
                  submitted_actions=run.counter if run else 0, commands=run.commands if run else [],
                  category_mode=args.category_mode,
                  natural_item=getattr(run, "natural_item", None), saved_state=getattr(run, "saved_state", None),
                  last_snapshot=campaign_driver.redact(run.current) if run else None)
    (runtime.session / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(dict(passed=result["passed"], checks=len(result["checks"]), actions=result["submitted_actions"],
                          evidence=str(runtime.session)), ensure_ascii=False), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session")
    parser.add_argument("--source-session", type=Path, default=CONTINUATION_SESSION)
    parser.add_argument("--source-record")
    parser.add_argument("--addon-archive", type=Path)
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--inspect-candidate", action="store_true")
    parser.add_argument("--category-mode", choices=("unlock", "mastery"), default="unlock")
    parser.add_argument("--max-search-actions", type=int, default=300)
    raise SystemExit(asyncio.run(main(parser.parse_args())))
