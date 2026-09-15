-- Native LevelupDialog/Actor/ActorTalents implementations in an isolated actor
-- boundary fixture. Campaign acceptance separately exercises the real player.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Progression=require 'mod.mcp_bridge.Progression'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local function read(path) local f=assert(io.open(path));local data=f:read('*a');f:close();return data end
local function copy(t)
    if type(t)~='table' then return t end
    local n={};for k,v in pairs(t) do n[k]=copy(v) end;return setmetatable(n,getmetatable(t))
end
string.tformat=string.format
string.capitalize=function(text) return text:sub(1,1):upper()..text:sub(2) end
string.toTString=function(text) return {text} end
local util={bound=function(v,lo,hi) return math.max(lo,math.min(v,hi)) end,
    getval=function(v,...) if type(v)=='function' then return v(...) end;return v end}
local function nativeModule(path,source,extra,stop)
    local module={}
    local env=setmetatable({_M=module,module=function() end,require=function() return {} end,
        class={make=true,inherit=function() return {} end},mod={class={interface={TooltipsData={}}}},
        _t=function(v) return v end,util=util}, {__index=_G})
    for k,v in pairs(extra or {}) do env[k]=v end
    local data=read(path)
    if stop then data=data:sub(1,assert(data:find(stop,1,true))-1) end
    local chunk=assert(loadstring(data,'@'..source));setfenv(chunk,env);chunk()
    return module,env
end
local base,base_env=nativeModule('game/engines/default/engine/interface/ActorTalents.lua','/engine/interface/ActorTalents.lua')
local stats,stats_env=nativeModule('game/engines/default/engine/interface/ActorStats.lua','/engine/interface/ActorStats.lua')
for _,name in ipairs{'str','dex','mag','wil','cun','con','lck'} do stats:defineStat(name,name,10,1,100,'test') end
local dialog,dialog_env=nativeModule('game/modules/tome/dialogs/LevelupDialog.lua','/mod/dialogs/LevelupDialog.lua',
    {config={settings={cheat=false}}},'-- UI Stuff')
local actor={}
for k,v in pairs(base) do actor[k]=v end
for k,v in pairs(stats) do actor[k]=v end
local actor_env=setmetatable({_M=actor,engine={interface={ActorTalents=base}},util=util,
    _t=function(v) return v end,oldGetTalentTypeMastery=base.getTalentTypeMastery},{__index=_G})
local function extract(path,name,source,env)
    local file=read(path)
    local first=assert(file:find('function _M:'..name..'%('))
    local last=file:find('\nfunction _M:',first+1) or #file+1
    local chunk=assert(loadstring(file:sub(first,last-1),'@'..source));setfenv(chunk,env);chunk()
end
for _,name in ipairs{'getTalentTypeMastery','lastLearntTalentsMax','capLastLearntTalents','learnTalent','unlearnTalent',
    'checkPool','learnPool','updateTalentTypeMastery','canLearnTalent','udpateSustains','onStatChange',
    'getTalentCooldown','startTalentCooldown','alterTalentLevelRaw'} do
    extract('game/modules/tome/class/Actor.lua',name,'/mod/class/Actor.lua',actor_env)
end
extract('game/engines/default/engine/Entity.lua','attr','/engine/Entity.lua',actor_env)
local class_source=read('game/engines/default/engine/class.lua')
local first=assert(class_source:find('local function clonerecurs%(d%)'))
local last=assert(class_source:find('%-%-%- Automatically called by cloneFull',first))
local chunk=assert(loadstring(class_source:sub(first,last-1),'@/engine/class.lua'));setfenv(chunk,actor_env);chunk()
local function native(source,body)
    local fn=assert(loadstring('return function(self,...) '..body..' end','@'..source))()
    return fn
end
dialog.triggerHook=native('/engine/class.lua','self.actor.hook_calls=(self.actor.hook_calls or 0)+1')
package.preload['mod.dialogs.LevelupDialog']=function() return dialog end
local definitions,types=base.talents_def,base.talents_types_def
local defenv=setmetatable({_t=function(v) return v end,load=function() end,require=function() return {} end,
    newTalentType=function(t) base:newTalentType(t) end,
    newTalent=function(t)
        if types[t.type[1]] and types[t.type[1]].generic then t.generic=true end
        base:newTalent(t)
    end}, {__index=_G})
