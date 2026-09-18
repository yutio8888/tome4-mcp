-- Friendly-fire pre-cast safety: static friendlyfire metadata plus the visible
-- ally-in-footprint read used by inspect (round-21 report 3-4).
-- P3-b (TODO #63): derive the addon root from this test's own path so a bare
-- relative invocation fails loudly instead of silently testing the canonical
-- `game/addons/tome-mcp-bridge` tree from another checkout.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
package.path=root..'/overload/?.lua;'..package.path
local Details=require 'mod.mcp_bridge.ObservationDetails'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

check(Details.friendlyfire({friendlyfire=true})==true,'explicit friendlyfire true is authoritative')
check(Details.friendlyfire({friendlyfire=false})==false,'explicit friendlyfire false is authoritative')
check(Details.friendlyfire({})==true,'a missing friendlyfire reports the engine default true')
check(Details.friendlyfire({friendlyfire=60})==60,'a numeric friendlyfire is preserved')
-- Engine per-shape defaults (Target:getType fills selffire/friendlyfire true;
-- only the cone transform forces selffire=false). These are field values, not
-- footprint claims: combine them with Details.footprintContainsOrigin.
for _,shape in ipairs({'hit','bolt','beam','widebeam','ball','arrow','self','wide'}) do
    check(Details.selffire({type=shape})==true,'shape '..shape..' defaults selffire true')
    check(Details.friendlyfire({type=shape})==true,'shape '..shape..' defaults friendlyfire true')
end
check(Details.selffire({type='cone'})==false,'the cone transform forces selffire=false')
check(Details.selffire({type='hit',selffire=false})==false,'an explicit selffire false wins')
-- Geometric containment is separate from the filter defaults.
check(Details.footprintContainsOrigin({x=5,y=5},'beam',nil,12,9,5)==false,'a beam excludes its origin')
check(Details.footprintContainsOrigin({x=5,y=5},'bolt',nil,12,9,5)==false,'a bolt excludes its origin')
check(Details.footprintContainsOrigin({x=5,y=5},'ball',3,nil,7,5)==true,'a ball contains the origin within its radius')
check(Details.footprintContainsOrigin({x=5,y=5},'widebeam',1,12,9,5)==true,'a radius-1 widebeam can contain the origin')

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

-- Native evaluates `typ.player_selffire or act.allow_player_selffire`: false in
-- one source must not veto true in the other.
check(Details.playerSelfOverride({allow_player_selffire=true},{player_selffire=false})==true,
    'the actor opt-in wins over a spec player_selffire=false')
check(Details.playerSelfOverride({allow_player_selffire=false},{player_selffire=true})==true,
    'the spec opt-in wins over an actor allow_player_selffire=false')
check(Details.playerSelfOverride({allow_player_selffire=false},{player_selffire=false})==false,
    'both opt-in sources false suppress the projectile self-hit')
check(Details.playerSelfOverride({allow_player_selffire=true},{})==true,
    'the actor opt-in applies when the spec omits player_selffire')
check(Details.playerSelfOverride({},{})==false,'no opt-in suppresses the projectile self-hit')

print('Friendly fire: '..checks..' checks passed')
