-- V2-3 pure fixtures: engine-free footprint model for the audited shapes.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Footprint=require 'mod.auto_combat.EffectFootprint'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local function spec(shape,geometry)
    local s={origin={x=0,y=0},target={x=0,y=0},shape=shape}
    for k,v in pairs(geometry or {}) do s[k]=v end
    return s
end

-- Line semantics: the origin is excluded.
do
    local points=Footprint.line(0,0,3,0)
    check(#points==3,'a horizontal line has three steps after the origin')
    check(points[1].x==1 and points[1].y==0,'the first step is adjacent to the origin')
    check(points[3].x==3 and points[3].y==0,'the line reaches the target')
end

-- hit / self: a single cell.
do
    local set=Footprint.model(spec('hit',{target={x=4,y=2}}))
    check(Footprint.at(set,4,2) and not Footprint.at(set,3,2),'a hit covers only the target cell')
end

-- bolt stops on the first blocking grid (and only that grid is affected).
do
    local set=Footprint.model(spec('bolt',{target={x=4,y=0}}),{blockPath=function(x) return x==2 end})
    check(Footprint.at(set,2,0),'a bolt affects its stopping grid')
    check(not Footprint.at(set,1,0) and not Footprint.at(set,3,0) and not Footprint.at(set,4,0),
        'a bolt does not affect grids before or after the stop')
end
do
    local set=Footprint.model(spec('bolt',{target={x=4,y=0}}))
    check(Footprint.at(set,4,0) and not Footprint.at(set,0,0),'an unobstructed bolt stops at the target, excluding the origin')
end

-- beam collects every traversed grid, excluding the origin.
do
    local set=Footprint.model(spec('beam',{target={x=3,y=0}}))
    check(Footprint.at(set,1,0) and Footprint.at(set,2,0) and Footprint.at(set,3,0),
        'a beam covers its line')
    check(not Footprint.at(set,0,0),'a beam never covers the origin')
end
do
    local set=Footprint.model(spec('beam',{target={x=4,y=0}}),{blockPath=function(x) return x==2 end})
    check(Footprint.at(set,1,0) and Footprint.at(set,2,0) and not Footprint.at(set,3,0),
        'a blocked beam stops on the blocker')
end

-- ball: radius around the stop; can contain the origin.
do
    local set=Footprint.model(spec('ball',{target={x=3,y=0},radius=5}))
    check(Footprint.at(set,0,0),'a large ball contains the origin')
    local small=Footprint.model(spec('ball',{target={x=3,y=0},radius=1}))
    check(not Footprint.at(small,0,0),'a small remote ball misses the origin')
end
do
    local set=Footprint.model(spec('ball',{target={x=0,y=0},radius=0}))
    check(Footprint.at(set,0,0),'a range-0 ball is centred on the origin')
end

-- widebeam: a radius-1 wide line from the origin includes near-origin width.
do
    local set=Footprint.model(spec('widebeam',{target={x=2,y=0},radius=1}))
    check(Footprint.at(set,0,0),'a radius-1 widebeam includes the origin through its first circle')
    check(Footprint.at(set,2,0),'a widebeam includes the target')
    local wide=Footprint.model(spec('widebeam',{target={x=5,y=0},radius=2}))
    check(Footprint.at(wide,0,0),'a radius-2 widebeam includes the origin')
end

-- cone: the apex is part of the footprint.
do
    local set=Footprint.model(spec('cone',{target={x=4,y=0},radius=3}))
    check(Footprint.at(set,0,0),'the cone apex is in the footprint')
    check(Footprint.at(set,3,0),'the cone covers its axis')
end

-- Unknown shapes fail closed (no safer assumption is available).
do
    local set=Footprint.model(spec('wide',{target={x=1,y=0}}))
    check(set==nil,'an unknown shape produces no footprint')
end

-- A blocking radius excludes the blocked cell from a ball.
do
    local set=Footprint.model(spec('ball',{target={x=0,y=0},radius=1}),{blockRadius=function(x,y) return x==1 and y==0 end})
    check(not Footprint.at(set,1,0),'a blocked radius cell is excluded')
    check(Footprint.at(set,0,0),'the center remains')
end

-- Membership helpers.
do
    local set,_=Footprint.newSet()
    check(Footprint.count(set)==0,'an empty set has no grids')
end

-- A supplied native context that cannot expand is unknown, not the model.
do
    local set,backend=Footprint.expand(spec('beam',{target={x=3,y=0}}),{native={}})
    check(set==nil and backend=='native_failed','a native expansion failure is unknown, not the model')
    local headless=Footprint.expand(spec('beam',{target={x=3,y=0}}),{})
    check(headless~=nil,'an explicitly headless context still uses the pure model')
end

-- DYN-REV-03: the aim direction is independent of the AoE centre. A
-- source-centred cone keeps the bound target as its direction, so the guard's
-- footprint is the real directional Burning Wake shape, not a degenerate apex.
do
    local Guard=require 'mod.auto_combat.AutoCombatGuard'
    local origin={x=0,y=0}
    local bound={x=4,y=0}
    local directional=Guard.footprintSpec({shape='cone',radius=2,center='self',direction='target'},origin,bound)
    check(directional.origin.x==0 and directional.target.x==4,'direction keeps the bound target as the aim vector')
    local set=Footprint.model(directional,{})
    check(Footprint.at(set,1,0),'the directional source-centred cone includes the immediately-east grid')
    check(Footprint.count(set)>1,'the directional cone is not degenerate')
    local degenerate=Guard.footprintSpec({shape='cone',radius=2,center='self'},origin,bound)
    check(degenerate.target.x==0 and degenerate.target.y==0,'a centre-only component collapses to the caster')
end

-- DYN-REV2-01: map-effect helpers are called with the engine's boolean-true
-- block argument (`Map:addEffect` passes `true`), never a custom callback.
do
    local real_core=rawget(_G,'core')
    local captured
    rawset(_G,'core',{fov={
        circle_grids=function(x,y,radius,block) captured={shape='ball',block=block}; return {[x]={[y]=true}} end,
        beam_any_angle_grids=function(x,y,radius,angle,sx,sy,dx,dy,block)
            captured={shape='cone',block=block,dx=dx,dy=dy}; return {[x]={[y]=true}} end,
    }})
    local ctx={game={level={map={isBound=function() return true end}}},source={x=0,y=0}}
    Footprint.nativeMapEffect(ctx,{shape='ball',target={x=1,y=1},radius=2})
    check(captured and captured.shape=='ball' and captured.block==true,'a map-effect ball passes block=true')
    Footprint.nativeMapEffect(ctx,{shape='cone',origin={x=0,y=0},target={x=3,y=0},radius=2})
    check(captured and captured.shape=='cone' and captured.block==true and captured.dx==3,
        'a map-effect cone passes block=true and the aim delta')
    rawset(_G,'core',real_core)
end

print('Effect footprint: '..checks..' checks passed')