base:newTalentType{type='base/class',name='Base',hide=true}
for _,path in ipairs{'techniques/techniques.lua','cunning/cunning.lua','techniques/2h-assault.lua',
    'techniques/strength-of-the-berserker.lua','techniques/combat-techniques.lua','techniques/combat-training.lua',
    'techniques/conditioning.lua','techniques/superiority.lua','techniques/warcries.lua','techniques/bloodthirst.lua',
    'cunning/survival.lua','cunning/dirty.lua'} do
    local fn=assert(loadfile('game/modules/tome/data/talents/'..path));setfenv(fn,defenv);fn()
end
actor.talents_def=definitions;actor.talents_types_def=types;actor.resources_def={}
local defaults={
    ['technique/2hweapon-assault']=true,['technique/strength-of-the-berserker']=true,
    ['technique/combat-techniques-active']=true,['technique/combat-techniques-passive']=true,
    ['technique/combat-training']=true,['technique/conditioning']=true,
    ['technique/superiority']=false,['technique/warcries']=false,['technique/bloodthirst']=false,
    ['cunning/survival']=true,['cunning/dirty']=false,
}
function actor:registerCallbacks() self.register_calls=self.register_calls+1 end
function actor:unregisterCallbacks() end
function actor:fireTalentCheck(name) self.callback_calls[name]=(self.callback_calls[name] or 0)+1 end
function actor:recomputeRegenResources() self.regen_calls=self.regen_calls+1 end
function actor:checkEncumbrance() self.encumbrance_calls=self.encumbrance_calls+1 end
function actor:hasEffect() return nil end
function actor:triggerHook() return nil end
function actor:combatTalentScale(t,lo,hi) return lo+(hi-lo)*self:getTalentLevelRaw(t)/5 end
function actor:combatTalentLimit(t,limit,lo,hi)
    local value=self:combatTalentScale(t,lo,hi)
    return limit<lo and math.max(limit,value) or math.min(limit,value)
