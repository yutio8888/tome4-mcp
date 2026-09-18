-- Native perception fixtures only; never installed in ordinary campaign runs.
local M={}
function M.run(emit)
    local Observer=require 'mod.mcp_bridge.Observer'
    local Compat=require 'mod.mcp_bridge.NativeCompatibility'
    local Json=require 'mod.mcp_bridge.Json'
    local p,map,zone=game.player,game.level.map,game.zone
    local meta={session_id='visibility-fixture',level_instance_id='arena',revision=0,protocol_version=3,
        phase='ready',control='manual',battle_companion={}}
    local function check(ok,name)
        emit{kind='visibility_check',passed=ok==true,name=name}
        assert(ok,name)
    end
    local function snap() return Observer.capture(game,meta,12) end
    local function cell(s,x,y)
        for _,c in ipairs(s.map.cells) do if c.x==x and c.y==y then return c end end
    end
    local old_wild,old_radius,old_blind=zone.wilderness,zone.wilderness_see_radius,p.blind
    local old_terrain=map(14,3,map.TERRAIN)
    local hidden=old_terrain:clone();hidden.name='MCP UNSEEN WORLD LOCATION';hidden.change_zone='private-world-destination';hidden.change_level=1
    map(14,3,map.TERRAIN,hidden)
    local function fov() map.clean_fov=true;p:playerFOV() end
    zone.wilderness=true;zone.wilderness_see_radius=4;fov();Observer.reset()
    check(Compat.matches('playerFOV',p.playerFOV) and Compat.matches('computeFOV',p.computeFOV)
        and Compat.matches('map.applyLite',map.applyLite) and Compat.matches('map.cleanFOV',map.cleanFOV),
        'wilderness_perception_entrypoints_are_present_for_direct_use')
    local world=snap();local matches,seen=true,0
    for _,c in ipairs(world.map.cells) do
        local i=c.x+c.y*map.w
        local native=map.seens[i]~=nil and map.seens[i]~=false and map.seens[i]~=0
        if c.visible~=native or c.known~=native or map.infovs[i] then matches=false end
        if native then seen=seen+1 end
    end
    check(matches and seen>0,'native_wilderness_cells_match_applyLite_without_infovs')
    check(not cell(world,14,3).known and not Json.encode(world):find('MCP UNSEEN WORLD LOCATION',1,true)
        and not Json.encode(world):find('private-world-destination',1,true),'native_unseen_world_entrance_not_disclosed')
    local wilderness_view=snap()
    check(Json.encode(world)==Json.encode(wilderness_view),'repeated_native_world_observations_are_identical')
    p.blind=1;Observer.reset();local blind=snap();local none=true
    for _,c in ipairs(blind.map.cells) do if c.known or c.visible then none=false end end
    check(none,'native_wilderness_blind_projection_does_not_learn_terrain')
    p.blind=old_blind
    -- NO-AUDIT: a replaced-but-present perception entrypoint is used as a normal
    -- entry (the wilderness branch proceeds); a MISSING/non-function one is
    -- unavailable. `computeFOV` is a class method, so restore by deleting the
    -- instance shadow.
    p.computeFOV=function() end
    Observer.reset();local replaced=snap()
    check(cell(replaced,p.x,p.y).known,'native_world_replaced_perception_entrypoint_is_used')
    p.computeFOV=false
    Observer.reset();local missing=snap()
    check(not cell(missing,p.x,p.y).known,'native_world_missing_perception_entrypoint_is_unavailable')
    rawset(p,'computeFOV',nil)
    zone.wilderness=old_wild;zone.wilderness_see_radius=old_radius
    -- Genuine native ESP only marks the actor's cell; it does not reveal floor.
    local old_esp=p.esp_all;p.esp_all=1;p:resetCanSeeCache()
    map.clean_fov=true;map:cleanFOV();map:applyESP(6,3,0.6);Observer.reset()
    local esp=snap()
    check(map.seens[6+3*map.w] and not map.infovs[6+3*map.w]
        and not cell(esp,6,3).known,'native_dungeon_esp_does_not_disclose_terrain')
    p.esp_all=old_esp;p:resetCanSeeCache()
    fov();Observer.reset();local dungeon=snap()
    check(cell(dungeon,p.x,p.y).known and cell(dungeon,p.x,p.y).visible,'native_dungeon_ordinary_fov_still_reveals_terrain')
    p.blind=1;Observer.reset();local blind_dungeon=snap();none=true
    for _,c in ipairs(blind_dungeon.map.cells) do if c.known or c.visible then none=false end end
    check(none,'native_dungeon_blind_projection_does_not_learn_terrain')
    p.blind=old_blind;map(14,3,map.TERRAIN,old_terrain);fov();Observer.reset()
end
return M
