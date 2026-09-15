-- Test instrumentation only. Commands still arrive through production TCP.
local M = {ready=false, actions=0, enemy_acts=0}
local function encode(value)
    local t = type(value)
    if t == "nil" then return "null" end
    if t == "boolean" or t == "number" then return tostring(value) end
    if t == "string" then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
            return ('\\u%04x'):format(c:byte())
        end) .. '"'
    end
    assert(t == "table")
    local out = {}
    for key, entry in pairs(value) do out[#out+1] = encode(tostring(key)) .. ":" .. encode(entry) end
    return "{" .. table.concat(out, ",") .. "}"
end
function M.emit(record) print("[MCPProbe] " .. encode(record)) end
local function guard(fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then M.emit{kind="error", error=tostring(err)}; core.game.exit_engine() end
end
function M.state()
    local p = game.player
    local e, map = M.enemy, game.level and game.level.map
    local cache = e and p.can_see_cache and p.can_see_cache[e]
    cache = cache and cache['nil/nil']
    return {x=p.x, y=p.y, life=p.life, mana=p.mana, energy=p.energy.value,
        world_tick=game.turn, actions=M.actions, enemy_acts=M.enemy_acts,
        enemy_life=M.enemy and M.enemy.life, enemy_energy=M.enemy and M.enemy.energy.value, paused=game.paused,
        enemy_present=e and game.level.entities[e.uid]==e,
        enemy_x=e and e.x, enemy_y=e and e.y,
        enemy_seen=e and map and map.seens[e.x+e.y*map.w] and true or false,
        enemy_cached=cache and tostring(cache[1]) or "missing",
        lightning_cd=p.talents_cd[p.T_LIGHTNING] or 0,
        adrenaline_cd=p.talents_cd[p.T_ADRENALINE_SURGE] or 0,
        adrenaline_active=p:hasEffect(p.EFF_ADRENALINE_SURGE) and true or false}
end
function M.onFrame()
    if not M.ready then return end
    if not M.next_report or core.game.getTime() >= M.next_report then
        M.next_report = core.game.getTime() + 150
        local report = M.state(); report.kind = "state"; M.emit(report)
    end
end
function M.instrumentObserver()
    local Observer = require "mod.mcp_bridge.Observer"
    local readers={{Observer,'capture'},{Observer,'inspect'}}
    if __module_extra_info.mcp_probe_interactions then
        readers[#readers+1]={require('mod.mcp_bridge.Interactions'),'describe'}
        readers[#readers+1]={require('mod.mcp_bridge.NativeTasks'),'describe'}
    end
    for _, entry in ipairs(readers) do
        local owner,name=unpack(entry)
        local original = assert(owner[name])
        -- Keep this observation call path interpreted so the diagnostic call
        -- hook also sees nested native methods. Do not replace their identity.
        if jit then jit.off(original, true) end
        owner[name] = function(...)
            local before = M.state()
            local called, rng_originals, methods = {}, {}, {}
            local p = game.player
            for key, fn in pairs(rng) do
                if type(fn) == "function" then
                    rng_originals[key] = fn
                    rng[key] = function(...)
                        called["rng." .. key] = (called["rng." .. key] or 0) + 1
                        return fn(...)
                    end
                end
            end
            for _, key in ipairs{"canSee", "canSeeNoCache", "preUseTalent", "canLearnTalent",
                "getTalentReqDesc", "getTalentFullDescription"} do
                if type(p[key])=='function' then methods[p[key]] = key end
            end
            for _,inven in pairs(p.inven or {}) do
                for _,obj in ipairs(inven) do
                    for _,key in ipairs{'getName','isIdentified','tooltip'} do
                        if type(obj[key])=='function' then methods[obj[key]]='object.'..key end
                    end
                end
            end
            for _,talent in pairs(p.talents_def or {}) do
                if type(talent.info)=='function' then methods[talent.info]='talent.info' end
            end
            local old_hook, old_mask, old_count = debug.gethook()
            debug.sethook(function()
                local fn = debug.getinfo(2, "f").func
                if methods[fn] then called[methods[fn]] = (called[methods[fn]] or 0) + 1 end
            end, "c")
            local function pack(...) return {n=select("#", ...), ...} end
            local result = pack(pcall(original, ...))
            debug.sethook(old_hook, old_mask, old_count)
            for key, fn in pairs(rng_originals) do rng[key] = fn end
            if not result[1] then error(result[2]) end
            local after, same = M.state(), next(called) == nil
            for key, value in pairs(before) do if after[key] ~= value then same = false end end
            M.emit{kind="observation_check", method=name, passed=same, called=called}
            assert(same, "Observer invoked RNG, perception, talent precheck or changed native state")
            return unpack(result, 2, result.n)
        end
    end
end
function M.start()
    guard(function()
        local p = assert(game.player)
        assert(config.settings.cheat and p.__cheated and p.innate_player)
        assert(not game.creating_player and p.level == 1 and p.descriptor.subrace == "Cornac")
        M.emit{kind="birth_complete", new_character=true, uid=p.uid, name=p.name,
            subclass=p.descriptor.subclass, runtime=jit.version}
        game:changeLevel(1, "mcp-test", {direct_switch=true})
        p:move(3, 3, true)
        p:learnTalent(p.T_MANA_POOL, true, 1)
        p:learnTalent(p.T_LIGHTNING, true, 1)
        p:learnTalent(p.T_HEAL, true, 1)
        p:learnTalent(p.T_ADRENALINE_SURGE, true, 1)
        p.max_mana=300; p.mana=300; p.max_life=1000; p.life=500
        p.life_regen=0; p.mana_regen=0; p.changed=true
        local NPC = require "mod.class.NPC"
        local enemy = NPC.new{
            name="MCP target dummy", type="humanoid", subtype="human", display="d",
            color=colors.RED, faction="enemies", level_range={1,1},
            max_life=10000, life_rating=0, rank=2, size_category=3,
            ai="simple", ai_state={talent_in=0}, never_move=true,
            stats={str=10, dex=10, mag=10, con=10},
            combat={dam=1, atk=1, apr=0, dammod={str=1}},
            combat_armor=0, combat_def=0, infravision=10,
        }
        enemy:resolve(); enemy:resolve(nil, true); enemy.life=enemy.max_life
        local hidden = enemy:clone()
        hidden.name="MCP hidden dummy"; hidden.dont_act=true; hidden.invisible=1000
        game.zone:addEntity(game.level, hidden, "actor", 18, 18)
        enemy.energy.value=1000
        enemy.mcp_probe_dummy=true
        game.zone:addEntity(game.level, enemy, "actor", 6, 3); M.enemy=enemy
        if __module_extra_info.mcp_probe_interactions then require('mod.MCPInteractionProbe').start() end
        game.paused=true
        M.instrumentObserver()
        require('mod.MCPVisibilityProbe').run(M.emit)
        M.ready=true
        M.emit{kind="arena_ready", enemy_uid=enemy.uid, hidden_uid=hidden.uid, state=M.state()}
    end)
end
function M.reload()
    guard(function()
        assert(game.zone.short_name == "mcp-test", "Reload must use the saved native arena")
        for _, actor in pairs(game.level.entities) do
            if actor.mcp_probe_dummy then M.enemy = actor end
        end
        assert(M.enemy, "Saved native enemy fixture is missing")
        if __module_extra_info.mcp_probe_interactions then require('mod.MCPInteractionProbe').attach() end
        M.instrumentObserver()
        M.ready = true
        M.emit{kind="reload_ready", new_character=false, state=M.state(), player_uid=game.player.uid}
    end)
end
return M
