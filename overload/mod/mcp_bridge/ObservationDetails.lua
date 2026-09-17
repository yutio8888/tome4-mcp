-- GPL-3.0-or-later. Bounded, read-only projections of already known state.
-- Never invoke object naming/identification, tooltip, combat or UI callbacks.
local Json = require 'mod.mcp_bridge.Json'
local Distance = require 'mod.mcp_bridge.Distance'
local M = {}
function M.finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
function M.number(n) return M.finite(n) and n or nil end
-- Normalized engine value of the projection self-friend filter. `Target:getType`
-- fills absent fields (`selffire=true`, `friendlyfire=true`) and its cone transform
-- forces `selffire=false`; an explicit boolean or number is authoritative. This
-- is the engine field value, not a footprint claim: combine it with the geometric
-- footprint (M.footprintContainsOrigin) to get real self risk.
function M.selffire(typ)
    if type(typ)~='table' then return 'unknown' end
    local value=typ.selffire
    if type(value)=='boolean' then return value end
    if type(value)=='number' and M.finite(value) then return value end
    if value~=nil then return 'unknown' end
    if typ.type=='cone' then return false end
    return true
end
-- Static damage footprint. Only the shape decides scope; `direct_hit` is not a
-- scope truth (a direct hit can still carry an area) and is kept as a hint.
-- `bolt` is a projectile single target; `widebeam` is a widened line.
function M.damageScope(shape,direct_hit,residual_radius)
    local residual=M.number(residual_radius)
    if shape=='beam' or shape=='widebeam' then return 'line',residual end
    if shape=='ball' or shape=='cone' or shape=='wide' then return 'area',residual end
    if shape=='hit' or shape=='bolt' or shape=='arrow' then return 'single',residual end
    return 'unknown',residual
end
-- Normalized engine value of the projection friendly-fire filter. Missing
-- fields default to true; `Target:getType` only changes `selffire` for a cone.
function M.friendlyfire(typ)
    if type(typ)~='table' then return 'unknown' end
    local value=typ.friendlyfire
    if type(value)=='boolean' then return value end
    if type(value)=='number' and M.finite(value) then return value end
    if value~=nil then return 'unknown' end
    return true
end
-- A player projectile self-hits when the target spec opts in (`typ.player_selffire`)
-- OR the actor allows it (`player.allow_player_selffire`); either source being
-- false must not veto the other (native `Actor.lua` uses a boolean OR).
function M.playerSelfOverride(player,typ)
    if type(typ)=='table' and typ.player_selffire then return true end
    return player~=nil and player.allow_player_selffire==true
end
local function onSegment(ox,oy,ex,ey,ax,ay)
    -- Integer-grid collinearity plus bounding box; a warning, not a projectile.
    local cross=(ex-ox)*(ay-oy)-(ey-oy)*(ax-ox)
    if cross~=0 then return false end
    if ax<math.min(ox,ex) or ax>math.max(ox,ex) then return false end
    if ay<math.min(oy,ey) or ay>math.max(oy,ey) then return false end
    return true
end
local function rayEnd(ox,oy,tx,ty,range)
    local dx,dy=tx-ox,ty-oy
    local steps=math.max(math.abs(dx),math.abs(dy))
    if steps<=0 or type(range)~='number' then return tx,ty end
    local f=range/steps
    return math.floor(ox+dx*f+0.5),math.floor(oy+dy*f+0.5)
end
-- Warning-quality distance from a unit to a beam/widebeam segment.
local function pointSegmentDistance(px,py,ax,ay,bx,by)
    local dx,dy=bx-ax,by-ay
    if dx==0 and dy==0 then return Distance.grid(px,py,ax,ay) end
    local t=((px-ax)*dx+(py-ay)*dy)/(dx*dx+dy*dy)
    if t<0 then t=0 elseif t>1 then t=1 end
    return Distance.grid(px,py,ax+dx*t,ay+dy*t)