end
function actor:combatStatLimit() return 0.1 end
function actor:combatScale(value) return value end
function actor:talentTemporaryValue(values,field,value)
    self.passive_calls=self.passive_calls+1
    values.__tmpvals=values.__tmpvals or {};values.__tmpvals[#values.__tmpvals+1]={field,#values.__tmpvals+1}
    if type(value)=='number' then self[field]=(self[field] or 0)+value end
end
function actor:addTemporaryValue(field,value) self[field]=(self[field] or 0)+value;return 1 end
function actor:removeTemporaryValue() end
function actor:forceUseTalent(tid,flags)
    self.sustain_refreshes=self.sustain_refreshes+1
    check(flags.ignore_energy and flags.ignore_cd and flags.no_talent_fail,'native sustain refresh flags preserved')
    return true
end
local function fixture()
    local p=setmetatable({__is_actor=true,player=true,uid=1,name='Cornac Berserker',x=2,y=2,level=3,
        descriptor={race='Human',subrace='Cornac',class='Warrior',subclass='Berserker'},
        unused_stats=9,unused_talents=5,unused_generics=4,unused_talents_types=1,unused_prodigies=0,
        stats={},inc_stats={},energy={value=1000},life=160,max_life=160,inc_resource_multi={},
        talents={T_STUNNING_BLOW_ASSAULT=1,T_WARSHOUT_BERSERKER=1,T_ARMOUR_TRAINING=1,T_WEAPON_COMBAT=1,T_WEAPONS_MASTERY=1},
        talents_auto={},
        resource_pool_refs={},tmp={},
        talents_types=copy(defaults),talents_types_mastery={},talents_mastery_bonus={},talents_cd={},talents_learn_vals={},
        sustain_talents={},talents_add_levels={},talent_cd_reduction={},turn_procs={},
        last_learnt_talents={class={},generic={}},callback_calls={},register_calls=0,regen_calls=0,
        encumbrance_calls=0,passive_calls=0,sustain_refreshes=0}, {__index=actor})
    for name,def in pairs(stats.stats_def) do if type(name)=='string' then p.stats[def.id]=15;p.inc_stats[def.id]=0 end end
    p.stats[stats.STAT_CON]=13
    local g={player=p,level={level=2},dialogs={},logPlayer=function() end,log=function() end,w=1000}
    base_env.game=g;actor_env.game=g;dialog_env.game=g;defenv.game=g
    return g,p
end
local function find(list,key,value) for _,entry in ipairs(list) do if entry[key]==value then return entry end end end
local function talent(tree,tid)
    for _,category in ipairs(tree.categories) do local t=find(category.talents,'id',tid);if t then return t end end
end
local g,p=fixture()
for _,kind in ipairs{'spend_stat','learn_talent','learn_category','unlearn_talent'} do check(Progression.isAction(kind),'growth action '..kind) end
check(Progression.validate{type='spend_stat',stat='str'}.stat=='str','stat schema')
for _,action in ipairs{
    {type='spend_stat',stat='lck'},{type='spend_stat',stat='STR'},{type='spend_stat',stat='str',amount=2},
    {type='learn_talent',talent_id=''},{type='learn_talent',talent_id='T_VITALITY',force=true},
    {type='learn_category',category_id='cunning/dirty',points=1},{type='learn_category',category_id=1},
} do check(not Progression.validate(action),'invalid/bypass growth action rejected') end
local before=Json.encode({p.stats,p.talents,p.talents_types,p.unused_stats,p.unused_talents,p.unused_generics,p.unused_talents_types})
local tree=Progression.describe(g,p)
check(#tree.stats==6 and #tree.categories==11 and tree.points.stats==9 and tree.points.class==5
    and tree.points.generic==4 and tree.points.category==1,'native visible growth tree and point pools')
check(find(tree.categories,'id','cunning/dirty').known==false,'owned locked categories retained')
check(talent(tree,'T_WEAPONS_MASTERY').point_cost.pool=='generic' and talent(tree,'T_STUNNING_BLOW_ASSAULT').point_cost.pool=='class','native class/generic costs')
check(talent(tree,'T_EXOTIC_WEAPONS_MASTERY')==nil and not find(tree.categories,'id','base/class'),'hidden skills and categories omitted')
local count=0
for _,category in ipairs(tree.categories) do
    check(category.supported,'reviewed native category supported '..category.id..' '..tostring(category.readiness_reason))
    for _,t in ipairs(category.talents) do
        count=count+1;check(t.supported,'reviewed native talent supported '..t.id..' '..tostring(t.readiness_reason))
        local def=definitions[t.id]
        local req=type(def.require)=='function' and def.require(p,def) or def.require
        for stat,required in pairs(req.stat or {}) do
            check(t.requirements.stats[stat]==util.getval(required,(p.talents[t.id] or 0)+1),'requirement arithmetic matches native '..t.id)
        end
        if req.level then check(t.requirements.required_level==util.getval(req.level,(p.talents[t.id] or 0)+1),'level requirement matches native '..t.id) end
    end
end
check(count==46,'all 46 ordinary visible Berserker talents described')
check(before==Json.encode({p.stats,p.talents,p.talents_types,p.unused_stats,p.unused_talents,p.unused_generics,p.unused_talents_types})
    and p.callback_calls.callbackOnTalentChange==nil and not p.is_dialog_talent_leveling,'describing growth is read-only')
check(talent(tree,'T_DEATH_DANCE_ASSAULT').readiness=='blocked' and talent(tree,'T_DEATH_DANCE_ASSAULT').readiness_reason=='talent_level_requirement','next-tier level refusal visible')
check(talent(tree,'T_DIRTY_FIGHTING').readiness_reason=='category_locked','locked category prevents talent spend')
check(find(tree.categories,'id','technique/bloodthirst').readiness_reason=='category_level_requirement','category minimum level visible')
p.levelup_hide_unknown_catgories=true
check(#Progression.describe(g,p).categories==7 and Progression.execute(g,{type='learn_category',category_id='cunning/dirty'}).code=='category_not_in_growth_tree',
    'native hide-unknown-category option restricts visible trees and writes')
p.levelup_hide_unknown_catgories=nil

local result=Progression.execute(g,{type='spend_stat',stat='str'})
check(result.ok and result.points_spent==1 and result.energy_spent==0 and p.stats[stats.STAT_STR]==16
    and p.unused_stats==8 and p.encumbrance_calls==1 and p.callback_calls.callbackOnStatChange==1,'native stat spend with derived-stat callback')
check(not p.is_dialog_talent_leveling and not p.no_last_learnt_talents_cap,'native unload clears temporary flags')
result=Progression.execute(g,{type='spend_stat',stat='con'})
check(result.ok and p.max_life==164 and p.unused_stats==7,'native Constitution increases maximum life')
result=Progression.execute(g,{type='learn_talent',talent_id='T_STUNNING_BLOW_ASSAULT'})
check(result.ok and p.talents.T_STUNNING_BLOW_ASSAULT==2 and p.unused_talents==4 and not p.talents_cd.T_STUNNING_BLOW_ASSAULT,'existing talent spends one class point without starting new cooldown')
result=Progression.execute(g,{type='learn_talent',talent_id='T_RUSH'})
check(result.ok and p.talents.T_RUSH==1 and p.unused_talents==3 and p.talents_cd.T_RUSH==p:getTalentCooldown(definitions.T_RUSH),
    'new talent uses native finish cooldown: '..Json.encode(result)..' points='..tostring(p.unused_talents)..' cd='..tostring(p.talents_cd.T_RUSH)..' expected='..tostring(p:getTalentCooldown(definitions.T_RUSH)))
check(p.register_calls==1 and p.callback_calls.callbackOnTalentChange==2 and p.regen_calls>=2,'native learning callbacks and resources updated')
result=Progression.execute(g,{type='learn_talent',talent_id='T_QUICK_RECOVERY'})
check(result.ok and p.passive_calls>0 and p.stamina_regen>0,'native passive application preserved')
result=Progression.execute(g,{type='learn_talent',talent_id='T_VITALITY'})
check(result.ok and p.unused_generics==3 and p.talents.T_VITALITY==1,'generic talent uses generic pool')
p.sustain_talents.T_BERSERKER_RAGE=true;p.talents.T_BERSERKER_RAGE=1
result=Progression.execute(g,{type='spend_stat',stat='str'})
check(result.ok and p.sustain_refreshes==2,'native finish refreshes known sustains')
p.sustain_talents={}
result=Progression.execute(g,{type='learn_category',category_id='cunning/dirty'})
check(result.ok and p.talents_types['cunning/dirty'] and p.unused_talents_types==0 and p.hook_calls==1,'native category unlock and levelup hook')
result=Progression.execute(g,{type='learn_category',category_id='technique/2hweapon-assault'})
check(not result.ok and result.code=='insufficient_category_points','spent category pool rejects further allocation')

g,p=fixture();p.talents_types_mastery['technique/2hweapon-assault']=0.3
result=Progression.execute(g,{type='learn_category',category_id='technique/2hweapon-assault'})
check(result.ok and math.abs(p.talents_types_mastery['technique/2hweapon-assault']-0.5)<0.000001
    and p.__increased_talent_types['technique/2hweapon-assault']==1 and p.talents.T_STUNNING_BLOW_ASSAULT==1,'native category mastery improves once without raw skill gain')
p.unused_talents_types=1
result=Progression.execute(g,{type='learn_category',category_id='technique/2hweapon-assault'})
check(not result.ok and result.code=='category_already_improved' and p.unused_talents_types==1,'one-mastery-increase limit retained')
g,p=fixture()
local rejected={
    {{type='learn_talent',talent_id='T_DEATH_DANCE_ASSAULT'},'talent_level_requirement'},
    {{type='learn_talent',talent_id='T_DIRTY_FIGHTING'},'category_locked'},
    {{type='learn_talent',talent_id='T_THICK_SKIN'},'talent_stat_requirement'},
    {{type='learn_talent',talent_id='T_EXOTIC_WEAPONS_MASTERY'},'talent_not_in_growth_tree'},
    {{type='learn_talent',talent_id='T_NO_SUCH_TALENT'},'talent_not_in_growth_tree'},
    {{type='learn_category',category_id='technique/bloodthirst'},'category_level_requirement'},
    {{type='learn_category',category_id='base/class'},'category_not_in_growth_tree'},
}
for _,case in ipairs(rejected) do
    result=Progression.execute(g,case[1]);check(not result.ok and result.code==case[2] and not result.uncertain,'native-boundary refusal '..case[2])
end
p.unused_stats=0;p.unused_talents=0;p.unused_generics=0;p.unused_talents_types=0
for _,action in ipairs{{type='spend_stat',stat='str'},{type='learn_talent',talent_id='T_STUNNING_BLOW_ASSAULT'},
    {type='learn_talent',talent_id='T_VITALITY'},{type='learn_category',category_id='cunning/dirty'}} do
    result=Progression.execute(g,action)
    check(not result.ok and result.code:find('insufficient_',1,true) and not result.uncertain,'insufficient pool is a clean refusal')
end
g,p=fixture();p.stats[stats.STAT_STR]=25
check(Progression.execute(g,{type='spend_stat',stat='str'}).code=='stat_level_limit','native level-based stat cap')
p.level=50;p.stats[stats.STAT_STR]=60
check(Progression.execute(g,{type='spend_stat',stat='str'}).code=='stat_maximum','native absolute stat cap')
p.stats[stats.STAT_STR]=40;p.talents.T_STUNNING_BLOW_ASSAULT=5
check(Progression.execute(g,{type='learn_talent',talent_id='T_STUNNING_BLOW_ASSAULT'}).code=='talent_maximum','native raw talent cap')
p.talents.T_STUNNING_BLOW_ASSAULT=1
check(Progression.execute(g,{type='learn_talent',talent_id='T_DEATH_DANCE_ASSAULT'}).code=='talent_lower_tier_requirement','native lower-tier talent count prerequisite')
p.no_levelup_access=1
check(Progression.execute(g,{type='spend_stat',stat='str'}).code=='levelup_access_blocked'
    and find(Progression.describe(g,p).stats,'stat','str').readiness_reason=='levelup_access_blocked','native game levelup access restriction')
p.no_levelup_access=nil;g.dialogs={{}}
check(Progression.execute(g,{type='spend_stat',stat='str'}).code=='player_busy','growth cannot pass an existing dialog')

-- Query sentinels must never run even for unknown/modded requirements/info.
g,p=fixture()
local forbidden_calls=0
local function forbidden() forbidden_calls=forbidden_calls+1;error('query invoked a callback') end
local old_info=definitions.T_VITALITY.info;definitions.T_VITALITY.info=forbidden
local old_require=definitions.T_STUNNING_BLOW_ASSAULT.require;definitions.T_STUNNING_BLOW_ASSAULT.require=forbidden
p.canLearnTalent=forbidden;p.clone=forbidden
tree=Progression.describe(g,p)
check(forbidden_calls==0 and talent(tree,'T_STUNNING_BLOW_ASSAULT').requirements.status=='unknown','dynamic query callbacks remain untouched')
check(Progression.execute(g,{type='learn_talent',talent_id='T_STUNNING_BLOW_ASSAULT'}).code=='progression_native_modified','modified native learning entry rejected')
definitions.T_VITALITY.info=old_info;definitions.T_STUNNING_BLOW_ASSAULT.require=old_require
p.canLearnTalent=nil;p.clone=nil
p.cloned=forbidden
check(Progression.execute(g,{type='spend_stat',stat='str'}).code=='progression_native_modified' and forbidden_calls==0,'unknown clone hook rejected before native mutation')
p.cloned=nil
local original=definitions.T_STUNNING_BLOW_ASSAULT.require
definitions.T_STUNNING_BLOW_ASSAULT.require=defenv.techs_req4
check(not talent(Progression.describe(g,p),'T_STUNNING_BLOW_ASSAULT').supported,'swapped native requirement family rejected')
definitions.T_STUNNING_BLOW_ASSAULT.require=original
local empty=Progression.describe({}, {})
check(#empty.stats==6 and #empty.categories==0 and empty.points.stats=='unknown','missing actor fields yield unknown safely')

-- A native callback exception after mutation must be surfaced for runtime
-- isolation; no synthetic rollback may conceal callbacks already performed.
g,p=fixture();p.stats[stats.STAT_STR]=20
local old_learn=definitions.T_ARMOUR_TRAINING.on_learn
definitions.T_ARMOUR_TRAINING.on_learn=native('data/talents/techniques/combat-training.lua','error("native callback failure")')
result=Progression.execute(g,{type='learn_talent',talent_id='T_ARMOUR_TRAINING'})
check(not result.ok and result.uncertain and result.code=='progression_execution_error' and result.error:find('native callback failure',1,true)
    and p.talents.T_ARMOUR_TRAINING==2 and not p.is_dialog_talent_leveling,'partial native exception is explicit and transient flags cleaned')
definitions.T_ARMOUR_TRAINING.on_learn=old_learn
g,p=fixture();p.energy.value=0/0
check(Progression.execute(g,{type='spend_stat',stat='str'}).code=='progression_energy_unavailable' and p.unused_stats==9,
    'non-finite energy rejected before native mutation')
g,p=fixture();p.stats[stats.STAT_STR]=20
definitions.T_ARMOUR_TRAINING.on_learn=native('data/talents/techniques/combat-training.lua','self.energy=nil')
result=Progression.execute(g,{type='learn_talent',talent_id='T_ARMOUR_TRAINING'})
check(not result.ok and result.uncertain and result.code=='progression_execution_error'
    and result.native_message:find('energy unavailable',1,true),'missing post-native energy is uncertain')
definitions.T_ARMOUR_TRAINING.on_learn=old_learn
g,p=fixture();p.level=10;p.stats[stats.STAT_STR]=40
local old_close=definitions.T_STUNNING_BLOW_ASSAULT.on_levelup_close
local old_changed=definitions.T_STUNNING_BLOW_ASSAULT.on_levelup_changed
definitions.T_STUNNING_BLOW_ASSAULT.on_levelup_close=native('data/talents/techniques/2h-assault.lua',
    'self.close_calls=(self.close_calls or 0)+1;self.close_dialog=select(6,...)')
definitions.T_STUNNING_BLOW_ASSAULT.on_levelup_changed=native('data/talents/techniques/2h-assault.lua','self.changed_calls=(self.changed_calls or 0)+1')
result=Progression.execute(g,{type='learn_talent',talent_id='T_STUNNING_BLOW_ASSAULT'})
check(result.ok and p.close_calls==1 and p.close_dialog==true and p.changed_calls==1,'native finish callbacks run once with dialog semantics')
definitions.T_STUNNING_BLOW_ASSAULT.on_levelup_close=old_close;definitions.T_STUNNING_BLOW_ASSAULT.on_levelup_changed=old_changed
g,p=fixture();p.level=50;p.stats[stats.STAT_STR]=40
for _,tid in ipairs{'T_STUNNING_BLOW_ASSAULT','T_WARSHOUT_BERSERKER','T_STUNNING_BLOW_ASSAULT','T_WARSHOUT_BERSERKER','T_RUSH'} do
    check(Progression.execute(g,{type='learn_talent',talent_id=tid}).ok,'native class history allocation '..tid)
end
check(#p.last_learnt_talents.class==4 and p.last_learnt_talents.class[1]=='T_WARSHOUT_BERSERKER'
    and p.last_learnt_talents.class[4]=='T_RUSH','native unload caps respec history')
g,p=fixture();p.inc_stats[stats.STAT_STR]=10
check(talent(Progression.describe(g,p),'T_ARMOUR_TRAINING').readiness=='available'
    and p:canLearnTalent(definitions.T_ARMOUR_TRAINING),'native requirements include temporary stat bonuses')

-- Bounded unknown trees, quote-heavy IDs and control-heavy labels.
g,p=fixture()
local extra={}
for i=1,40 do
    local category=string.rep('"',200)..i
    p.talents_types[category]=false
    local c={type=category,name=string.rep('\1"',1000),talents={}}
    types[category]=c;extra[#extra+1]=category
    for j=1,32 do
        c.talents[j]={id=string.rep('"',230)..i..'/'..j,name=string.rep('"',1000),type={category,j},points=5}
    end
end
tree=Progression.describe(g,p)
check(tree.categories_truncated and tree.talents_truncated and #Json.encode(tree)<=96*1024,'growth inspection bounds quote-heavy unknown trees')
for _,category in ipairs(extra) do types[category]=nil end
-- Native respec: only recently learnt talent points can be refunded.
g,p=fixture()
check(Progression.isAction('unlearn_talent'),'respec action exposed')
for _,action in ipairs{
    {type='unlearn_talent'},{type='unlearn_talent',talent_id=''},{type='unlearn_talent',talent_id='T_RUSH',points=1},
} do check(not Progression.validate(action),'invalid respec action rejected') end
check(#Progression.describe(g,p).respec.unlearnable==0,'no respec candidates before learning')
result=Progression.execute(g,{type='learn_talent',talent_id='T_RUSH'})
check(result.ok and p.talents.T_RUSH==1 and p.unused_talents==4,'learned talent for respec')
local candidates=Progression.describe(g,p).respec.unlearnable
check(#candidates==1 and candidates[1].id=='T_RUSH' and candidates[1].available==true,'recently learnt talent is refundable')
result=Progression.execute(g,{type='unlearn_talent',talent_id='T_RUSH'})
check(result.ok and result.points_returned==1 and result.point_pool=='class' and result.previous_value==1 and result.new_value==0
    and (p.talents.T_RUSH or 0)==0 and p.unused_talents==5 and #p.last_learnt_talents.class==0,'native talent respec refunds one point and clears history')
check(Progression.execute(g,{type='unlearn_talent',talent_id='T_RUSH'}).code=='talent_not_learned','a fully refunded talent cannot be refunded again')
result=Progression.execute(g,{type='unlearn_talent',talent_id='T_STUNNING_BLOW_ASSAULT'})
check(not result.ok and result.code=='talent_not_recently_learnt','initial talents are not refundable without history')
g,p=fixture()
Progression.execute(g,{type='learn_talent',talent_id='T_RUSH'})
p.in_combat=true
check(Progression.execute(g,{type='unlearn_talent',talent_id='T_RUSH'}).code=='respec_in_combat','in-combat respec refused')
g.level.data={allow_respec='limited'}
check(Progression.execute(g,{type='unlearn_talent',talent_id='T_RUSH'}).ok,'limited allow_respec permits in-combat refund')
g,p=fixture()
Progression.execute(g,{type='learn_talent',talent_id='T_RUSH'})
p.item_talent_levels_learnt={T_RUSH=1}
check(Progression.execute(g,{type='unlearn_talent',talent_id='T_RUSH'}).code=='talent_item_granted','item-granted levels are protected')
-- F-2: an alchemy golem must not block player progression/respec.
g,p=fixture();p.alchemy_golem={}
check(Progression.describe(g,p).categories[1].supported,'progression is available with an alchemy golem present')
check(Progression.execute(g,{type='spend_stat',stat='str'}).ok and p.stats[stats.STAT_STR]==16,'stat spend works with a golem present')
check(Progression.execute(g,{type='learn_talent',talent_id='T_RUSH'}).ok,'learning works with a golem present')
result=Progression.execute(g,{type='unlearn_talent',talent_id='T_RUSH'})
check(result.ok and result.points_returned==1,'respec works with a golem present')
print('Progression: '..checks..' checks passed')
