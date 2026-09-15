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
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_transport.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_actions.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_talent_query.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_query_purity.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_journal.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_observer.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_progression.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_items.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_tasks.lua
"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_invocations.lua
if [ -f game/addons/tome-mcp-bridge/tests/test_runtime.lua ]; then
    "$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_runtime.lua
fi

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_interactive_runtime.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_chat.lua

"$task_lua" "${task_lua_options[@]}" game/addons/tome-mcp-bridge/tests/test_native_compatibility.lua
