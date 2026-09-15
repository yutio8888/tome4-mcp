-- Query purity and dependency-audit tests (spec QRY-01/02/06/07/09/11).
-- Pure Lua fixtures: no engine, no game source. Dangerous helpers are replaced
-- after the baseline is registered and must never be called.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Actions=require 'mod.mcp_bridge.Actions'
local TalentQuery=require 'mod.mcp_bridge.TalentQuery'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Distance=require 'mod.mcp_bridge.Distance'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function fixture()
    local p={x=5,y=5,level=10,talents={T_COST=1},talents_cd={},mana=100,
        talents_def={T_COST={id='T_COST',mode='activated',range=1,target='self',mana=10}},
        resources_def={}}
    p.resources_def.mana={short_name='mana',min=0,
        cost_factor=assert(loadstring('return function(self,t,check,value) return 1.5 end','@data/resources.lua')())}
    p.alterTalentCost=assert(loadstring('return function(self,t,r,c) return c end','@/mod/class/Actor.lua')())
    p.attr=assert(loadstring('return function(self,name) return nil end','@/mod/class/Actor.lua')())
    return p
end

-- QRY-08: one shared grid-distance definition.
check(Distance.grid(0,0,3,5)==5,'fallback grid distance is the documented Chebyshev rule')
check(Distance.grid(2,2,2,2)==0,'zero distance is stable')

-- T-QRY-06: an attr helper replaced after the baseline is never called.
Compat.resetDependencies()
local p1=fixture()
TalentQuery.registerNative(p1)
local dangerAttr=0
p1.attr=function(self,name) dangerAttr=dangerAttr+1; return 0 end
local q1=assert(Actions.query(p1,'T_COST'))
check(dangerAttr==0,'a replaced attr helper is never called')
check(q1.current_costs.mana=='unknown' and q1.costs_complete==false and q1.affordable=='unknown',
    'untrusted suppression makes every cost unknown instead of a false certainty')
check(q1.resource_checks.mana.reason=='dependency_replaced',
    'resource_checks names the replaced dependency')

-- T-QRY-07: a same-source-tag replacement of the cost helper is rejected.
Compat.resetDependencies()
local p2=fixture()
TalentQuery.registerNative(p2)
local dangerAlter=0
p2.alterTalentCost=assert(loadstring('return function(self,t,r,c) return c end','@/mod/class/Actor.lua')())
local replaced=p2.alterTalentCost
p2.alterTalentCost=function(self,t,r,c) dangerAlter=dangerAlter+1; return 99 end
local q2=assert(Actions.query(p2,'T_COST'))
check(replaced~=p2.alterTalentCost and dangerAlter==0,'a disguised replacement is not executed')
check(q2.current_costs.mana=='unknown' and q2.affordable=='unknown','a rejected helper yields unknown cost')

-- T-QRY-09 control: a registered static cost still resolves exactly.
Compat.resetDependencies()
local p3=fixture()
TalentQuery.registerNative(p3)
local q3=assert(Actions.query(p3,'T_COST'))
check(q3.current_costs.mana==15 and q3.costs_complete==true and q3.affordable==true,
    'a fully audited static cost is not degraded to unknown')

-- T-QRY-11: 1000 reads do not touch game state or RNG.
local before={x=p3.x,y=p3.y,mana=p3.mana,cd=p3.talents_cd.T_COST,life=p3.life}
local rngCalls=0
local preUseCalls=0
p3.preUseTalent=function() preUseCalls=preUseCalls+1 end
local mathRandom=math.random
math.random=function(...) rngCalls=rngCalls+1; return mathRandom(...) end
for _=1,1000 do assert(Actions.query(p3,'T_COST',{x=6,y=5})) end
math.random=mathRandom
check(p3.x==before.x and p3.y==before.y and p3.mana==before.mana
    and p3.talents_cd.T_COST==before.cd and p3.life==before.life,
    '1000 reads leave player fields unchanged')
check(rngCalls==0 and preUseCalls==0,'reads consume no RNG and never run preUseTalent')
local qr=assert(Actions.query(p3,'T_COST',nil,5,9))
check(qr.distance==4 and qr.in_range==false,'query range uses the shared distance definition')

print('Query purity: '..checks..' checks passed')
