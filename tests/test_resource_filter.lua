-- Snapshot resource filtering (report 3.b): only resources the player has
-- unlocked (resource pool talent learned) are reported; talent-less resources
-- such as air are always kept. Pure fixture, no engine.
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

local function player()
    local p={level=1,exp=1,exp_mod=1,talents={T_POSITIVE_POOL=true},talents_def={},stats_def={},
        stats={},inc_stats={},descriptor={},unused_stats=0,unused_talents=0,unused_generics=0,
        unused_talents_types=0,unused_prodigies=0,life_regen=0,die_at=0,energy={value=1000},
        inven={},inven_def={},tmp={},resources_def={},
        mana=0,max_mana=100,positive=10,max_positive=50,negative=5,max_negative=50,air=100,max_air=100}
    p.resources_def.mana={short_name='mana',talent='T_MANA_POOL'}
    p.resources_def.positive={short_name='positive',talent='T_POSITIVE_POOL'}
    p.resources_def.negative={short_name='negative',talent='T_NEGATIVE_POOL'}
    p.resources_def.air={short_name='air'}
    return p
end
local p=player()
local result={}
Details.player({player=p},p,{session_id='s',level_instance_id='l'},result)
local r=result.resources
check(r.positive and r.negative==nil and r.mana==nil and r.air,
    'only unlocked pools are reported; air (no pool talent) is kept')
check(r.positive.value==10 and r.positive.max==50,'unlocked resource keeps value/min/max')
p.talents.T_NEGATIVE_POOL=true
result={};Details.player({player=p},p,{session_id='s',level_instance_id='l'},result)
check(result.resources.negative and result.resources.mana==nil,'learning a second pool reports only that pool')
print('Resource filter: '..checks..' checks passed')
