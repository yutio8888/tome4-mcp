#!/usr/bin/env python3
"""Official MCP SDK client -> stdio server -> native game smoke test.

Run with the server's Python environment. TOME_MCP_* and PYTHONPATH are inherited
from the native acceptance runner. The server process owns its protocol stdout.
"""
import asyncio
import json
import os
import sys

from mcp import Client, StdioServerParameters


async def main() -> None:
    evidence = []

    def check(condition: bool, name: str, **details) -> None:
        evidence.append(dict(name=name, passed=bool(condition), **details))
        assert condition, evidence[-1]

    params = StdioServerParameters(command=sys.executable, args=["-m", "tome_mcp"],
                                   env={key: os.environ[key] for key in ("PYTHONPATH", "TOME_MCP_TOKEN", "TOME_MCP_PORT")})
    async with Client(params) as client:
        tools = await client.list_tools()
        names = {tool.name for tool in tools.tools}
        check(names == {"tome.connect", "tome.observe", "tome.inspect", "tome.list", "tome.act", "tome.status", "tome.stop", "tome.respond", "tome.dismiss"},
              "official_mcp_initialize_and_list_tools", tools=sorted(names))
        resource = await client.read_resource("tome://rules")
        check(bool(resource.contents), "official_mcp_rules_resource")

        async def call(name: str, args: dict | None = None) -> dict:
            reply = await client.call_tool(name, args or {})
            structured = reply.structured_content
            check(not reply.is_error and isinstance(structured, dict) and structured.get("ok"),
                  "mcp_call_" + name, error=structured.get("error") if isinstance(structured, dict) else None)
            return structured["result"]

        connection = await call("tome.connect")
        session = connection["session_id"]
        before = await call("tome.observe", dict(session_id=session))
        check(before["phase"] == "ready", "mcp_native_game_ready")
        await call("tome.inspect", dict(session_id=session, kind="talent", id="T_LIGHTNING"))
        if connection["capabilities"].get("progression_read"):
            tree = await call("tome.inspect", dict(session_id=session, kind="progression", id="player"))
            check(isinstance(tree.get("categories"), list), "mcp_native_progression_inspection")
            owned = before["player"].get("equipment", []) + before["player"].get("inventory", [])
            check(bool(owned), "mcp_native_item_inspection_has_original_equipment")
            item = await call("tome.inspect", dict(session_id=session, kind="item", id=owned[0]["id"]))
            check(item["id"] == owned[0]["id"] and item["name"] == owned[0]["name"], "mcp_native_owned_item_inspection")
            unchanged = await call("tome.observe", dict(session_id=session))
            check(unchanged["player"] == before["player"] and unchanged["world_tick"] == before["world_tick"]
                  and unchanged["revision"] == before["revision"], "mcp_native_growth_item_reads_preserve_state")
        args = dict(session_id=session, control_token=connection["control_token"], command_id=(before.get("history") or {}).get("next_command_id"),
                    expected_revision=before["revision"], action={"type": "wait"}, wait_ms=10000)
        action = await call("tome.act", args)
        check(action["status"] == "completed" and action["energy_spent"] > 0,
              "mcp_tcp_native_wait_completed", command_id=action["command_id"], energy_spent=action["energy_spent"])
        after = action["snapshot"]
        check(after["phase"] == "ready" and after["world_tick"] > before["world_tick"],
              "mcp_native_wait_returns_stable_snapshot", before_tick=before["world_tick"], after_tick=after["world_tick"])
        status = await call("tome.status", dict(session_id=session, command_id=action["command_id"]))
        check(status["status"] == "completed", "mcp_status_recovers_completed_command")
        duplicate = await call("tome.act", args)
        observed = await call("tome.observe", dict(session_id=session))
        check(duplicate["command_id"] == action["command_id"] and observed["world_tick"] == after["world_tick"],
              "mcp_duplicate_does_not_advance_game")
        stopped = await call("tome.stop", dict(session_id=session, control_token=connection["control_token"]))
        check(stopped["stopped"] and stopped["snapshot"]["control_source"] == "manual", "mcp_stop_returns_manual_control")
    print(json.dumps(dict(passed=True, checks=evidence)))


if __name__ == "__main__":
    asyncio.run(main())
