#!/usr/bin/env bash
set -eu
# Resolve the addon dir from this script's own location (tests/..) so an
# alternate worktree tests ITS OWN code. TOME_MCP_ADDON_DIR (absolute or
# relative) is an explicit override; the enclosing checkout root is still
# where game/ core sources are read from.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
addon_dir=${TOME_MCP_ADDON_DIR:-$(cd "$script_dir/.." && pwd)}
if [ ! -d "$addon_dir" ]; then
    echo "tests/run.sh: no such addon dir: $addon_dir" >&2
    exit 2
fi
addon_dir=$(cd "$addon_dir" && pwd)
game_root=$(cd "$addon_dir/../../.." && pwd)
cd "$game_root"
echo "tests/run.sh: addon_dir=$addon_dir game_root=$game_root"
# One mandatory entry point: structural gates, tool regressions, Lua, Python,
# and all generators. No optional/skip path for missing checks or dependencies.
export PYTHONDONTWRITEBYTECODE=1
if [ -n "${TOME_MCP_PYTHON:-}" ]; then
    task_python=$TOME_MCP_PYTHON
elif [ -x "$addon_dir/server/.venv/bin/python" ]; then
    task_python="$addon_dir/server/.venv/bin/python"
else
    task_python=python3
fi
"$task_python" "$addon_dir/tools/check_boundary_rules.py" --check --root "$addon_dir"
"$task_python" "$addon_dir/tests/test_boundary_rules.py" -v
"$task_python" "$addon_dir/tests/test_validation_manifest.py" -v
"$task_python" -c 'import mcp' || {
    echo "tests/run.sh: MCP Python dependency missing; set TOME_MCP_PYTHON to the server environment" >&2
    exit 1
}

if command -v luajit >/dev/null 2>&1; then
    task_lua=luajit
    # Match game/loader/pre-init.lua. The native engine selects level 2.
    task_lua_options=(-O2)
else
    task_lua=lua
    task_lua_options=()
fi
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_json.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_ledger.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_observation_views.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_transport.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_actions.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_talent_query.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_query_purity.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_resource_filter.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_journal.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_observer.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_level_map.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_actor_combat.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_progression.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_items.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_tasks.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_invocations.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_policy.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_pilots.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_friendly_fire.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_effect_manifest.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_effect_manifest_drift.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_effect_footprint.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_effect_risk.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_guard.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_movement.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_movement_factory.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_sequence.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_controller.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_catalog.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_snapshot.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_service.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_ab.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_assistant.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_policy_bytes.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_execution.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_host.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_io.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_editor_model.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_native_activity.lua"
"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_runtime.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_interactive_runtime.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_chat.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_native_compatibility.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_sysfix.lua"
PYTHONPATH="$addon_dir/server/src${PYTHONPATH:+:$PYTHONPATH}" "$task_python" -m unittest discover -s "$addon_dir/server/tests" -v
"$task_python" "$addon_dir/tools/generate_native_seams.py" --check --game-root "$game_root"
"$task_python" "$addon_dir/tools/generate_effect_manifest.py" --check
"$task_python" "$addon_dir/tools/generate_protocol.py" --check
