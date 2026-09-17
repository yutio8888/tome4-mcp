#!/usr/bin/env bash
set -eu
task_root=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$task_root"
if command -v luajit >/dev/null 2>&1; then
    task_lua=luajit
    # Match game/loader/pre-init.lua. The native engine selects level 2.
    task_lua_options=(-O2)
else
    task_lua=lua
    task_lua_options=()
fi
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_json.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_ledger.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_observation_views.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_transport.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_actions.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_talent_query.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_query_purity.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_resource_filter.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_journal.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_observer.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_level_map.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_actor_combat.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_progression.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_items.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_tasks.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_invocations.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_policy.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_pilots.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_friendly_fire.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_effect_manifest.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_effect_manifest_drift.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_effect_footprint.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_effect_risk.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_guard.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_controller.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_catalog.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_snapshot.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_service.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_ab.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_assistant.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_execution.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_host.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_io.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_auto_combat_editor_model.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_native_activity.lua
if [ -f game/addons/tome-mcp-bridge/tests/test_runtime.lua ]; then
    "$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_runtime.lua
fi

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_interactive_runtime.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_chat.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_native_compatibility.lua
