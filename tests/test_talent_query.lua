-- Protocol 3 talent query and one-shot target prefill. Uses a controlled
-- fixture; the native game suite verifies the real getTarget path separately.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Actions=require 'mod.mcp_bridge.Actions'
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- --- Pure validation: protocol version gating -------------------------------
local v3=assert(Actions.validate({type='use_talent',talent_id='T_TEST'}))
check(v3.talent_id=='T_TEST' and v3.target_id==nil,'v3 use_talent accepts talent_id only')
local actorPrefill=assert(Actions.validate({type='use_talent',talent_id='T_TEST',target_id='actor-1'}))
check(actorPrefill.target_id=='actor-1','v3 accepts actor prefill')
local positionPrefill=assert(Actions.validate({type='use_talent',talent_id='T_TEST',x=4,y=7}))
check(positionPrefill.x==4 and positionPrefill.y==7,'v3 accepts position prefill')
for _,bad in ipairs{
    {type='use_talent',talent_id='T_TEST',target_id='a',x=1,y=2},
    {type='use_talent',talent_id='T_TEST',x=1},
    {type='use_talent',talent_id='T_TEST',y=2},
    {type='use_talent',talent_id='T_TEST',x=-1,y=2},
    {type='use_talent',talent_id='T_TEST',x=1.5,y=2},
    {type='use_talent',talent_id='T_TEST',x=1,y=2,extra=true},
} do
    check(not Actions.validate(bad),'v3 rejects malformed prefill: '..tostring(bad.x)..','..tostring(bad.y))
end

-- --- Read-only query ---------------------------------------------------------
local queryP={x=5,y=5,level=10,talents={T_STATIC=3,T_DYNAMIC=1,T_COOLDOWN=1},talents_cd={},mana=40,stamina=100}
local dynamicRangeCalls=0
local dynamicRequiresCalls=0
queryP.talents_def={
    T_STATIC={id='T_STATIC',mode='activated',range=8,requires_target=true,target='actor',mana=30,cooldown=5},
    T_DYNAMIC={id='T_DYNAMIC',mode='activated',range=function() dynamicRangeCalls=dynamicRangeCalls+1;return 5 end,
        requires_target=function() dynamicRequiresCalls=dynamicRequiresCalls+1;return true end,target=function() return 'actor' end},
    T_COOLDOWN={id='T_COOLDOWN',mode='activated',range=1,target='self',cooldown=4},
}
local q=assert(Actions.query(queryP,'T_STATIC'))
check(q.range==8 and q.requires_target==true and q.target_type=='actor','query reads stored range and target flags')
check(q.base_costs.mana==30 and q.current_costs.mana=='unknown' and q.costs_complete==false,
    'base cost is stored; real-time cost is unknown without the native helpers')
check(q.affordable=='unknown' and q.cooldown_remaining==0,
    'unknown real-time cost yields unknown affordability, never a base-cost guess')
check(q.resource_checks.mana.amount=='unknown' and q.resource_checks.mana.affordable=='unknown'
    and type(q.resource_checks.mana.reason)=='string' and q.resource_checks.mana.reason:find('unverified'),
    'resource_checks explains the unknown affordability per resource')
