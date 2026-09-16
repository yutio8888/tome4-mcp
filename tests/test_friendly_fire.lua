-- Friendly-fire pre-cast safety: static friendlyfire metadata plus the visible
-- ally-in-footprint read used by inspect (round-21 report 3-4).
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Details=require 'mod.mcp_bridge.ObservationDetails'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

check(Details.friendlyfire({friendlyfire=true})==true,'explicit friendlyfire true is authoritative')
check(Details.friendlyfire({friendlyfire=false})==false,'explicit friendlyfire false is authoritative')
check(Details.friendlyfire({})=='unknown','a missing friendlyfire stays unknown')

local function actor(x,y,faction,reaction,extra)
    local a={__is_actor=true,x=x,y=y,faction=faction,reaction=reaction,uid=x*100+y,
        name='unit-'..x..'-'..y}
    for k,v in pairs(extra or {}) do a[k]=v end
    return a
end
local origin=actor(5,5,'player',0)
local ally=actor(7,5,'player',0)
local escort=actor(9,5,'player',0)
local hostile=actor(8,5,'enemy',-1)
local hiddenAlly=actor(6,5,'player',0,{hidden=true})
local southAlly=actor(5,7,'player',0)
local g={player=origin,level={entities={origin,ally,escort,hostile,hiddenAlly,southAlly}}}
local function visible(_,a) return not a.hidden end

do
    local names,count=Details.friendliesInEffect(g,origin,8,5,'beam',nil,12,visible)
    check(count==2,'a piercing beam warns about the visible allies on its line')
    local ids={}
    for _,entry in ipairs(names) do ids[entry.id]=true end
    check(ids[tostring(ally.uid)] and ids[tostring(escort.uid)],'both line allies are named')
    check(not ids[tostring(hostile.uid)],'a hostile on the line is not a friendly-fire risk')
    check(not ids[tostring(hiddenAlly.uid)],'an unseen ally is not read')
end
do
    local _,count=Details.friendliesInEffect(g,origin,5,7,'ball',1,nil,visible)
    check(count==1,'a ball warns about the ally in its radius')
    local _,far=Details.friendliesInEffect(g,origin,5,7,'ball',0,nil,visible)
    check(far==1,'a zero radius only covers the impact cell')
end
do
    local _,count=Details.friendliesInEffect(g,origin,7,5,'hit',nil,nil,visible)
    check(count==1,'a single-target hit warns about an ally on the target cell')
    local _,none=Details.friendliesInEffect(g,origin,3,3,'hit',nil,nil,visible)
    check(none==0,'an empty cell has no friendly-fire risk')
end
do
    -- A beam aimed at a distant hostile still warns about nearer allies; range
    -- clips the ray so allies beyond it are not reported.
    local _,count=Details.friendliesInEffect(g,origin,9,5,'beam',nil,3,visible)
    check(count==1,'range clips the beam footprint to the nearer ally')
end

print('Friendly fire: '..checks..' checks passed')
