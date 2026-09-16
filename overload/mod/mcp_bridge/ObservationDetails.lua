-- GPL-3.0-or-later. Bounded, read-only projections of already known state.
-- Never invoke object naming/identification, tooltip, combat or UI callbacks.
local Json = require 'mod.mcp_bridge.Json'
local M = {}
function M.finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
function M.number(n) return M.finite(n) and n or nil end
-- Self-inclusion for a target spec. ToME treats a missing selffire as
-- "area shapes may hit their origin": beams/hits cannot. A function target
-- (or a non-boolean selffire) computes it at cast time and stays unknown.
function M.selffire(typ)
    if type(typ)~='table' then return 'unknown' end
    if type(typ.selffire)=='boolean' then return typ.selffire end
    if typ.selffire~=nil then return 'unknown' end
    -- A direct-hit talent never includes its origin.
    if typ.direct_hit==true then return false end
    local shape=typ.type
    if shape=='ball' or shape=='cone' or shape=='wide' then return true end
    if shape=='beam' or shape=='hit' or shape=='bolt' or shape=='arrow' then return false end
    return 'unknown'
end
-- Static damage footprint: a direct hit is single-target, a beam is a line,
-- and an area shape covers a region. A stored residual radius (an on-ground
-- remainder such as Searing Light's light zone) is reported separately.
function M.damageScope(shape,direct_hit,residual_radius)
    local residual=M.number(residual_radius)
    if direct_hit==true then return 'single',residual end
    if shape=='beam' then return 'line',residual end
    if shape=='ball' or shape=='cone' or shape=='wide' then return 'area',residual end
    return 'unknown',residual
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
    result.encumbrance={max_bonus=M.number(p.max_encumber),current=M.number(p.encumber),
        scope='stored fields only; current/max encumbrance are engine-computed and not evaluated'}
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