end
-- Geometric self-placement of a shape relative to the source, independent of the
-- projection filters (M.selffire/M.friendlyfire). A beam starts after the origin;
-- a widebeam draws a radius around each path cell so radius>=1 can include the
-- origin; bolt/hit land on the selected cell only; a ball covers a radius around
-- it. Warning-quality geometry: exact hex/wide-line parity is the v2 manifest.
function M.footprintContainsOrigin(origin,shape,radius,range,tx,ty)
    if type(origin)~='table' or not (M.finite(origin.x) and M.finite(origin.y)) then return 'unknown' end
    if not (M.finite(tx) and M.finite(ty)) then return 'unknown' end
    if shape=='hit' or shape=='bolt' or shape=='arrow' or shape=='self' then
        return origin.x==tx and origin.y==ty
    end
    if shape=='beam' then return false end
    if shape=='widebeam' then return (M.number(radius) or 0)>=1 end
    if shape=='ball' then return Distance.grid(origin.x,origin.y,tx,ty)<=(M.number(radius) or 0) end
    if shape=='cone' then return M.number(radius)~=nil end
    return 'unknown'
end
local function friendlyOf(origin,actor)
    local reaction=M.number(actor.reaction)
    if reaction~=nil then return reaction>=0 end
    if actor.faction~=nil and origin.faction~=nil then return actor.faction==origin.faction end
    return true
