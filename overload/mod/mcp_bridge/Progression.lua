-- GPL-3.0-or-later. Single-point adapters for the native LevelupDialog.
-- Queries never call canLearnTalent, talent info/require functions, or clone.
-- v1.6 (review-disposition D11 superseded): every reviewed definition/player
-- method is called as a LIVE entrypoint with structural (presence/callable/type)
-- checks only — a replaced-but-callable function is used, a missing/erroring/
-- non-finite one fails typed. Source identity is never an availability gate;
-- provenance stays advisory telemetry (NativeCompatibility).
-- v1.7 (NEW-01): because a replaced-but-callable entrypoint is genuinely called,
-- a success is only published after the point pool AND the target are re-read
-- after the last live native call that can still mutate them: the dialog method
-- (incStat/learnTalent/learnType), the finish callbacks
-- (on_levelup_close/on_levelup_changed) and the unload cleanup
-- (capLastLearntTalents). Any final disagreement is a typed, uncertain failure
-- (`native_progression_mismatch`, uncertain=true), never ok=true.
local Json = require 'mod.mcp_bridge.Json'
local D = require 'mod.mcp_bridge.ObservationDetails'
local M = {}
local stat_names={'str','dex','mag','wil','cun','con'}
local stats_allowed={str=true,dex=true,mag=true,wil=true,cun=true,con=true}
local pools={stats='unused_stats',class='unused_talents',generic='unused_generics',category='unused_talents_types',prodigy='unused_prodigies'}
local STAT='/engine/interface/ActorStats.lua'
local TALENT='/engine/interface/ActorTalents.lua'
local ACTOR='/mod/class/Actor.lua'
local LEVELUP='/mod/dialogs/LevelupDialog.lua'
local categories,talents={},{}
local function addCategory(id,file,requirement,ids,generic,minimum)
    local c={id=id,file='data/talents/'..file,requirement=requirement,generic=generic==true,minimum=minimum or 0}
    categories[id]=c
    for tier,short in ipairs(ids) do
        local tid='T_'..short
        talents[tid]={id=tid,category=id,file=c.file,requirement=requirement,tier=tier,generic=c.generic}
    end
end
addCategory('technique/2hweapon-assault','techniques/2h-assault.lua','str',
    {'STUNNING_BLOW_ASSAULT','FEARLESS_CLEAVE','DEATH_DANCE_ASSAULT','EXECUTION'})
addCategory('technique/strength-of-the-berserker','techniques/strength-of-the-berserker.lua','str',
    {'WARSHOUT_BERSERKER','BERSERKER_RAGE','SHATTERING_BLOW','RELENTLESS_FURY'})
addCategory('technique/combat-techniques-active','techniques/combat-techniques.lua','strdex',
    {'RUSH','PRECISE_STRIKES','PERFECT_STRIKE','BLINDING_SPEED'})
addCategory('technique/combat-techniques-passive','techniques/combat-techniques.lua','strdex',
    {'QUICK_RECOVERY','FAST_METABOLISM','SPELL_SHIELD','UNENDING_FRENZY'})
addCategory('technique/conditioning','techniques/conditioning.lua','con',
    {'VITALITY','UNFLINCHING_RESOLVE','DAUNTING_PRESENCE','ADRENALINE_SURGE'},true)
addCategory('technique/superiority','techniques/superiority.lua','str_high',
    {'JUGGERNAUT','ONSLAUGHT','BATTLE_CALL','SHATTERING_IMPACT'},false,10)
addCategory('technique/warcries','techniques/warcries.lua','str_high',
    {'SHATTERING_SHOUT','SECOND_WIND','BATTLE_SHOUT','BATTLE_CRY'},false,10)
addCategory('technique/bloodthirst','techniques/bloodthirst.lua','str_high',
    {'MORTAL_TERROR','BLOODBATH','BLOODY_BUTCHER','UNSTOPPABLE'},false,10)
addCategory('cunning/survival','cunning/survival.lua','cun',
    {'HEIGHTENED_SENSES','DEVICE_MASTERY','TRACK','DANGER_SENSE'},true)
addCategory('cunning/dirty','cunning/dirty.lua','cun',
    {'DIRTY_FIGHTING','BACKSTAB','BLINDING_POWDER','TWIST_THE_KNIFE'})
addCategory('technique/combat-training','techniques/combat-training.lua','training',
    {'THICK_SKIN','ARMOUR_TRAINING','LIGHT_ARMOUR_TRAINING','WEAPON_COMBAT','WEAPONS_MASTERY','KNIFE_MASTERY','EXOTIC_WEAPONS_MASTERY'},true)
local training={
    T_THICK_SKIN={stat='con',line=26,formula=function(level) return 14+level*9 end},
    T_ARMOUR_TRAINING={stat='str',line=45,formula=function(level) return 16+(level+2)*(level-1) end},
    T_LIGHT_ARMOUR_TRAINING={stat='dex',line=124,formula=function(level) return 16+(level+2)*(level-1) end},
    T_WEAPON_COMBAT={level=true,line=166,formula=function(level) return (level-1)*4 end},
    T_WEAPONS_MASTERY={stat='str',line=181,formula=function(level) return 12+level*6 end},
    T_KNIFE_MASTERY={stat='dex',line=199,formula=function(level) return 10+level*6 end},
    T_EXOTIC_WEAPONS_MASTERY={stat='str',second_stat='dex',line=217,formula=function(level) return 10+level*6 end},
}
local function integer(value) return D.finite(value) and value%1==0 and value>=0 end
local function id(value) return type(value)=='string' and #value>0 and #value<=256 and not value:find('%z') end
local function active(value) return value~=nil and value~=false and value~=0 end
local function tableOrEmpty(value) return type(value)=='table' and value or {} end
local function field(p,name,key)
    local value=p[name]
    if type(value)=='table' then return value[key] end