check(q.prefill_supported==true and #q.prefill_modes==2,'query advertises prefill modes')
check(q.readiness=='unknown' and q.readiness_reason=='target_required','readiness stays advisory and reports the missing target')
local far=assert(Actions.query(queryP,'T_STATIC',{x=5,y=12}))
check(far.distance==7 and far.in_range==true,'query computes distance and in_range from a target')
local beyond=assert(Actions.query(queryP,'T_STATIC',nil,5,20))
check(beyond.distance==15 and beyond.in_range==false,'query accepts explicit coordinates')
local dynamic=assert(Actions.query(queryP,'T_DYNAMIC'))
check(dynamic.range=='unknown' and dynamic.requires_target=='unknown' and dynamic.target_type=='unknown',
    'dynamic range/requires_target/target are reported unknown')
check(dynamicRangeCalls==0 and dynamicRequiresCalls==0,'query never evaluates dynamic talent functions')
queryP.talents_cd.T_COOLDOWN=3
local cooling=assert(Actions.query(queryP,'T_COOLDOWN'))
check(cooling.cooldown_remaining==3 and cooling.readiness=='blocked' and cooling.readiness_reason=='cooldown',
    'cooldown blocks readiness without running preUseTalent')
queryP.talents_cd.T_COOLDOWN=nil
queryP.mana=10
local unknownPoor=assert(Actions.query(queryP,'T_STATIC'))
check(unknownPoor.affordable=='unknown' and unknownPoor.readiness_reason~='insufficient_resource',
    'low resources never fabricate a certain unaffordable result without a known current cost')
queryP.mana=40
check(select(2,Actions.query(queryP,'T_MISSING'))=='invalid_talent','unknown talent id is rejected')
-- F1: read-only dependencies are only trusted after an audited registration
-- (source path + file digest). Tests stub fs/md5 so the audit path itself runs.
local files={}
fs={readAll=function(path) return files[path] end}
package.loaded.md5={sumhexa=function(bytes) return bytes end}
local function mk(path,src) return assert(loadstring(src,'@'..path))() end
local function trust(id,path,fn)
    local token='md5:'..tostring(fn)
    files[path]=token
    return Compat.registerDependency(id,'talent_query',fn,path,'test',token)
end
local function resetAndTrust(p)
    Compat.resetDependencies()
    if type(p.attr)=='function' then trust('actor.attr','/engine/Entity.lua',p.attr) end
    if type(p.alterTalentCost)=='function' then trust('actor.alterTalentCost','/mod/class/Actor.lua',p.alterTalentCost) end
    local defs=p.resources_def
    if type(defs)=='table' then
        for name,def in pairs(defs) do
            if type(def)=='table' and type(def.cost_factor)=='function' then
                trust('resource.cost_factor:'..name,'data/resources.lua',def.cost_factor)
            end
        end
    end
end
-- Real-time cost mirrors native postUseTalent order (alterTalentCost then cost_factor).
local costP={x=1,y=1,level=10,talents={T_COST=1},talents_cd={},mana=100,
    talents_def={T_COST={id='T_COST',mode='activated',range=1,target='self',mana=10}},
    resources_def={{short_name='mana',min=0,cost_factor=mk('data/resources.lua','return function(self,t,check,value) return 1.5 end')}},
    alterTalentCost=mk('/mod/class/Actor.lua','return function(self,t,r,c) return c end'),
    attr=mk('/engine/Entity.lua','return function(self,name) return nil end')}
costP.resources_def.mana=costP.resources_def[1]
resetAndTrust(costP)
local qc=assert(Actions.query(costP,'T_COST'))
check(qc.base_costs.mana==10 and qc.current_costs.mana==15 and qc.costs_complete==true,
    'query reports the real-time cost with the native cost_factor')
check(qc.affordable==true and qc.resource_checks.mana.reason=='sufficient',
    'known sufficient current cost is affordable')
costP.mana=5
local qpoor=assert(Actions.query(costP,'T_COST'))
check(qpoor.affordable==false and qpoor.readiness=='blocked' and qpoor.readiness_reason=='insufficient_resource'
    and qpoor.resource_checks.mana.reason=='insufficient_resource',
    'known insufficient current cost blocks readiness')
costP.mana=100
costP.talents_def.T_COST.mana=function() return 10 end
local qd=assert(Actions.query(costP,'T_COST'))
check(qd.current_costs.mana=='unknown' and qd.costs_complete==false and qd.affordable=='unknown',
    'dynamic base cost stays unknown and does not fabricate affordability')
costP.talents_def.T_COST.mana=10
costP.alterTalentCost=function() return 10 end
local qi=assert(Actions.query(costP,'T_COST'))
check(qi.current_costs.mana=='unknown' and qi.affordable=='unknown',
    'a modified alterTalentCost is not executed and affordability stays unknown')
-- F1: a dependency that cannot be audited at registration is never used.
local forgedP={x=1,y=1,level=10,talents={T_COST=1},talents_cd={},mana=100,
    talents_def={T_COST={id='T_COST',mode='activated',range=1,target='self',mana=10}},
    resources_def={{short_name='mana',min=0,cost_factor=mk('data/resources.lua','return function() return 1 end')}},
    alterTalentCost=mk('/mod/class/Actor.lua','return function(self,t,r,c) return c end'),
    attr=mk('/engine/Entity.lua','return function(self,name) return nil end')}
forgedP.resources_def.mana=forgedP.resources_def[1]
Compat.resetDependencies()
files['/engine/Entity.lua']=nil
Compat.registerDependency('actor.attr','talent_query',forgedP.attr,'/engine/Entity.lua','test','does-not-match')
files['/mod/class/Actor.lua']='token-alter'
Compat.registerDependency('actor.alterTalentCost','talent_query',forgedP.alterTalentCost,'/mod/class/Actor.lua','test','token-alter')
files['data/resources.lua']='token-cf'
Compat.registerDependency('resource.cost_factor:mana','talent_query',forgedP.resources_def.mana.cost_factor,'data/resources.lua','test','token-cf')
local forged=assert(Actions.query(forgedP,'T_COST'))
check(forged.current_costs.mana=='unknown' and forged.resource_checks.mana.reason=='dependency_source_unreadable',
    'F1: an unauditable dependency is never used')
-- F4: a suppression getter that is missing or raises must not become "not suppressed".
local attrP={x=1,y=1,level=10,talents={T_COST=1},talents_cd={},mana=5,
    talents_def={T_COST={id='T_COST',mode='activated',range=1,target='self',mana=10}},
    resources_def={{short_name='mana',min=0,cost_factor=mk('data/resources.lua','return function() return 1 end')}},
    alterTalentCost=mk('/mod/class/Actor.lua','return function(self,t,r,c) return c end')}
attrP.resources_def.mana=attrP.resources_def[1]
attrP.attr=mk('/engine/Entity.lua','return function(self,name) error("suppression getter failed") end')
resetAndTrust(attrP)
local f4=assert(Actions.query(attrP,'T_COST'))
check(f4.current_costs.mana=='unknown' and f4.costs_complete==false
    and f4.resource_checks.mana.reason=='suppression_unverified' and f4.affordable~=false,
    'F4: a raising suppression getter yields unknown cost, not a confirmed cost')
local nilAttrP={x=1,y=1,level=10,talents={T_COST=1},talents_cd={},mana=5,
    talents_def={T_COST={id='T_COST',mode='activated',range=1,target='self',mana=10}},
    resources_def={{short_name='mana',min=0,cost_factor=mk('data/resources.lua','return function() return 1 end')}},
    alterTalentCost=mk('/mod/class/Actor.lua','return function(self,t,r,c) return c end')}
nilAttrP.resources_def.mana=nilAttrP.resources_def[1]
resetAndTrust(nilAttrP)
local f4b=assert(Actions.query(nilAttrP,'T_COST'))
check(f4b.current_costs.mana=='unknown' and f4b.resource_checks.mana.reason=='suppression_unverified',
    'F4: a missing suppression getter is unknown, never a confirmed cost')

-- Round-2 report 3.a/3.b: static targeting hints and signed resource costs.
local geoP={x=1,y=1,level=10,talents={T_BALL=1,T_FUNC=1},talents_cd={},
    talents_def={
        T_BALL={id='T_BALL',mode='activated',range=7,radius=3,requires_target=true,direct_hit=true,reflectable=true,target={type='ball'}},
        T_FUNC={id='T_FUNC',mode='activated',range=10,requires_target=true,target=function() return {type='beam'} end}}}
Compat.resetDependencies()
local qball=assert(Actions.query(geoP,'T_BALL'))
check(qball.radius==3 and qball.direct_hit==true and qball.reflectable==true and qball.target_shape=='ball',
    'static radius/direct_hit/reflectable/target_shape are reported')
check(qball.target_type=='table','a table target keeps target_type=table')
local qbeam=assert(Actions.query(geoP,'T_FUNC'))
check(qbeam.target_shape=='unknown' and qbeam.target_type=='unknown' and qbeam.range==10,
    'a dynamic target stays unknown and is never evaluated')
local creditP={x=1,y=1,level=10,talents={T_CREDIT=1},talents_cd={},positive=20,
    talents_def={T_CREDIT={id='T_CREDIT',mode='activated',range=5,target='self',positive=-15}},
    resources_def={},
    alterTalentCost=mk('/mod/class/Actor.lua','return function(self,t,r,c) return c end'),
    attr=mk('/engine/Entity.lua','return function(self,name) return nil end')}
creditP.resources_def.positive={short_name='positive',min=0,cost_factor=mk('data/resources.lua','return function() return 1 end')}
resetAndTrust(creditP)
local qcredit=assert(Actions.query(creditP,'T_CREDIT'))
check(qcredit.base_costs.positive==-15 and qcredit.resource_checks.positive.operation=='credit'
    and qcredit.resource_checks.positive.pool_delta==15,
    'a negative stored cost is a credit against the pool, not a debit')

-- --- One-shot target prefill -------------------------------------------------
-- Replace the native seam and compatibility gate with controlled doubles so the
-- prefill wrapper can be exercised without a running engine.
local realStart,realCheck,realMatches=Tracker.start,Compat.check,Compat.matches
local seen,nativeCalls
local prefillDef={id='T_PREFILL',mode='activated',action=function() end}
local rangeDef={id='T_PREFILL_RANGE',mode='activated',action=function() end,range=5}
local dynamicDef={id='T_PREFILL_DYNAMIC',mode='activated',action=function() end,test_range=2}
local warnDef={id='T_PREFILL_WARN',mode='activated',action=function() end,test_warn=true}
local beamDef={id='T_PREFILL_BEAM',mode='activated',action=function() end,test_type='beam'}
local p={x=1,y=1,energy={value=1000},talents={T_PREFILL=1,T_PREFILL_RANGE=1,T_PREFILL_DYNAMIC=1,T_PREFILL_WARN=1,T_PREFILL_BEAM=1},
    talents_def={T_PREFILL=prefillDef,T_PREFILL_RANGE=rangeDef,T_PREFILL_DYNAMIC=dynamicDef,T_PREFILL_WARN=warnDef,T_PREFILL_BEAM=beamDef}}
p.useTalent=function(self,id)
    local def=self.talents_def[id] or {}
    local spec={range=def.test_range,type=def.test_type,talent=def.test_warn and def or nil,nowarning=def.test_nowarning}
    local x,y,t=self:getTarget(spec)
    seen[#seen+1]={x,y,t}
    x,y,t=self:getTarget(spec)
    seen[#seen+1]={x,y,t}
    return true
end
setmetatable(p,{__index={getTarget=function() nativeCalls=nativeCalls+1;return 99,99,nil end}})
local g={player=p,level={map={w=20,h=20}}}
local meta={protocol_version=3,session_id='s',level_instance_id='l',revision=1}
local command={command_id='c1'}
Tracker.start=function(_,_,fn)
    local ok,value=pcall(fn)
    if not ok then error(value,0) end
    return {test=true},value
end
Compat.check=function() return true end
Compat.matches=function() return true end
local function run(action,target)
    seen={};nativeCalls=0
    local result=Actions.execute(g,action,target,meta,command)
    check(rawget(p,'getTarget')==nil,'prefill wrapper always removed from the player')
    return result
end
local actor={x=6,y=3}
local result=run({type='use_talent',talent_id='T_PREFILL',target_id='actor-1'},actor)
check(result.ok,'prefilled actor action completes')
check(seen[1][1]==6 and seen[1][2]==3 and seen[1][3]==actor,'first getTarget returns the prefilled actor')
check(seen[2][1]==99 and seen[2][2]==99 and nativeCalls==1,'second getTarget uses native targeting')
check(g.target==nil or g.target.forced==nil,'prefill does not use the global forced-target field')
result=run({type='use_talent',talent_id='T_PREFILL',x=7,y=8})
check(result.ok and seen[1][1]==7 and seen[1][2]==8 and seen[1][3]==nil,'position prefill returns coordinates without an entity')
check(nativeCalls==1,'position prefill also consumes exactly once')
result=run({type='use_talent',talent_id='T_PREFILL'})
check(result.ok and seen[1][1]==99 and seen[2][1]==99 and nativeCalls==2,'no prefill leaves native targeting untouched')
result=run({type='use_talent',talent_id='T_PREFILL',target_id='actor-1'},nil)
check(not result.ok and result.code=='target_lost','unresolved prefilled actor is refused before execution')
-- Static range is checked before the native talent starts.
result=run({type='use_talent',talent_id='T_PREFILL_RANGE',x=1,y=10})
check(not result.ok and result.code=='target_out_of_range' and nativeCalls==0,
    'static out-of-range prefill is refused before native execution')
result=run({type='use_talent',talent_id='T_PREFILL_RANGE',x=1,y=5})
check(result.ok and seen[1][1]==1 and seen[1][2]==5,'static in-range prefill still runs')
-- A dynamic talent target spec is enforced by the getTarget wrapper, which
-- falls back to native targeting instead of using the out-of-range point.
result=run({type='use_talent',talent_id='T_PREFILL_DYNAMIC',x=1,y=10})
check(result.ok and seen[1][1]==99 and nativeCalls>=1,
    'dynamic out-of-range prefill falls back to native targeting')
-- A self-target prefill must not silence the native self-target warning.
result=run({type='use_talent',talent_id='T_PREFILL_WARN',x=1,y=1})
check(result.ok and seen[1][1]==99 and nativeCalls>=1,
    'self-target warning prefill falls back to native targeting')
result=run({type='use_talent',talent_id='T_PREFILL_BEAM',x=7,y=8})
check(result.ok and command.target_geometry and command.target_geometry.shape=='beam'
    and command.target_geometry.piercing==true,
    'the native target geometry (beam/piercing) is recorded on the command')

Tracker.start,Compat.check,Compat.matches=realStart,realCheck,realMatches

-- Grid answers must enforce the same native talent range.
local Interactions=require 'mod.mcp_bridge.Interactions'
local realValid=Interactions.valid
Interactions.valid=function() return true end
local gridHandler={game={player={x=2,y=2},level={map={w=20,h=20}}},target={},co={},kind='target.grid',range=5}
local prepared,code=Interactions.prepare(gridHandler,{type='position',x=2,y=10}, {})
check(prepared==nil and code=='position_out_of_range','respond enforces native range for grid answers')
prepared,code=Interactions.prepare(gridHandler,{type='position',x=2,y=6}, {})
check(type(prepared)=='table' and prepared.x==2 and prepared.y==6,'in-range grid answer is prepared')
Interactions.valid=realValid

print('Talent query/prefill: '..checks..' checks passed')
