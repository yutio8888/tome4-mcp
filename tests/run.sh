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

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_groups.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_controller.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_catalog.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_snapshot.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_service.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_ab.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_assistant.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_execution.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_host.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_io.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_auto_combat_editor_model.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_native_activity.lua"
if [ -f "$addon_dir/tests/test_runtime.lua" ]; then
    "$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_runtime.lua"
fi

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_interactive_runtime.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_chat.lua"

"$task_lua" "${task_lua_options[@]}" "$addon_dir/tests/test_native_compatibility.lua"