end
local function known(p,category) return field(p,'talents_types',category) and true or false end
-- NEW-04 (NEW-03 shared read): the category target value is computed without
-- any unvalidated arithmetic. A known category needs a finite number mastery
-- to be comparable; a missing one means 1 (the native default); a wrong-typed
-- or non-finite one is `nil` (typed mismatch), never an escaping error.
local function categoryTargetValue(p,category)
    if not known(p,category) then return false end
    local mastery=field(p,'talents_types_mastery',category)
    if mastery==nil then return 1 end
    if D.finite(mastery) then return mastery+1 end
    return nil
end
local function rawLevel(p,tid)
    local value=field(p,'talents',tid)
    if value==nil then return 0 end
    return integer(value) and value or nil
end
-- Static, read-only list of unmet require fields. This never runs a talent's
-- `special` function; that is reported as checked natively.
local function staticMissing(p,t)
    local out={}
    local req=type(t)=='table' and t.require or nil
    if type(req)=='table' then
        if D.finite(req.level) and (D.number(p.level) or 0)<req.level then
            out[#out+1]={kind='level',required=req.level,current=D.number(p.level)}
        end
        if type(req.stat)=='table' and D.finite(req.stat[2]) then
            local def=p.stats_def and p.stats_def[req.stat[1]]
            local id=type(def)=='table' and def.id or req.stat[1]
            local cur=type(p.stats)=='table' and D.number(p.stats[id]) or nil
            if cur==nil or cur<req.stat[2] then
                out[#out+1]={kind='stat',stat=D.text(req.stat[1],32),required=req.stat[2],current=cur}
            end
        end
        if type(req.talent)=='table' and D.finite(req.talent[2]) then
            local known=rawLevel(p,req.talent[1])
            if (known or 0)<req.talent[2] then
                out[#out+1]={kind='talent',talent=D.text(req.talent[1],64),required=req.talent[2],current=known}
            end
        end
        if req.special~=nil then out[#out+1]={kind='special',checked='native'} end
    end
    return out
end
local function rejectionFields(p,aid)
    local t=aid and p.talents_def and p.talents_def[aid] or nil
    return {missing=staticMissing(p,t),
        missing_scope='static require fields only; special/lua prerequisites are checked natively'}
end
local function callable(value) return type(value)=='function' end
local function onlyKeys(t,allowed)
    if type(t)~='table' then return false end
    for key in pairs(t) do if not allowed[key] then return false end end
    return true
end
function M.isAction(kind) return kind=='spend_stat' or kind=='learn_talent' or kind=='learn_category' or kind=='unlearn_talent' end
function M.validate(action)
    if type(action)~='table' then return nil,'invalid_action' end
    local result,allowed={type=action.type},{type=true}
    if action.type=='spend_stat' then
        if not stats_allowed[action.stat] then return nil,'invalid_stat' end
        result.stat=action.stat;allowed.stat=true
    elseif action.type=='learn_talent' then
        if not id(action.talent_id) then return nil,'invalid_talent_id' end
        result.talent_id=action.talent_id;allowed.talent_id=true
    elseif action.type=='unlearn_talent' then
        -- Native respec is limited to refunding a recently learnt talent point.
        if not id(action.talent_id) then return nil,'invalid_talent_id' end
        result.talent_id=action.talent_id;allowed.talent_id=true
    elseif action.type=='learn_category' then
        if not id(action.category_id) then return nil,'invalid_category_id' end
        result.category_id=action.category_id;allowed.category_id=true
    else return nil,'unsupported_action' end
    for key in pairs(action) do if not allowed[key] then return nil,'unexpected_action_field' end end
    return result
end
local function statValues(p,name)
    local def=field(p,'stats_def',name)
    if type(def)~='table' or not integer(def.id) then return nil,nil,nil,nil end
    local base,bonus=field(p,'stats',def.id),field(p,'inc_stats',def.id)
    -- v1.6: the live native getter is the entrypoint. A replaced-but-callable
    -- getStat is called and used; only a missing/non-callable getter or a
    -- non-finite result is a typed unknown. Source identity is not consulted.
    if not D.finite(base) or not D.finite(bonus) or not D.finite(def.min) or not D.finite(def.max)
        or type(p.getStat)~='function' then return D.number(base),D.number(bonus),nil,def end
    local ok,value,raw=pcall(function()
        return p:getStat(def.id),p:getStat(def.id,nil,nil,true)
    end)
    if not ok or not D.finite(value) or not D.finite(raw) then
        return D.number(base),D.number(bonus),nil,def
    end
    return base,bonus,value,def,raw
end
local function maxPoints(p,t)
    if not integer(t.points) or t.points<1 or not integer(p.level) then return nil end
    if t.points==1 then return 1 end
    local extra=field(p,'talents_inc_cap',t.id) or 0
    if not integer(extra) then return nil end
    return t.points+math.max(0,math.floor((p.level-50)/10))+extra
end
local function visibleCategory(p,category)
    local c=field(p,'talents_types_def',category)
    return type(c)=='table' and not c.hide and field(p,'talents_types',category)~=nil
        and (known(p,category) or not p.levelup_hide_unknown_catgories) and c or nil
end
local function visibleTalent(p,t)
    return type(t)=='table' and id(t.id) and type(t.type)=='table' and visibleCategory(p,t.type[1])
        and (not t.hide or field(p,'__show_special_talents',t.id)) and true or false
end
local function requirementAudit(t,spec)
    local req=t.require
    local kind=spec.requirement
    -- Structural shape checks against the reviewed declaration families only.
    -- v1.6 (D11 superseded): the reviewed arithmetic is NOT re-verified by
    -- source identity at runtime — a replaced-but-callable requirement function
    -- is used, the native LevelupDialog judges the real requirements, and the
    -- computed hints below stay advisory (native recheck governs execution).
    -- Only a missing/mis-shaped/non-callable declaration fails typed.
    if kind=='str' or kind=='str_high' or kind=='strdex' then return callable(req)
    elseif kind=='con' or kind=='cun' then
        return type(req)=='table' and onlyKeys(req,{stat=true,level=true})
            and onlyKeys(req.stat,{[kind]=true})
            and callable(req.stat[kind]) and callable(req.level)
    elseif kind=='training' then
        local plan=training[t.id]
        if not plan or not onlyKeys(req,{stat=true,level=true}) then return false end
        if plan.level then return req.stat==nil and callable(req.level) end
        local keys={[plan.stat]=true};if plan.second_stat then keys[plan.second_stat]=true end
        return req.level==nil and onlyKeys(req.stat,keys) and callable(req.stat[plan.stat])
            and (not plan.second_stat or callable(req.stat[plan.second_stat]))
    end
    return false
end
local function auditTalent(p,t)
    local spec=type(t)=='table' and talents[t.id]
    if not spec then return nil,'unsupported_progression_talent' end
    if type(t.type)~='table' or t.type[1]~=spec.category or t.type[2]~=(spec.requirement=='training' and 1 or spec.tier)
        or t.points~=5 or t.generic~=nil and type(t.generic)~='boolean' or (t.generic==true)~=spec.generic or t.is_class_evolution or t.is_race_evolution
        or not requirementAudit(t,spec) then return nil,'progression_talent_modified' end
    -- v1.6 (D11 superseded): the definition's function fields are live
    -- entrypoints, not identity-gated. A replaced-but-callable function is
    -- used (the native dialog settles the action); no source audit here.
    return spec
end
local function auditCategory(p,c)
    local spec=type(c)=='table' and categories[c.type]
    if not spec then return nil,'unsupported_progression_category' end
    if c.generic~=nil and type(c.generic)~='boolean' or (c.generic==true)~=spec.generic or (c.min_lev or 0)~=spec.minimum or c.on_mastery_change~=nil
        or type(c.talents)~='table' then return nil,'progression_category_modified' end
    for _,t in ipairs(c.talents) do
        if not auditTalent(p,t) then return nil,'progression_category_modified' end
    end
    return spec
end
-- v1.6: structural availability only. Each listed player method must exist and
-- be callable; the source column is advisory provenance documentation, never a
-- gate (a replaced-but-callable method is used).
local player_methods={
    attr='/engine/Entity.lua',clone='/engine/class.lua',getStat=STAT,getStr=STAT,getDex=STAT,isStatMax=STAT,incStat=STAT,
    onStatChange=ACTOR,udpateSustains=ACTOR,capLastLearntTalents=ACTOR,lastLearntTalentsMax=ACTOR,
    getTalentFromId=TALENT,getTalentLevelRaw=TALENT,getTalentLevel=TALENT,knowTalent=TALENT,
    knowTalentType=TALENT,numberKnownTalent=TALENT,canLearnTalent=ACTOR,learnTalent=ACTOR,unlearnTalent=ACTOR,
    isTalentCoolingDown=TALENT,startTalentCooldown=ACTOR,getTalentTypeMastery=ACTOR,
    learnTalentType=TALENT,setTalentTypeMastery=TALENT,updateTalentTypeMastery=ACTOR,
}
local function playerAudit(p)
    if type(p)~='table' or not integer(p.level) or p.level<1 or p.level>1000 then return nil,'progression_state_unknown' end
    if type(p.energy)~='table' or not D.finite(p.energy.value) then return nil,'progression_energy_unavailable' end
    if active(p.no_levelup_access) then return nil,'levelup_access_blocked' end
    if active(p.is_dialog_talent_leveling) or active(p.no_last_learnt_talents_cap) then return nil,'progression_player_busy' end
    if p.cloned~=nil and type(p.cloned)~='function' then return nil,'progression_native_modified' end
    for method in pairs(player_methods) do
        if type(p[method])~='function' then return nil,'progression_native_modified' end
    end
    return true
end
local function readiness(entry,available,reason,unknown)
    entry.readiness=available and 'available' or unknown and 'unknown' or 'blocked'
    entry.readiness_reason=available and nil or reason
    return entry
end
local function statSummary(p,name)
    local base,bonus,value,def,raw=statValues(p,name)
    local supported,reason=playerAudit(p)
    local result={stat=name,name=type(def)=='table' and D.text(def.name,64) or name,base=base,bonus=bonus,
        effective=value or 'unknown',point_cost={pool='stats',amount=1},supported=supported==true}
    if not supported then return readiness(result,false,reason,true) end
    if not raw or not integer(p.unused_stats) then return readiness(result,false,'progression_state_unknown',true) end
    result.level_limit=p.level*1.4+20;result.absolute_limit=60+math.max(0,p.level-50)
    if p.unused_stats<1 then return readiness(result,false,'insufficient_stat_points') end
    if raw>=result.level_limit then return readiness(result,false,'stat_level_limit') end
    if math.floor(base)>=def.max or raw>=result.absolute_limit then return readiness(result,false,'stat_maximum') end
    return readiness(result,true)
end
local function requirementSummary(p,t,spec)
    local level=rawLevel(p,t.id)
    local result={next_raw_level=level and level+1 or 'unknown',stats={},category_known=known(p,t.type[1]),
        lower_talents_required=math.max(0,(D.number(t.type[2]) or 1)-1),lower_talents_known=0}
    for tid in pairs(tableOrEmpty(p.talents)) do
        local other=field(p,'talents_def',tid)
        if type(other)=='table' and type(other.type)=='table' and other.type[1]==t.type[1] and tid~=t.id
            and (not t.type[2] or not other.type[2] or D.finite(other.type[2]) and D.finite(t.type[2]) and other.type[2]<t.type[2]) then
            result.lower_talents_known=result.lower_talents_known+1
        end
    end
    if not spec or not level then result.status='unknown';return result end
    level=level+1
    local kind=spec.requirement
    if kind=='training' then
        local plan=training[t.id]
        if plan.level then result.required_level=plan.formula(level)
        else
            result.stats[plan.stat]=plan.formula(level)
            if plan.second_stat then result.stats[plan.second_stat]=plan.formula(level) end
        end
    else
        local tier=spec.tier
        local minimum=(kind=='str_high' and 22 or 12)+(tier-1)*8
        result.required_level=(kind=='str_high' and 10 or 0)+(tier-1)*4+level-1
        local stat=kind=='str_high' and 'str' or kind
        if kind=='strdex' then
            local _,_,str=statValues(p,'str');local _,_,dex=statValues(p,'dex')
            if not str or not dex then result.status='unknown';return result end
            stat=str>=dex and 'str' or 'dex'
        end
        result.stats[stat]=minimum+(level-1)*2
    end
    result.status='known'
    return result
end
local function talentSummary(p,t)
    local spec,reason=auditTalent(p,t)
    local native,native_reason=playerAudit(p)
    local level=rawLevel(p,t.id)
    local result={id=t.id,name=D.text(t.name) or t.id,raw_level=level or 'unknown',max_points=maxPoints(p,t) or 'unknown',
        mode=D.text(t.mode,32) or 'unknown',point_cost={pool=t.generic and 'generic' or 'class',amount=1},
        supported=native==true and (spec~=nil or reason=='unsupported_progression_talent'),
        coverage=spec and 'audited' or 'native_generic',
        description_status='dynamic_description_not_evaluated',requirements=requirementSummary(p,t,spec)}
    if not native then return readiness(result,false,native_reason,true) end
    if not spec then
        -- Visible but not in the reviewed list: the native LevelupDialog is the
        -- judge of requirements, caps and points. A tampered reviewed talent is
        -- still rejected by the reason check above.
        if reason~='unsupported_progression_talent' then return readiness(result,false,reason,true) end
        local points=p[pools[result.point_cost.pool]]
        if not integer(points) then return readiness(result,false,'progression_state_unknown',true) end
        if points<1 then return readiness(result,false,'insufficient_'..result.point_cost.pool..'_points') end
        -- The requirement function of an unlisted talent is dynamic and is not
        -- evaluated by a read query; never claim availability here.
        return readiness(result,false,'native_precheck_not_run',true)
    end
    local points=p[pools[result.point_cost.pool]]
    local req=result.requirements
    if not integer(points) or not level or result.max_points=='unknown' or req.status=='unknown' then
        return readiness(result,false,'progression_state_unknown',true)
    end
    if points<1 then return readiness(result,false,'insufficient_'..result.point_cost.pool..'_points') end
    if not req.category_known and not t.type_no_req then return readiness(result,false,'category_locked') end
    if level>=result.max_points then return readiness(result,false,'talent_maximum') end
    if req.required_level and p.level<req.required_level then return readiness(result,false,'talent_level_requirement') end
    for stat,required in pairs(req.stats) do
        local _,_,value=statValues(p,stat)
        if not value then return readiness(result,false,'progression_state_unknown',true) end
        if value<required then return readiness(result,false,'talent_stat_requirement') end
    end
    if req.lower_talents_known<req.lower_talents_required then return readiness(result,false,'talent_lower_tier_requirement') end
    return readiness(result,true)
end
local function categorySummary(p,c)
    local spec,reason=auditCategory(p,c)
    local native,native_reason=playerAudit(p)
    local mastery=field(p,'talents_types_mastery',c.type)
    local improved=field(p,'__increased_talent_types',c.type) or 0
    local result={id=c.type,name=D.text(c.name),known=known(p,c.type),generic=c.generic==true,
        mastery_base=mastery==nil and 1 or D.finite(mastery) and mastery+1 or 'unknown',
        improvements_used=integer(improved) and improved or 'unknown',minimum_level=D.number(c.min_lev) or 0,
        point_cost={pool='category',amount=1},
        supported=native==true and (spec~=nil or reason=='unsupported_progression_category'),
        coverage=spec and 'audited' or 'native_generic',talents=Json.array()}
    result.operation=result.known and 'improve_mastery' or 'unlock'
    result.mastery_increase=result.known and 0.2 or nil
    if not native then return readiness(result,false,native_reason,true) end
    if not spec and reason~='unsupported_progression_category' then return readiness(result,false,reason,true) end
    if not integer(p.unused_talents_types) or not integer(improved) or result.mastery_base=='unknown' then
        return readiness(result,false,'progression_state_unknown',true)
    end
    if result.known and improved>=1 then return readiness(result,false,'category_already_improved') end
    if p.unused_talents_types<1 then return readiness(result,false,'insufficient_category_points') end
    if p.level<result.minimum_level then return readiness(result,false,'category_level_requirement') end
    return readiness(result,true)
end
local function canUnlearn(g,p,tid)
    local t=field(p,'talents_def',tid)
    if not visibleTalent(p,t) then return nil,'talent_not_in_growth_tree' end
    local level=rawLevel(p,tid)
    if not level or level<1 then return nil,'talent_not_learned' end
    if t.no_unlearn_last then return nil,'talent_protected' end
    if p.item_talent_levels_learnt and p.item_talent_levels_learnt[tid]
        and p:getTalentLevelRaw(t)<=p.item_talent_levels_learnt[tid] then return nil,'talent_item_granted' end
    local list=p.last_learnt_talents and p.last_learnt_talents[t.generic and 'generic' or 'class']
    if type(list)~='table' then return nil,'respec_history_unavailable' end
    local max=p:lastLearntTalentsMax(t.generic and 'generic' or 'class')
    if not integer(max) or max<1 then return nil,'respec_history_unavailable' end
    local min=math.max(1,#list-(max-1))
    local found=false
    for i=#list,min,-1 do if list[i]==tid then found=true;break end end
    if not found then return nil,'talent_not_recently_learnt' end
    if active(p.in_combat) and not (g and g.level and g.level.data and g.level.data.allow_respec=='limited') then
        return nil,'respec_in_combat'
    end
    return t
end
local function unlearnableSummary(g,p)
    local out=Json.array()
    if type(p.last_learnt_talents)~='table' then return out end
    local seen={}
    for _,kind in ipairs{'class','generic'} do
        local list=p.last_learnt_talents[kind]
        if type(list)=='table' then
            local max=p:lastLearntTalentsMax(kind)
            if integer(max) and max>=1 then
                local min=math.max(1,#list-(max-1))
                for i=min,#list do
                    local tid=list[i]
                    if not seen[tid] then
                        seen[tid]=true
                        local t,reason=canUnlearn(g,p,tid)
                        if t then out[#out+1]={id=tid,pool=kind,position=i,available=true}
                        else out[#out+1]={id=tid,pool=kind,position=i,available=false,reason=reason} end
                    end
                end
            end
        end
    end
    return out
end
function M.describe(g,p)
    p=p or g and g.player
    local result={points={},stats=Json.array(),categories=Json.array(),readiness_is_advisory=true,
        scope='player-owned visible growth trees; one point per action or refund; native requirements rechecked during execution',
        execution_scope='visible talents in categories the player knows are learnt through the native LevelupDialog (audited trees only add exact requirement hints); recently learnt talent respec; no stat/category respec, prodigies, inscription slots or special evolutions'}
    if type(p)~='table' then result.readiness_reason='no_player';return result end
    result.respec={unlearnable=unlearnableSummary(g,p),
        scope='recently learnt talents only, inside the native last-learnt window and out of combat; stats and unlocked categories are not refundable outside an open native level-up dialog'}
    for key,fieldname in pairs(pools) do result.points[key]=D.number(p[fieldname]) or 'unknown' end
    for _,name in ipairs(stat_names) do result.stats[#result.stats+1]=statSummary(p,name) end
    local keys,truncated=D.keys(p.talents_types,32,function(key) return id(key) and visibleCategory(p,key)~=nil end)
    result.categories_truncated=truncated
    local count=0
    for _,key in ipairs(keys) do
        local c=visibleCategory(p,key)
        local entry=categorySummary(p,c)
        for _,t in ipairs(tableOrEmpty(c.talents)) do
            if visibleTalent(p,t) then
                count=count+1
                if #entry.talents>=16 or count>96 then entry.talents_truncated=true;result.talents_truncated=true
                else entry.talents[#entry.talents+1]=talentSummary(p,t) end
            end
        end
        result.categories[#result.categories+1]=entry
    end
    -- inspect responses do not pass through Observer's snapshot budget.
    while #Json.encode(result)>96*1024 do
        local largest
        for _,entry in ipairs(result.categories) do
            if #entry.talents>0 and (not largest or #entry.talents>#largest.talents) then largest=entry end
        end
        if not largest then result.categories[#result.categories]=nil;result.categories_truncated=true
        else largest.talents[#largest.talents]=nil;largest.talents_truncated=true;result.talents_truncated=true end
        result.truncated=true
    end
    return result
end
-- NEW-03: settlement-time postcondition. `checkPostcondition` re-reads the
-- LIVE player state with the same total, type-safe reads used during execute
-- and compares them against the descriptor recorded when the mutation was
-- accepted. It returns nil when the drained final state still matches, a
-- mismatch reason ('points'/'target'/'invalid_postcondition') otherwise, and
-- never raises: missing/wrong-typed values are mismatches, not errors. No
-- identity/digest/source gate is involved — the reads are live entrypoints.
local function postconditionTarget(p,operation,target)
    if operation=='spend_stat' then
        return type(p.stats)=='table' and p.stats[target] or nil
    elseif operation=='learn_talent' or operation=='unlearn_talent' then
        return rawLevel(p,target)
    elseif operation=='learn_category' then
        return categoryTargetValue(p,target)
    end
end
function M.checkPostcondition(p,spec)
    if type(p)~='table' or type(spec)~='table' then return 'invalid_postcondition' end
    local points=p[spec.pool]
    if not integer(points) or points~=spec.expected_points then return 'points' end
    local value=postconditionTarget(p,spec.operation,spec.target)
    if not D.finite(value) or not D.finite(spec.expected_value)
        or math.abs(value-spec.expected_value)>0.000001 then return 'target' end
end

local dialog_methods={'incStat','learnTalent','learnType','getMaxTPoints','checkDeps','finish','unload'}
local function dialogAudit(dialog)
    if type(dialog)~='table' then return false end
    -- v1.6: structural presence/callable checks only; source identity of the
    -- dialog methods is advisory, never an availability decision.
    for _,method in ipairs(dialog_methods) do if type(dialog[method])~='function' then return false end end
    return type(dialog.triggerHook)=='function'
end
local function busy(g,p)
    return p.dead or g.dialogs and #g.dialogs>0 or g.target_co or g.target and g.target.active
end
local function executeUnlearn(g,p,a)
    local target,code=canUnlearn(g,p,a.talent_id)
    if not target then return {ok=false,code=code,energy_spent=0} end
    local pool=target.generic and 'generic' or 'class'
    if not integer(p[pools[pool]]) then return {ok=false,code='progression_state_unknown',energy_spent=0} end
    local before_points=p[pools[pool]]
    local before_value=rawLevel(p,a.talent_id)
    local before_energy=p.energy.value
    local loaded,dialog=pcall(require,'mod.dialogs.LevelupDialog')
    if not loaded or not dialogAudit(dialog) then return {ok=false,code='levelup_dialog_unavailable',energy_spent=0} end
    local host,native_message,entered=false,nil,false
    local function message(_,title,text) native_message=D.text(text or title,512) end
    -- NEW-01: the refund postcondition (`before_points+1`, raw level exactly one
    -- lower) is re-read after finish and after unload, because the live
    -- on_levelup_close/on_levelup_changed callbacks and the cleanup can undo it.
    local function postconditionMismatch()
        if p[pools[pool]]~=before_points+1 then return 'points' end
        local value=rawLevel(p,a.talent_id)
        if not D.finite(value) or value~=before_value-1 then return 'target' end
    end
    local ok,outcome=pcall(function()
        entered=true
        p.is_dialog_talent_leveling=true;p.no_last_learnt_talents_cap=true
        p.__hidden_talent_types=p.__hidden_talent_types or {}
        p.__increased_talent_types=p.__increased_talent_types or {}
        p.last_learnt_talents=p.last_learnt_talents or {class={},generic={}}
        local backup=p:clone();backup.uid=p.uid
        host=setmetatable({actor=p,actor_dup=backup,on_birth=false,unused_stats=p.unused_stats,
            talents_changed={},talents_learned={},talent_types_learned={},stats_increased={},talents_deps={},
            new_stats_changed=false,new_talents_changed=false,
            updateTooltip=function() end,subtleMessage=message,simplePopup=message,simpleLongPopup=message}, {__index=dialog})
        dialog.learnTalent(host,a.talent_id,false)
        local after_value=rawLevel(p,a.talent_id)
        local refunded=p[pools[pool]]==before_points+1
        if not refunded or not D.finite(after_value) or after_value~=before_value-1 then
            local mutated=p[pools[pool]]~=before_points or after_value~=before_value
            return {ok=false,code=refunded and 'native_progression_mismatch' or 'native_progression_rejected',uncertain=mutated or nil,
                missing=staticMissing(p,p.talents_def and p.talents_def[a.talent_id])}
        end
        if not dialog.finish(host) then return {ok=false,code='native_progression_finish_failed',uncertain=true} end
        if postconditionMismatch() then return {ok=false,code='native_progression_mismatch',uncertain=true} end
        -- NEW-03: the refund was accepted; the command carries the expected
        -- postcondition for the settlement-time re-validation.
        return {ok=true,code='progression_applied',points_returned=1,point_pool=pool,
            previous_value=before_value,new_value=after_value,
            postcondition={pool=pools[pool],expected_points=before_points+1,operation='unlearn_talent',
                target=a.talent_id,expected_value=before_value-1}}
    end)
    local cleanup_ok,cleanup_error=true,nil
    if entered then
        cleanup_ok,cleanup_error=pcall(dialog.unload,host or {actor=p})
        p.is_dialog_talent_leveling=nil;p.no_last_learnt_talents_cap=nil
    end
    if not ok or not cleanup_ok then
        outcome={ok=false,code='progression_execution_error',uncertain=entered or nil,
            error=D.text(tostring(not ok and outcome or cleanup_error),512)}
    elseif outcome.ok then
        -- NEW-04: the after-unload recheck cannot escape; an erroring final
        -- read is a typed uncertain progression failure, never ok=true.
        local checked,mismatch=pcall(postconditionMismatch)
        if not checked then
            outcome={ok=false,code='progression_execution_error',uncertain=true,
                error=D.text(tostring(mismatch),512)}
        elseif mismatch then
            -- unload (the native capLastLearntTalents) and any replaced-but-callable
            -- cleanup ran after finish; the final refund must still hold.
            outcome={ok=false,code='native_progression_mismatch',uncertain=true}
        end
    end
    outcome.native_message=outcome.error or native_message
    local after_energy=type(p.energy)=='table' and D.number(p.energy.value)
    if not after_energy then
        return {ok=false,code='progression_execution_error',uncertain=true,energy_spent=0,
            native_message='Native progression left player energy unavailable.'}
    end
    outcome.energy_spent=math.max(0,before_energy-after_energy)
    return outcome
end
function M.execute(g,action)
    local a,reason=M.validate(action)
    if not a then return {ok=false,code=reason,energy_spent=0} end
    local p=g and g.player
    if not p then return {ok=false,code='no_player',energy_spent=0} end
    if type(p.energy)~='table' or not D.finite(p.energy.value) then
        return {ok=false,code='progression_energy_unavailable',energy_spent=0}
    end
    if busy(g,p) then return {ok=false,code='player_busy',energy_spent=0} end
    local supported,audit_reason=playerAudit(p)
    if not supported then return {ok=false,code=audit_reason,energy_spent=0} end
    if a.type=='unlearn_talent' then
        -- Native respec bypasses the normal respec item/cost, so it is opt-in.
        local settings=config and config.settings and config.settings.tome_mcp_bridge
        if not (type(settings)=='table' and settings.allow_respec==true) then
            return {ok=false,code='respec_not_enabled',energy_spent=0}
        end
        return executeUnlearn(g,p,a)
    end
    local description,target,before_value
    if a.type=='spend_stat' then
        description=statSummary(p,a.stat)
        local def=field(p,'stats_def',a.stat)
        target=type(def)=='table' and def.id
        before_value=target and field(p,'stats',target)
    elseif a.type=='learn_talent' then
        target=field(p,'talents_def',a.talent_id)
        if not visibleTalent(p,target) then return {ok=false,code='talent_not_in_growth_tree',energy_spent=0} end
        local spec,audit_reason=auditTalent(p,target)
        if spec then
            description=talentSummary(p,target);before_value=rawLevel(p,a.talent_id)
        elseif audit_reason=='unsupported_progression_talent' then
            -- Generic native path: the talent is visible in a category the player
            -- already knows but is outside the reviewed list. The native dialog
            -- validates requirements, caps and the point cost.
            local pool=target.generic and 'generic' or 'class'
            if not integer(p[pools[pool]]) then return {ok=false,code='progression_state_unknown',energy_spent=0} end
            if p[pools[pool]]<1 then return {ok=false,code='insufficient_'..pool..'_points',energy_spent=0} end
            description={readiness='available',point_cost={pool=pool},native_generic=true}
            before_value=rawLevel(p,a.talent_id)
        else
            return {ok=false,code=audit_reason or 'progression_talent_modified',energy_spent=0}
        end
    else
        target=visibleCategory(p,a.category_id)
        if not target then return {ok=false,code='category_not_in_growth_tree',energy_spent=0} end
        local spec,audit_reason=auditCategory(p,target)
        if spec then
            description=categorySummary(p,target);before_value=description.known and description.mastery_base or false
        elseif audit_reason=='unsupported_progression_category' then
            if not integer(p.unused_talents_types) then return {ok=false,code='progression_state_unknown',energy_spent=0} end
            if p.unused_talents_types<1 then return {ok=false,code='insufficient_category_points',energy_spent=0} end
            if p.level<(target.min_lev or 0) then return {ok=false,code='category_level_requirement',energy_spent=0} end
            local mastery=field(p,'talents_types_mastery',target.type)
            local base=false
            if known(p,target.type) then
                if mastery==nil then base=1
                elseif D.finite(mastery) then base=mastery+1
                else return {ok=false,code='progression_state_unknown',energy_spent=0} end
            end
            description={readiness='available',point_cost={pool='category'},native_generic=true,known=known(p,target.type)}
            before_value=base
        else
            return {ok=false,code=audit_reason or 'progression_category_modified',energy_spent=0}
        end
    end
    if description.readiness~='available' then return {ok=false,code=description.readiness_reason,energy_spent=0} end
    local loaded,dialog=pcall(require,'mod.dialogs.LevelupDialog')
    if not loaded or not dialogAudit(dialog) then return {ok=false,code='levelup_dialog_unavailable',energy_spent=0} end
    local pool=pools[description.point_cost.pool]
    local before_points=p[pool]
    local before_energy=p.energy.value
    local host,native_message,mutated,entered=false,nil,false,false
    local function message(_,title,text) native_message=D.text(text or title,512) end
    -- NEW-01: compute the expected post-state once, then re-read it after every
    -- live native call that can still mutate the player (the dialog method, the
    -- finish callbacks and the unload cleanup). `targetValue` is the same raw
    -- read used for the pre-finish check, so both agree on what "changed" means.
    local function targetValue()
        if a.type=='spend_stat' then return field(p,'stats',target)
        elseif a.type=='learn_talent' then return rawLevel(p,a.talent_id)
        else return categoryTargetValue(p,a.category_id) end
    end
    -- NEW-04: every arithmetic step validates its operand first. A wrong-typed
    -- mastery read before the mutation is a clean typed refusal (nothing has
    -- been spent yet), not a crash.
    local expected
    if a.type=='learn_category' then
        if before_value==false then
            local base_mastery=field(p,'talents_types_mastery',a.category_id)
            if base_mastery~=nil and not D.finite(base_mastery) then
                return {ok=false,code='progression_state_unknown',energy_spent=0}
            end
            expected=1+(base_mastery or 0)
        else
            expected=before_value+0.2
        end
    else
        expected=before_value+1
    end
    local function postconditionMismatch()
        if p[pool]~=before_points-1 then return 'points' end
        local value=targetValue()
        if not D.finite(value) or math.abs(value-expected)>0.000001 then return 'target' end
    end
    local ok,outcome=pcall(function()
        entered=true
        -- Same bookkeeping as LevelupDialog:init, without UI generation. The
        -- native clone is for previous levels used by finish callbacks only.
        p.is_dialog_talent_leveling=true;p.no_last_learnt_talents_cap=true
        p.__hidden_talent_types=p.__hidden_talent_types or {}
        p.__increased_talent_types=p.__increased_talent_types or {}
        p.last_learnt_talents=p.last_learnt_talents or {class={},generic={}}
        local backup=p:clone();backup.uid=p.uid
        host=setmetatable({actor=p,actor_dup=backup,on_birth=false,unused_stats=p.unused_stats,
            talents_changed={},talents_learned={},talent_types_learned={},stats_increased={},talents_deps={},
            new_stats_changed=false,new_talents_changed=false,
            -- Bridge-owned UI presentation replacements; no caller callbacks.
            updateTooltip=function() end,subtleMessage=message,simplePopup=message,simpleLongPopup=message}, {__index=dialog})
        if a.type=='spend_stat' then dialog.incStat(host,target,1)
        elseif a.type=='learn_talent' then dialog.learnTalent(host,a.talent_id,true)
        else dialog.learnType(host,a.category_id,true) end
        local after_value=targetValue()
        mutated=p[pool]~=before_points or after_value~=before_value
        if p[pool]~=before_points-1 then return {ok=false,code='native_progression_rejected',uncertain=mutated or nil,
            missing=staticMissing(p,a.talent_id and p.talents_def and p.talents_def[a.talent_id])} end
        if not D.finite(after_value) or math.abs(after_value-expected)>0.000001 then
            return {ok=false,code='native_progression_mismatch',uncertain=true}
        end
        if not dialog.finish(host) then return {ok=false,code='native_progression_finish_failed',uncertain=true} end
        -- finish runs the live on_levelup_close/on_levelup_changed callbacks;
        -- a replaced-but-callable one can undo the spend here.
        if postconditionMismatch() then return {ok=false,code='native_progression_mismatch',uncertain=true} end
        -- NEW-03: the mutation was accepted, so the command carries the expected
        -- postcondition. Runtime re-validates it at settlement time, after the
        -- native tick-end queue (the real `game:onTickEnd` undo pattern used by
        -- official talents too) has drained, before any success is published.
        return {ok=true,code='progression_applied',points_spent=1,point_pool=description.point_cost.pool,
            previous_value=before_value,new_value=after_value,
            postcondition={pool=pool,expected_points=before_points-1,operation=a.type,
                target=a.type=='spend_stat' and target or (a.talent_id or a.category_id),
                expected_value=expected}}
    end)
    local cleanup_ok,cleanup_error=true,nil
    if entered then
        cleanup_ok,cleanup_error=pcall(dialog.unload,host or {actor=p})
        -- These two transient flags are owned by this single native operation.
        -- Failure does not roll back game mutations or swallow native dialogs.
        p.is_dialog_talent_leveling=nil;p.no_last_learnt_talents_cap=nil
    end
    if not ok or not cleanup_ok then
        outcome={ok=false,code='progression_execution_error',uncertain=entered or nil,
            error=D.text(tostring(not ok and outcome or cleanup_error),512)}
    elseif outcome.ok then
        -- NEW-04: the after-unload recheck itself must never escape; unload and
        -- any replaced-but-callable cleanup may leave a wrong-typed state whose
        -- read errors. Any failure here is a typed uncertain progression
        -- failure, never an uncaught error and never ok=true.
        local checked,mismatch=pcall(postconditionMismatch)
        if not checked then
            outcome={ok=false,code='progression_execution_error',uncertain=true,
                error=D.text(tostring(mismatch),512)}
        elseif mismatch then
            -- unload (the native capLastLearntTalents) and any replaced-but-callable
            -- cleanup ran after finish; the final spend/learn must still match.
            outcome={ok=false,code='native_progression_mismatch',uncertain=true}
        end
    end
    outcome.native_message=outcome.error or native_message
    local after_energy=type(p.energy)=='table' and D.number(p.energy.value)
    if not after_energy then
        return {ok=false,code='progression_execution_error',uncertain=true,energy_spent=0,
            native_message='Native progression left player energy unavailable.'}
    end
    outcome.energy_spent=math.max(0,before_energy-after_energy)
    return outcome
end
return M