end
-- Visible friendly/neutral units inside a talent's static damage footprint.
-- `visible` is injected so this stays a player-visible read (no engine getters).
function M.friendliesInEffect(g,origin,tx,ty,shape,radius,range,visible)
    local out,count=Json.array(),0
    if type(visible)~='function' or not (g and g.level and origin) then return out,count end
    if not (M.finite(tx) and M.finite(ty) and M.finite(origin.x) and M.finite(origin.y)) then return out,count end
    local ex,ey=tx,ty
    if shape=='beam' or shape=='bolt' or shape=='widebeam' then ex,ey=rayEnd(origin.x,origin.y,tx,ty,range) end
    for _,actor in pairs(g.level.entities or {}) do
        if actor~=origin and type(actor)=='table' and actor.__is_actor and visible(g,actor)
            and M.finite(actor.x) and M.finite(actor.y) and friendlyOf(origin,actor) then
            local hit=false
            if shape=='beam' or shape=='bolt' then
                hit=onSegment(origin.x,origin.y,ex,ey,actor.x,actor.y)
                if hit and type(range)=='number' then
                    hit=Distance.grid(origin.x,origin.y,actor.x,actor.y)<=range
                end
            elseif shape=='widebeam' then
                hit=pointSegmentDistance(actor.x,actor.y,origin.x,origin.y,ex,ey)<=(radius or 0)
                if hit and type(range)=='number' then
                    hit=Distance.grid(origin.x,origin.y,actor.x,actor.y)<=range
                end
            elseif shape=='ball' or shape=='cone' or shape=='wide' then
                hit=Distance.grid(tx,ty,actor.x,actor.y)<=(radius or 0)
            elseif shape=='hit' or shape=='arrow' or shape==nil or shape=='unknown' then
                hit=actor.x==tx and actor.y==ty
            end
            if hit then
                count=count+1
                if #out<8 then
                    out[#out+1]={id=M.text(tostring(actor.uid),64),name=M.text(actor.name,48) or 'unknown'}
                end
            end
        end
    end
    return out,count
end
function M.native(fn,suffix)
    if type(fn)~='function' then return false end
    local info=debug.getinfo(fn,'S')
    return info and type(info.source)=='string' and info.source:sub(1,1)=='@'
        and info.source:sub(-#suffix)==suffix
end
function M.text(value,limit)
    if type(value)~='string' then return nil end
    -- Strip ToME display markup (#COLOR#, #{bold}#, #RESIST#, ...) and bound
    -- escaping overhead as well as bytes; preserve ordinary UTF-8.
    value=value:gsub('#{.-}#',''):gsub('#[%w_]+#',''):gsub('##','')
    value=value:gsub('[%z\1-\8\11\12\14-\31]',' ')
    limit=limit or 128
    if #value<=limit then return value end
    local cut=math.max(0,limit-3)
    while cut>0 do
        local nextbyte=value:byte(cut+1)
        if not nextbyte or nextbyte<128 or nextbyte>=192 then break end
        cut=cut-1
    end
    return value:sub(1,cut)..'...'
end
local function scalarId(id)
    if type(id)=='string' then return M.text(id,128) end
    if M.finite(id) then return tostring(id) end
end
function M.keys(t,limit,predicate)
    local keys,count={},0
    for key,value in pairs(type(t)=='table' and t or {}) do
        if (type(key)=='string' or M.finite(key)) and (not predicate or predicate(key,value)) then
            count=count+1
            -- Keep deterministic smallest keys without retaining an unbounded list.
            keys[#keys+1]=key
            table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
            if #keys>limit then keys[#keys]=nil end
        end
    end
    return keys,count>#keys
end
local function numbers(t,fields)
    local result={}
    if type(t)=='table' then
        for _,key in ipairs(fields) do result[key]=M.number(t[key]) end
    end
    return result
end
local combat_fields={'combat_atk','combat_def','combat_armor','combat_armor_hardiness','combat_dam',
    'combat_physcrit','combat_spellpower','combat_mindpower','combat_physresist','combat_spellresist','combat_mentalresist'}
local weapon_fields={'dam','atk','apr','physcrit','physspeed','speed','range','damrange'}
function M.effects(actor,limit)
    local effects=Json.array()
    local keys,truncated=M.keys(actor.tmp,limit or 24)
    for _,id in ipairs(keys) do
        local effect=actor.tmp[id]
        local def=actor.tempeffect_def and actor.tempeffect_def[id] or {}
        effects[#effects+1]={id=scalarId(id),name=M.text(def.desc) or scalarId(id),
            duration=type(effect)=='table' and M.number(effect.dur) or nil,
            status=M.text(def.status,32),type=M.text(def.type,32)}
    end
    return effects,truncated
end
function M.combat(actor)
    local resists={}
    local keys,truncated=M.keys(actor.resists,32,function(k,v) return M.finite(v) end)
    for _,key in ipairs(keys) do resists[scalarId(key)]=actor.resists[key] end
    return {base_combat=numbers(actor,combat_fields),base_weapon=numbers(actor.combat,weapon_fields),
        base_resists=resists,resists_truncated=truncated,combat_values_are_raw=true,
        combat_scope='stored base fields; excludes computed scaling, penetration and target-specific modifiers'}
end
function M.actor(actor,result)
    result.type=M.text(actor.type,48);result.subtype=M.text(actor.subtype,48)
    result.level=actor.hide_level_tooltip and 'unknown' or M.number(actor.level)
    result.rank=M.number(actor.rank)
    result.speed=numbers(actor,{'global_speed','global_speed_base','global_speed_add','movement_speed','combat_physspeed','combat_spellspeed','combat_mindspeed'})
    result.speed_values_are_raw=true
    result.effects,result.effects_truncated=M.effects(actor)
    result.effect_duration_is_raw=true
    for key,value in pairs(M.combat(actor)) do result[key]=value end
end
function M.expNext(p)
    if not M.finite(p.level) or p.level%1~=0 or p.level<0 or p.level>=1000
        or not M.finite(p.exp_mod) or not M.native(p.getExpChart,'/engine/interface/ActorLevel.lua') then return 'unknown' end
    local level=p.level+1
    local exp
    if type(p.exp_chart)=='table' then exp=rawget(p.exp_chart,level)
    elseif M.native(p.exp_chart,'/mod/load.lua') or M.native(p.exp_chart,'/modules/tome/load.lua') then
        exp=10
        local mult=8.5
        for i=2,level do exp=exp+level*mult;mult=math.max(3,mult-(level<30 and 0.2 or 0.1)) end
        exp=math.ceil(exp)
    elseif M.native(p.exp_chart,'/engine/interface/ActorLevel.lua') then
        exp=10
        local mult=10
        for i=2,level do exp=exp+level*mult;mult=mult+1 end
    end
    return M.finite(exp) and M.number(exp*p.exp_mod) or 'unknown'
end
local function isIdentified(g,obj)
    -- Match the native truth test without its writes to obj.identified. An
    -- overridden resolver cannot grant additional knowledge through this path.
    local identified=obj.identified
    if M.native(obj.isIdentified,'/engine/interface/ObjectIdentify.lua') then
        local known=g.object_known_types
        known=type(known)=='table' and known[obj.type]
        known=type(known)=='table' and known[obj.subtype]
        known=type(known)=='table' and known[obj.name]
        if known then identified=known end
        if obj.auto_id then identified=obj.auto_id end
    end
    return identified and true or false
end
function M.objectId(meta,obj)
    local uid=scalarId(obj.uid)
    return uid and meta.session_id..':object-'..uid or nil
end
local function requirements(obj)
    local req=obj.require
    if req==nil then return {} end
    if type(req)~='table' then return {unknown=true} end
    local result={required_level=M.number(req.level),stats={},talents=Json.array(),flags=Json.array()}
    if req.level~=nil and not M.finite(req.level) then result.unknown=true end
    if req.stat~=nil then
        if type(req.stat)~='table' then result.unknown=true
        else
            for _,name in ipairs{'str','dex','mag','wil','cun','con'} do
                local value=req.stat[name]
                result.stats[name]=M.number(value)
                if value~=nil and not M.finite(value) then result.unknown=true end
            end
        end
    end
    for _,kind in ipairs{'talent','flag'} do
        local source=req[kind]
        local destination=kind=='talent' and result.talents or result.flags
        if source~=nil then
            if type(source)~='table' then result.unknown=true
            else
                if #source>8 then result.truncated=true end
                for i=1,math.min(#source,8) do
                    local value=source[i]
                    local id=type(value)=='table' and M.text(value[1],64) or M.text(value,64)
                    local level=type(value)=='table' and M.number(value[2]) or 1
                    if id and level then destination[#destination+1]={id=id,level=level}
                    else result.unknown=true end
                end
            end
        end
    end
    return result
end
-- Shared by inventory, current ground observations and item inspection. These
-- are raw, already known properties; never identify an object to describe it.
-- Strip placeholder artifacts (empty parentheses) left by an unresolved ego
-- template, then append stored ego names. The native getName is deliberately
-- not invoked (pure stored reads only).
local function cleanItemName(value)
    local text=M.text(value,128)
    if not text then return nil end
    text=text:gsub('%s*%(%s*%)',''):gsub('%s+$','')
    return #text>0 and text or nil
end
local function storedEgoName(obj)
    if type(obj.ego)~='table' then return nil end
    local parts={}
    for _,ego in ipairs(obj.ego) do
        local name=type(ego)=='table' and (ego.name or ego.ego_name) or nil
        if type(name)=='string' and #name>0 then parts[#parts+1]=name end
    end
    return #parts>0 and table.concat(parts,' ') or nil
end
function M.item(g,obj,meta)
    local identified=isIdentified(g,obj)
    local base=cleanItemName(identified and obj.name or obj.unided_name) or 'unknown'
    if identified then
        local ego=storedEgoName(obj)
        if ego and not base:find(ego,1,true) then base=base..' '..ego end
    end
    local result={id=M.objectId(meta,obj),identified=identified,
        count=type(obj.stacked)=='table' and 1+#obj.stacked or 1,
        name=base,name_is_raw=true}
    if identified then
        result.type=M.text(obj.type,48);result.subtype=M.text(obj.subtype,48)
        result.add_name=M.text(obj.add_name,64)
        result.encumbrance=M.number(obj.encumber);result.encumbrance_is_per_item=true
        result.combat=numbers(obj.combat,weapon_fields)
        result.wielder=numbers(obj.wielder,combat_fields)
        result.combat_values_are_raw=true
        result.equipment_slot=M.text(obj.slot,48);result.offslot=M.text(obj.offslot,48)
        result.material_level=M.number(obj.material_level)
        result.requirements=requirements(obj);result.requirements_are_raw=true
        result.activation={present=type(obj.use_power)=='table' or type(obj.use_simple)=='table' or type(obj.use_talent)=='table',
            runtime_checked=true,power=M.number(obj.power),max_power=M.number(obj.max_power),
            recharge_per_turn=M.number(obj.power_regen),talent_cooldown=M.text(obj.talent_cooldown,128),
            use_no_wear=obj.use_no_wear and true or false}
    end
    return result
end
function M.inventory(g,p,meta)
    local inventory,equipment=Json.array(),Json.array()
    local keys,truncated=M.keys(p.inven,32,function(k,v) return M.finite(k) and type(v)=='table' end)
    local inventory_truncated,equipment_truncated=truncated,truncated
    local function worn(inven_id)
        local inven=p.inven[inven_id]
        local def=p.inven_def and p.inven_def[inven_id] or {}
        return inven.worn==true or def.is_worn==true,def.is_shown_equip==true
    end
    -- A full backpack must not hide the weapon and armour currently in use.
    table.sort(keys,function(a,b)
        local aw,aq=worn(a);local bw,bq=worn(b)
        local ar=aw and 0 or aq and 1 or 2;local br=bw and 0 or bq and 1 or 2
        if ar~=br then return ar<br end
        return a<b
    end)
    local count=0
    for _,inven_id in ipairs(keys) do
        local inven=p.inven[inven_id]
        local def=p.inven_def and p.inven_def[inven_id] or {}
        local equipped=inven.worn==true or def.is_worn==true
        local is_equipment=equipped or def.is_shown_equip==true
        local slots,slots_truncated=M.keys(inven,33,function(k,v) return M.finite(k) and k>0 and k%1==0 and type(v)=='table' end)
        table.sort(slots)
        if slots_truncated then
            if is_equipment then equipment_truncated=true else inventory_truncated=true end
        end
        for _,slot in ipairs(slots) do
            count=count+1
            if count>32 then
                if is_equipment then equipment_truncated=true else inventory_truncated=true end
                break
            end
            local obj=inven[slot]
            local item=M.item(g,obj,meta)
            item.inventory_id=inven_id;item.container_id=inven_id;item.slot=slot
            item.container=M.text(inven.short_name or def.short_name,48);item.equipped=equipped
            item.transmogrification_pending=obj.__transmo and true or false
            local destination=is_equipment and equipment or inventory
            destination[#destination+1]=item
        end
    end
    return inventory,equipment,inventory_truncated,equipment_truncated
end
function M.player(g,p,meta,result,detailed)
    result.level=M.number(p.level);result.exp=M.number(p.exp);result.exp_next=M.expNext(p)
    result.exp_scope='progress within current level; exp_next is the next-level threshold'
    for _,key in ipairs{'unused_stats','unused_talents','unused_generics','unused_talents_types','unused_prodigies'} do result[key]=M.number(p[key]) end
    result.descriptor={}
    for _,key in ipairs{'race','subrace','class','subclass','class_evolution','sex','difficulty'} do
        result.descriptor[key]=type(p.descriptor)=='table' and M.text(p.descriptor[key],64) or nil
    end
    result.stats={};result.stats_are_raw=true
    for _,name in ipairs{'str','dex','mag','wil','cun','con'} do
        local def=p.stats_def and p.stats_def[name]
        local id=type(def)=='table' and def.id or p['STAT_'..name:upper()]
        result.stats[name]={base=type(p.stats)=='table' and M.number(p.stats[id]) or nil,
            bonus=type(p.inc_stats)=='table' and M.number(p.inc_stats[id]) or nil}
    end
    result.life_regen=M.number(p.life_regen);result.regeneration_is_raw=true
    result.gold=M.number(p.money)
    result.gold_scope='gold is the stored money field'
    local carried=0
    for _,inven in pairs(p.inven or {}) do
        if type(inven)=='table' then
            for slot,obj in pairs(inven) do
                if type(slot)=='number' and slot>0 and type(obj)=='table' and M.finite(obj.encumber) then
                    local count=type(obj.stacked)=='table' and (1+#obj.stacked) or 1
                    carried=carried+obj.encumber*count
                end
            end
        end
    end
    result.encumbrance={items_total=math.floor(carried*100+0.5)/100,max_bonus=M.number(p.max_encumber),
        scope='items_total sums stored per-item weights; native current/max totals include strength and effects and are not evaluated'}
    result.cooldowns=Json.array()
    if type(p.talents_cd)=='table' then
        local ids={}
        for tid,cd in pairs(p.talents_cd) do if type(tid)=='string' and M.finite(cd) and cd>0 then ids[#ids+1]=tid end end
        table.sort(ids)
        for _,tid in ipairs(ids) do
            local def=p.talents_def and p.talents_def[tid]
            result.cooldowns[#result.cooldowns+1]={id=tid,name=type(def)=='table' and M.text(def.name,64) or nil,
                remaining=math.floor(p.talents_cd[tid]*1000+0.5)/1000}
        end
    end
    result.die_at=M.number(p.die_at) or 0
    result.energy=type(p.energy)=='table' and M.number(p.energy.value) or nil
    result.resources={}
    local resource_defs=p.resources_def
    for _,name in ipairs{'mana','stamina','vim','positive','negative','psi','hate','equilibrium','paradox','air'} do
        if M.finite(p[name]) then
            -- A resource is only reported when the player has unlocked it. Each
            -- resource definition is tied to a resource-pool talent; a pool the
            -- player has not learned is a default zero and carries no meaning
            -- (air has no pool talent and is always kept).
            local def=type(resource_defs)=='table' and resource_defs[name] or nil
            local talent=type(def)=='table' and def.talent or nil
            local unlocked=talent==nil or (type(p.talents)=='table' and p.talents[talent]~=nil)
            if unlocked then
                local regen=M.number(p[name..'_regen'])
                if regen then regen=math.floor(regen*1000+0.5)/1000 end
                result.resources[name]={value=p[name],min=M.number(p['min_'..name]),
                    max=M.number(p['max_'..name]),regen=regen}
            end
        end
    end
    result.effects,result.effects_truncated=M.effects(p)
    result.effect_duration_is_raw=true
    -- Active sustained talents are not tmp effects; expose them explicitly so a
    -- build decision does not have to infer them from resource maximums.
    result.sustains=Json.array()
    if type(p.sustain_talents)=='table' then
        local ids={}
        for tid,on in pairs(p.sustain_talents) do
            if on and type(tid)=='string' then ids[#ids+1]=tid end
        end
        table.sort(ids)
        for _,tid in ipairs(ids) do
            local def=p.talents_def and p.talents_def[tid]
            result.sustains[#result.sustains+1]={id=tid,name=type(def)=='table' and M.text(def.name,64) or nil}
        end
    end
    if detailed then
        result.inventory,result.equipment,result.inventory_truncated,result.equipment_truncated=M.inventory(g,p,meta)
        result.inventory_scope='owned items; raw known names and identified scalar properties only'
    else
        local inv,equip=0,0
        for inven_id,inven in pairs(p.inven or {}) do
            if type(inven)=='table' then
                local def=p.inven_def and p.inven_def[inven_id] or {}
                local is_equipment=inven.worn==true or def.is_worn==true or def.is_shown_equip==true
                local n=0
                for slot,obj in pairs(inven) do
                    if type(slot)=='number' and slot>0 and slot%1==0 and type(obj)=='table' then n=n+1 end
                end
                if is_equipment then equip=equip+n else inv=inv+n end
            end
        end
        result.inventory_count=inv;result.equipment_count=equip
        result.inventory_scope='counts only; enumerate with tome.list collection=inventory or equipment'
    end
end
function M.terrain(terrain,p)
    local result={name=M.text(terrain.name,48) or 'unknown',
        char=type(terrain.display)=='string' and #terrain.display==1 and terrain.display:match('[ -~]') and terrain.display or '.',
        block_status='unknown'}
    if type(terrain.block_move)=='boolean' then
        result.blocked=terrain.block_move
    elseif M.native(terrain.block_move,'/mod/class/Grid.lua') then
        if terrain.door_opened then
            result.blocked=true;result.door=true
            if p.open_door==nil or p.open_door==false then result.can_open=false
            elseif type(p.open_door)=='boolean' or type(p.open_door)=='string' or M.finite(p.open_door) then result.can_open=true end
            if terrain.door_player_check then result.confirmation_required=true end
            if terrain.door_player_stop then result.opening_blocked=true end
        else
            local unknown=false
            if terrain.can_pass and p.can_pass then
                if type(terrain.can_pass)~='table' or type(p.can_pass)~='table' then unknown=true
                else
                    for what,check in pairs(p.can_pass) do
                        local need=terrain.can_pass[what]
                        if need then
                            if not M.finite(need) or not M.finite(check) then unknown=true
                            elseif need<=check then result.blocked=false;break end
                        end
                    end
                end
            end
            if result.blocked==nil and not unknown then
                if terrain.does_block_move==nil or terrain.does_block_move==false then result.blocked=false
                elseif terrain.does_block_move==true then result.blocked=true end
            end
        end
    end
    if result.blocked~=nil then result.block_status=result.blocked and 'blocked' or 'passable' end
    -- These are already visible terrain labels, never hidden destination data.
    if terrain.change_level or terrain.change_zone then result.is_exit=true end
    return result
end
function M.dialogs(g)
    local result=Json.array()
    local dialogs=type(g.dialogs)=='table' and g.dialogs or {}
    local truncated=#dialogs>4
    -- The native engine gives input to the last registered dialog. Preserve
    -- that topmost dialog first even when output budgets trim older entries.
    for i=#dialogs,math.max(1,#dialogs-3),-1 do
        local dialog=dialogs[i]
        if type(dialog)=='table' and not dialog.hidden and not dialog.hide then
            local item={title=M.text(dialog.title),topmost=i==#dialogs,widgets=Json.array()}
            -- A native List menu (for example the death dialog) exposes its
            -- selectable entries even though they are not text/button widgets.
            local list=dialog.c_list
            if type(list)=='table' and type(list.list)=='table' and #list.list>0 then
                item.kind='list_menu'
                item.options=Json.array()
                for j=1,math.min(#list.list,16) do
                    local option=list.list[j]
                    item.options[#item.options+1]={label=M.text(type(option)=='table' and (option.name or option.label) or tostring(option),128)
                        or ('Option '..j)}
                end
                if #list.list>16 then item.options_truncated=true end
            end
            local widgets=type(dialog.uis)=='table' and dialog.uis or {}
            local shown=0
            for j=1,#widgets do
                local entry=widgets[j]
                local ui=type(entry)=='table' and entry.ui
                if type(ui)=='table' and not entry.hidden and not entry.hide and not ui.hidden and not ui.hide and ui.visible~=false then
                    local label=M.text(ui.text,512)
                    if label and #label>0 then
                        shown=shown+1
                        if shown>16 then item.widgets_truncated=true;break end
                        item.widgets[#item.widgets+1]={text=label,kind=type(ui.fct)=='function' and 'button' or 'text'}
                    end
                end
            end
            result[#result+1]=item
        end
    end
    return result,truncated
end
-- Persistent ground/overlay effects stored on the map (light zones, glyphs,
-- clouds). Read-only scalars; grids/particles/functions are never evaluated.
function M.groundEffects(g,p,radius)
    local out=Json.array()
    local map=g and g.level and g.level.map
    if not map or type(map.effects)~='table' or not M.finite(p.x) or not M.finite(p.y) then return out,false end
    local limit=64;local truncated=false;local n=0
    for _,e in ipairs(map.effects) do
        if type(e)=='table' and M.finite(e.x) and M.finite(e.y)
            and math.abs(e.x-p.x)<=radius and math.abs(e.y-p.y)<=radius then
            n=n+1
            if n>limit then truncated=true;break end
            local kind
            if type(e.overlay)=='table' then kind=M.text(e.overlay.type or e.overlay.name,48)
            elseif type(e.fake_overlay)=='table' then kind=M.text(e.fake_overlay.type or e.fake_overlay.name,48) end
            local damage_type
            if type(e.damtype)=='table' then damage_type=M.text(e.damtype.type or e.damtype.name,48)
            else damage_type=M.text(e.damtype,48) end
            out[#out+1]={x=e.x,y=e.y,radius=M.number(e.radius),remaining=M.number(e.duration),
                damage_type=damage_type,kind=kind,damage=M.number(e.dam)}
        end
    end
    table.sort(out,function(a,b) if a.x~=b.x then return a.x<b.x end return a.y<b.y end)
    return out,truncated
end
function M.bounded(result)
    -- Reserve 64 KiB of the 256 KiB transport frame for control/journal data.
    -- Normal observations retain their full summaries; crowded states expose
    -- explicit truncation and can be queried again with include_map=false.
    local function anyTruncated()
        if result.talents_truncated or result.actors_truncated or result.dialogs_truncated then return true end
        local ground=result.ground
        if type(ground)=='table' and ground~=Json.null and ground.truncated then return true end
        local player=result.player
        if type(player)=='table' and player~=Json.null
            and (player.inventory_truncated or player.equipment_truncated or player.effects_truncated or player.resists_truncated) then return true end
        local map=result.map
        if type(map)=='table' and map~=Json.null and map.names_truncated then return true end
        return false
    end
    if anyTruncated() then result.truncated=true end
    local limit=192*1024
    if #Json.encode(result)<=limit then return result end
    result.truncated=true
    if type(result.map)=='table' and result.map~=Json.null then
        for _,cell in ipairs(result.map.cells) do cell.name=M.text(cell.name,24) end
        result.map.names_truncated=true
    end
    local lists={{result.talents,result,'talents_truncated'}, {result.actors,result,'actors_truncated'},
        {result.dialogs,result,'dialogs_truncated'}}
    if type(result.ground)=='table' and result.ground~=Json.null then
        lists[#lists+1]={result.ground.items,result.ground,'truncated'}
    end
    if type(result.player)=='table' and result.player~=Json.null then
        lists[#lists+1]={result.player.inventory,result.player,'inventory_truncated'}
        lists[#lists+1]={result.player.equipment,result.player,'equipment_truncated'}
        lists[#lists+1]={result.player.effects,result.player,'effects_truncated'}
    end
    while #Json.encode(result)>limit do
        local largest,size
        for _,entry in ipairs(lists) do
            if entry[1] and #entry[1]>1 then
                local bytes=#Json.encode(entry[1])
                if not size or bytes>size then largest=entry;size=bytes end
            end
        end
        if not largest then break end
        for i=1,math.min(#largest[1]-1,math.max(1,math.ceil(#largest[1]/4))) do largest[1][#largest[1]]=nil end
        largest[2][largest[3]]=true
    end
    return result
end
function M.inventoryAll(g,p,meta,which)
    local items,truncated=Json.array(),false
    if not p or type(p.inven)~='table' then return items,true end
    local keys,keys_truncated=M.keys(p.inven,4096,function(k,v) return M.finite(k) and type(v)=='table' end)
    if keys_truncated then truncated=true end
    table.sort(keys)
    for _,inven_id in ipairs(keys) do
        local inven=p.inven[inven_id]
        local def=p.inven_def and p.inven_def[inven_id] or {}
        local equipped=inven.worn==true or def.is_worn==true
        local is_equipment=equipped or def.is_shown_equip==true
        if (which=='equipment' and is_equipment) or (which=='inventory' and not is_equipment) then
            local slots,slots_truncated=M.keys(inven,4096,function(k,v)
                return M.finite(k) and k>0 and k%1==0 and type(v)=='table'
            end)
            if slots_truncated then truncated=true end
            table.sort(slots)
            for _,slot in ipairs(slots) do
                local obj=inven[slot]
                local item=M.item(g,obj,meta)
                item.inventory_id=inven_id;item.container_id=inven_id;item.slot=slot
                item.container=M.text(inven.short_name or def.short_name,48);item.equipped=equipped
                item.transmogrification_pending=obj.__transmo and true or false
                items[#items+1]=item
            end
        end
    end
    return items,not truncated
end
return M
