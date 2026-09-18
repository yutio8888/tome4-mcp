-- Query purity tests (spec QRY-01/02/06/07/09/11), no-strict-audit (v1.6).
-- Pure Lua fixtures: no engine, no game source. Under the no-strict-audit
-- principle the live attr/alterTalentCost/cost_factor getters are called
-- directly; a replaced-but-usable helper IS used, and only an unusable helper
-- (missing/erroring/non-finite) makes the field unknown.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Actions=require 'mod.mcp_bridge.Actions'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Distance=require 'mod.mcp_bridge.Distance'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- A controllable, per-function digest store (diagnostic provenance only).
local files={}
fs={readAll=function(path) return files[path] end}
package.loaded.md5={sumhexa=function(bytes) return bytes end}
local function mk(path,src) return assert(loadstring(src,'@'..path))() end
local function trust(id,path,fn)
    local token='md5:'..tostring(fn)
    files[path]=token
    return Compat.registerDependency(id,'talent_query',fn,path,'test',token)
end
local function fixture()
    local p={x=5,y=5,level=10,talents={T_COST=1},talents_cd={},mana=100,
        talents_def={T_COST={id='T_COST',mode='activated',range=1,target='self',mana=10}},
        resources_def={}}
    p.resources_def.mana={short_name='mana',min=0,
        cost_factor=mk('data/resources.lua','return function(self,t,check,value) return 1.5 end')}
    p.alterTalentCost=mk('/mod/class/Actor.lua','return function(self,t,r,c) return c end')
    p.attr=mk('/engine/Entity.lua','return function(self,name) return nil end')
    return p
end
local function trustAll(p)
    Compat.resetDependencies()
    trust('actor.attr','/engine/Entity.lua',p.attr)
    trust('actor.alterTalentCost','/mod/class/Actor.lua',p.alterTalentCost)
    trust('resource.cost_factor:mana','data/resources.lua',p.resources_def.mana.cost_factor)
end

-- QRY-08: one shared grid-distance definition.
check(Distance.grid(0,0,3,5)==5,'fallback grid distance is the documented Chebyshev rule')
check(Distance.grid(2,2,2,2)==0,'zero distance is stable')

-- T-QRY-06 (NO-AUDIT): a replaced-but-usable attr helper IS used.
local p1=fixture()
trustAll(p1)
local dangerAttr=0
p1.attr=function(self,name) dangerAttr=dangerAttr+1; return nil end
local q1=assert(Actions.query(p1,'T_COST'))
check(dangerAttr>0,'a replaced-but-usable attr helper is used, not gated')
check(q1.current_costs.mana==15 and q1.affordable==true,
    'a usable replaced attr helper (no suppression) resolves the cost exactly')

-- T-QRY-06 (NO-AUDIT): an erroring attr helper is not "no suppression" (F4).
local p1e=fixture()
trustAll(p1e)
p1e.attr=function() error('boom') end
local q1e=assert(Actions.query(p1e,'T_COST'))
check(q1e.current_costs.mana=='unknown' and q1e.costs_complete==false and q1e.affordable=='unknown',
    'an unusable suppression helper makes every cost unknown instead of a false certainty')
check(q1e.resource_checks.mana.reason=='suppression_unverified',
    'resource_checks names the unusable suppression helper')

-- T-QRY-07 (NO-AUDIT): a replaced cost helper with a usable value is used.
local p2=fixture()
trustAll(p2)
local usedAlter=0
p2.alterTalentCost=function(self,t,r,c) usedAlter=usedAlter+1; return 99 end
local q2=assert(Actions.query(p2,'T_COST'))
check(usedAlter>0,'a replaced-but-usable cost helper is used, not gated')
check(q2.current_costs.mana==148.5,'the replaced helper value is consumed (99 * 1.5 factor)')

-- F1 (NO-AUDIT): a replaced-but-usable fatigue getter does not degrade, because
-- the function cost factor is called directly.
local p5=fixture()
p5.combatFatigue=mk('/mod/class/interface/Combat.lua','return function(self) return 0 end')
trustAll(p5)
local q5=assert(Actions.query(p5,'T_COST'))
check(q5.current_costs.mana==15 and q5.affordable==true,
    'a usable function cost factor (and its live fatigue getter) resolves exactly')

-- F1 (NO-AUDIT): an erroring function cost factor makes the field unknown.
local p6=fixture()
p6.resources_def.mana.cost_factor=function() error('boom') end
trustAll(p6)
local q6=assert(Actions.query(p6,'T_COST'))
check(q6.current_costs.mana=='unknown' and q6.resource_checks.mana.reason=='cost_factor_unverified',
    'an erroring function cost factor yields unknown cost')

-- T-QRY-09 control: a fully admitted static cost still resolves exactly.
local p3=fixture()
trustAll(p3)
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
