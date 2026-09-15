-- Exercise the actual inventory, Object, Actor doWear/doTakeoff and requirement
-- code. Small map/entity boundaries avoid booting the renderer; the ordinary
-- campaign acceptance separately covers the full Player callbacks and saves.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Items=require 'mod.mcp_bridge.Items'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local function clone(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=clone(v) end;return out
end
string.capitalize=string.capitalize or function(s) return s:sub(1,1):upper()..s:sub(2) end
string.tformat=string.tformat or string.format
local Inv,Obj,Entity,Actor,Player={},{},{},{},{}
local native={['engine.interface.ActorInventory']=Inv,['engine.Object']=Obj,['engine.Entity']=Entity}
local environments={}
local function compile(code,path,target)
    local env=setmetatable({_M=target,module=function() end,print=function() end,
        require=function(name) return native[name] or {} end,
        require_first=function() return {makeKeyChar=function() return 'a' end} end,
        class={make=true,inherit=function() return true end},_t=function(s) return s end,
        table=setmetatable({clone=clone},{__index=table}),engine={interface={ActorInventory=Inv}},
        config={settings={tome={}}}},{__index=_G})
    local chunk=assert(loadstring(code,'@'..path));setfenv(chunk,env);chunk()
    environments[#environments+1]=env
end
local function extract(path,source,target,first,last)
    local data=read(path);local a=assert(data:find('function _M:'..first..'(',1,true))
    local b=assert(data:find('\nfunction _M:'..last..'(',a,true))
    compile(data:sub(a,b-1),source,target)
end
compile(read('game/engines/default/engine/interface/ActorInventory.lua'),'/engine/interface/ActorInventory.lua',Inv)
compile(read('game/engines/default/engine/Object.lua'),'/engine/Object.lua',Obj)
extract('game/engines/default/engine/Entity.lua','/engine/Entity.lua',Entity,'check','addTemporaryValue')
extract('game/engines/default/engine/Entity.lua','/engine/Entity.lua',Entity,'attr','loadList')
extract('game/modules/tome/class/Actor.lua','/mod/class/Actor.lua',Actor,'doWear','getEncumberTitleUpdator')
extract('game/modules/tome/class/Actor.lua','/mod/class/Actor.lua',Actor,'updateObjectRequirements','searchAllInventories')
extract('game/modules/tome/class/Player.lua','/mod/class/Player.lua',Player,'playerPickup','playerDrop')
for _,slot in ipairs{'MAINHAND','OFFHAND','BODY','LITE','RING'} do Inv:defineInventory(slot,slot,true,'',true) end
local uid=0
local function object(fields)
    uid=uid+1
    local o={uid=uid,name='sword '..uid,unided_name='unidentified sword',type='weapon',subtype='sword',
        slot='MAINHAND',identified=true,encumber=3,check=Entity.check}
    for k,v in pairs(fields or {}) do o[k]=v end
    return setmetatable(o,{__index=Obj})
end
local meta={session_id='items-test',level_instance_id='level-1'}
local function fixture()
    local p=setmetatable({uid=1,x=2,y=2,energy={value=1000},level=3,stats={str=15,dex=15,mag=10},
        talents={},tmp={},inven={},events={},encumbrance=0,T_STRENGTH_OF_PURPOSE='T_STRENGTH_OF_PURPOSE',
        EFF_SWIFT_HANDS_CD='SWIFT',attr=Entity.attr,check=Entity.check,playerPickup=Player.playerPickup},
        {__index=function(_,k) return Actor[k] or Inv[k] end})
    for id,def in ipairs(Inv.inven_def) do
        p.inven[id]={id=id,name=def.short_name,short_name=def.short_name,worn=def.is_worn,max=id==Inv.INVEN_INVEN and 5 or 1}
    end
    function p:getName() return 'hero' end
    function p:getStat(s) return self.stats[s] or 0 end
    function p:knowTalent(id) return id and (self.talents[id] or 0)>0 end
    function p:getTalentLevelRaw(id) return self.talents[id] or 0 end
    function p:useEnergy(value) self.energy.value=self.energy.value-(value or 1000) end
    function p:addTemporaryValue(k,v) self[k]=(self[k] or 0)+v;return v end
    function p:removeTemporaryValue(k,v) self[k]=self[k]-v end
    function p:triggerHook(event) self.events[#self.events+1]=event[1] end
    function p:onAddObject(o,inv,slot) Inv.onAddObject(self,o,inv,slot);self.encumbrance=self.encumbrance+o.encumber*o:getNumber() end
    function p:onRemoveObject(o,inv,slot) Inv.onRemoveObject(self,o,inv,slot);self.encumbrance=self.encumbrance-o.encumber*o:getNumber() end
    function p:on_pickup_object(o) self.pickups=(self.pickups or 0)+1;if self.auto_id then o.identified=true end end
    function p:setEffect(id,dur) self.tmp[id]={dur=dur} end
    for _,name in ipairs{'actorCheckSustains','breakLightningSpeed','breakReloading','breakStepUp'} do
        p[name]=function(self) self.events[#self.events+1]=name end
    end
    local map={w=7,h=7,ACTOR=3,OBJECT=1000,map={},seens={},infovs={},lites={}}
    for y=0,6 do for x=0,6 do local idx=x+y*7;map.map[idx]={};map.seens[idx]=true;map.infovs[idx]=true;map.lites[idx]=true end end
    map.map[p.x+p.y*7][3]=p
    function map:getObject(x,y,i) return self.map[x+y*self.w][self.OBJECT+i-1] end
    function map:addObject(x,y,o) local c=self.map[x+y*self.w];local i=self.OBJECT;while c[i] do i=i+1 end;c[i]=o;return true,i-self.OBJECT+1 end
    function map:removeObject(x,y,slot) local c=self.map[x+y*self.w];local i=self.OBJECT+slot-1;local o=c[i];repeat c[i]=c[i+1];i=i+1 until not c[i];return o end
    local g={player=p,level={map=map},zone={},dialogs={},logSeen=function() end,logPlayer=function() end,
        hasEntity=function() return true end,addEntity=function() end}
    for _,env in ipairs(environments) do env.game=g end
    return g,p,map
end
local function id(o) return Details.objectId(meta,o) end
local function floorId(o,x,y) return meta.session_id..':'..meta.level_instance_id..':ground-'..x..','..y..':object-'..o.uid end
local function exec(g,kind,o) return Items.execute(g,{type=kind,item_id=id(o)},meta) end
local function pickup(g,o,x,y) return Items.execute(g,{type='pickup',item_id=floorId(o,x or 2,y or 2)},meta) end
local function bag(p,o) assert(p:addObject(p.INVEN_INVEN,o));return o end
local function worn(p,o) assert(p:addObject(o:wornInven(),o));return o end

for _,kind in ipairs{'pickup','equip','unequip'} do
    check(Items.isAction(kind) and Items.validate{type=kind,item_id='id'},'strict item action '..kind)
    for _,field in ipairs{'force','slot','inven','lua','target_id'} do
        local a={type=kind,item_id='id'};a[field]=true
        check(select(2,Items.validate(a))=='unexpected_action_field','reject bypass field '..field)
    end
end
for _,value in ipairs{'',string.rep('x',257),'a\0b',1,false} do check(not Items.validate{type='pickup',item_id=value},'invalid item id') end

local g,p,map=fixture()
local a,b,c=object(),object(),object()
map:addObject(2,2,a);map:addObject(2,2,b);map:addObject(3,2,c)
local d=object();map:addObject(3,2,d)
local ground=Items.ground(g,meta,2)
check(#ground.items==3 and ground.items[1].underfoot and ground.items[1].pile_size==2,'underfoot list and remote top only')
check(ground.items[3].id==floorId(c,3,2) and ground.items[3].pile_size==2,'remote pile count and current-level id')
check(not Items.inspect(g,meta,floorId(d,3,2)),'remote buried guessed ID denied')
check(Items.inspect(g,meta,floorId(b,2,2)).underfoot,'underfoot lower item inspect')
check(pickup(g,c,3,2).code=='item_not_underfoot' and map:getObject(3,2,1)==c,'remote pickup denied')
check(not Items.inspect(g,{session_id='old',level_instance_id=meta.level_instance_id},floorId(a,2,2)),'old session floor id denied')
check(not Items.inspect(g,{session_id=meta.session_id,level_instance_id='old'},floorId(a,2,2)),'old level floor id denied')
map.infovs[3+2*7]=nil
check(#Items.ground(g,meta,2).items==2 and not Items.inspect(g,meta,floorId(c,3,2)),'remembered floor hidden without current FOV')
map.infovs[3+2*7]=true;map.seens[3+2*7]=nil
check(#Items.ground(g,meta,2).items==2,'unseen floor hidden')
map.seens[3+2*7]=true;map.map[3+2*7][3]={};map.lites[3+2*7]=nil
check(#Items.ground(g,meta,2).items==2,'ESP actor does not expose underlying objects')
map.map[3+2*7][3]=nil
check(#Items.ground(g,meta,2).items==3,'ordinary visible unoccupied cell does not require permanent light')
c.hidden=true
check(#Items.ground(g,meta,2).items==2 and not Items.inspect(g,meta,floorId(c,3,2)),'hidden top object does not expose buried objects')
p.blind=1
check(#Items.ground(g,meta,2).items==0 and pickup(g,a).code=='item_not_visible_or_owned','blindness blocks ground knowledge and guessed pickup')
p.blind=0
check(#Items.ground(g,meta,2).items==2,'zero blindness attribute is inactive')
local callbacks=0
a.identified=false;a.name='SECRET';a.slot='BODY';a.require={stat={str=99}};a.combat={dam=99}
a.getName=function() callbacks=callbacks+1;error('naming callback') end
a.isIdentified=a.getName;a.getRequirementDesc=a.getName
local unknown=assert(Items.inspect(g,meta,floorId(a,2,2)))
check(unknown.name=='unidentified sword' and unknown.combat==nil and unknown.requirements==nil and unknown.equipment_slot==nil,'unidentified ground item hides properties')
check(callbacks==0 and a.identified==false and not Json.encode(unknown):find('SECRET',1,true),'ground inspect does not call getters or identify')
a.identified=true;a.require={stat={str=12,mag=function() error('dynamic requirement') end},level=4,talent={{'T_ARMOUR',2}},flag={'heavy'}}
local known=assert(Items.inspect(g,meta,floorId(a,2,2)))
check(known.requirements.stats.str==12 and known.requirements.required_level==4 and known.requirements.talents[1].level==2
    and known.requirements.flags[1].id=='heavy' and known.requirements.unknown and known.requirements_are_raw,'raw requirements without dynamic evaluation')
g,p,map=fixture()
for i=1,140 do map:addObject(2,2,object()) end
ground=Items.ground(g,meta,99)
check(#ground.items==32 and ground.truncated and ground.radius==12 and ground.items[1].pile_size==128
    and ground.items[1].pile_truncated,'ground and pile bounds')

g,p,map=fixture();a=object{identified=false};map:addObject(2,2,a);p.auto_id=true
a.on_pickup=function() callbacks=callbacks+1 end
local result=pickup(g,a)
check(result.ok and result.energy_spent==1000 and a.__new_pickup and p.changed,'native single pickup spends one turn')
check(p.inven[p.INVEN_INVEN][1]==a and not map:getObject(2,2,1) and a.identified and p.pickups==1
    and callbacks==1 and p.encumbrance==3,'native pickup callbacks, identification and encumbrance boundary preserved')
check(not Items.inspect(g,meta,floorId(a,2,2)) and Items.inspect(g,meta,id(a)).location=='inventory','picked-up ID changes location scope')
g,p,map=fixture();a=object();b=object();map:addObject(2,2,a);map:addObject(2,2,b)
result=pickup(g,b)
check(result.ok and result.energy_spent==0 and p.inven[p.INVEN_INVEN][1]==b and map:getObject(2,2,1)==a,'native multi-pile selection is free and exact')
g,p,map=fixture();a=object();map:addObject(2,2,a);p.inven[p.INVEN_INVEN].max=0
check(not pickup(g,a).ok and p.energy.value==1000 and map:getObject(2,2,1)==a,'full inventory leaves floor and energy unchanged')
p.inven[p.INVEN_INVEN].max=5;p.sleep=1
check(not pickup(g,a).ok and map:getObject(2,2,1)==a,'sleep refuses pickup before native transfer')
p.lucid_dreamer=1
check(pickup(g,a).ok,'native lucid dreamer exception preserved')
g,p,map=fixture();a=object{stacking='arrows'};b=bag(p,object{stacking='arrows'});map:addObject(2,2,a);p.inven[p.INVEN_INVEN].max=1
result=pickup(g,a)
check(result.ok and #p.inven[p.INVEN_INVEN]==1 and b:getNumber()==2 and b.__new_pickup,'full bag merges native stack and marks surviving stack')
g,p,map=fixture();a=object{on_prepickup=function() return 'skip' end};map:addObject(2,2,a)
check(not pickup(g,a).ok and map:getObject(2,2,1)==a,'native prepickup skip')
a.on_prepickup=function(_,who,slot) map:removeObject(who.x,who.y,slot);who.money=10;return true end
result=pickup(g,a)
check(result.ok and result.native_return==true and result.energy_spent==0 and p.money==10 and #p.inven[p.INVEN_INVEN]==0,'native handled pickup stays free without invented inventory object')

g,p,map=fixture();a=bag(p,object{wielder={combat_atk=4},on_wear=function() callbacks=callbacks+1 end})
result=exec(g,'equip',a)
check(result.ok and result.energy_spent==1000 and p.inven[p.INVEN_MAINHAND][1]==a and #p.inven[p.INVEN_INVEN]==0,'native doWear nil success inferred from real location')
check(p.combat_atk==4 and a.wielded and callbacks==2 and p.encumbrance==3 and p.changed,'native wear callback, wielder and encumbrance preserved')
check(p.events[#p.events]=='breakStepUp' and p.events[#p.events-3]=='actorCheckSustains','native sustain and movement break callbacks run')
p.energy.value=1000;a.on_takeoff=function() callbacks=callbacks+1 end
result=exec(g,'unequip',a)
check(result.ok and result.energy_spent==1000 and p.inven[p.INVEN_INVEN][1]==a and p.combat_atk==0 and callbacks==3,'native takeoff reverses wielder effects and callback')
check(exec(g,'unequip',a).code=='item_not_equipped','cannot take off bag object')
g,p,map=fixture();a=worn(p,object{wielder={combat_atk=2}});b=bag(p,object{wielder={combat_atk=5}})
result=exec(g,'equip',b)
check(result.ok and p.inven[p.INVEN_MAINHAND][1]==b and p.inven[p.INVEN_INVEN][1]==a and p.combat_atk==5
    and p.encumbrance==6 and result.energy_spent==1000,'native replacement returns old equipment without duplication')
check(exec(g,'equip',b).code=='item_not_in_backpack','already equipped item rejected')
for _,requirements in ipairs{{stat={str=16}},{level=4},{flag={'heavy'}},{talent={'T_ARMOUR'}},{talent={{'T_ARMOUR',2}}}} do
    g,p,map=fixture();a=bag(p,object{require=requirements});result=exec(g,'equip',a)
    check(not result.ok and result.code=='native_rejected' and result.energy_spent==0 and p.inven[p.INVEN_INVEN][1]==a
        and #p.inven[p.INVEN_MAINHAND]==0 and a.require==requirements,
        'native equipment requirement denial restores source: '..Json.encode(requirements)..' / '..Json.encode(result))
end
g,p,map=fixture();a=bag(p,object{type='weapon',require={stat={str=20}}});p.talents.T_STRENGTH_OF_PURPOSE=1;p.stats.mag=20
check(exec(g,'equip',a).ok and a.require.stat.str==20 and not a.require.stat.mag,'native requirement conversion and original requirement restoration')
g,p,map=fixture();a=worn(p,object{slot_forbid='OFFHAND'});b=bag(p,object{slot='OFFHAND'})
check(not exec(g,'equip',b).ok and p.inven[p.INVEN_INVEN][1]==b and p.inven[p.INVEN_MAINHAND][1]==a,'native two-handed forbidden slot respected')
g,p,map=fixture();a=bag(p,object{slot_forbid='OFFHAND'});b=worn(p,object{slot='OFFHAND'})
check(not exec(g,'equip',a).ok,'new equipment cannot forbid occupied slot')
g,p,map=fixture();a=bag(p,object{power_source={arcane=true}});p.forbid_arcane=1
check(not exec(g,'equip',a).ok,'native antimagic equipment requirement')
g,p,map=fixture();a=bag(p,object{on_canwear=function() return true end})
check(not exec(g,'equip',a).ok and p.inven[p.INVEN_INVEN][1]==a and p.energy.value==1000,'native wear veto restores source without spending energy')
g,p,map=fixture();a=worn(p,object{on_cantakeoff=function() return true end})
result=exec(g,'unequip',a)
check(not result.ok and result.energy_spent==1000 and p.inven[p.INVEN_MAINHAND][1]==a,'native takeoff veto still spends native energy')
g,p,map=fixture();a=worn(p,object());p.inven[p.INVEN_INVEN].max=0
check(not exec(g,'unequip',a).ok and p.energy.value==1000 and p.inven[p.INVEN_MAINHAND][1]==a,'native takeoff bag capacity check')
for _,field in ipairs{'sleep','no_equipment_changes'} do
    g,p,map=fixture();a=bag(p,object());p[field]=1
    check(not exec(g,'equip',a).ok and p.energy.value==1000 and p.inven[p.INVEN_INVEN][1]==a,'native equipment restriction '..field)
end
g,p,map=fixture();a=bag(p,object());p.quick_wear_takeoff=1
result=exec(g,'equip',a)
check(result.ok and result.energy_spent==0 and p.tmp.SWIFT.dur==0,'native instant wear and cooldown effect')
result=exec(g,'unequip',a)
check(result.ok and result.energy_spent==0 and p.tmp.SWIFT.dur==0,'native instant takeoff')
p.quick_wear_takeoff_disable=1
check(exec(g,'equip',a).energy_spent==1000,'native swift hands disable spends energy')
g,p,map=fixture();a=bag(p,object());b=worn(p,object{offslot='OFFHAND'});a.offslot='OFFHAND'
check(exec(g,'equip',a).ok and p.inven[p.INVEN_OFFHAND][1]==a and p.inven[p.INVEN_MAINHAND][1]==b,'native default offslot routing')

for _,field in ipairs{'on_preremoveobject','on_preaddobject','tinker','is_tinker','tinkered','stacked'} do
    g,p,map=fixture();a=bag(p,object());a[field]=field=='stacked' and {object()} or function() error('complex transfer must not execute') end
    check(exec(g,'equip',a).code=='unsupported_item_transfer' and p.inven[p.INVEN_INVEN][1]==a and p.energy.value==1000,'unsupported transfer blocked before mutation '..field)
end
g,p,map=fixture();a=worn(p,object());a.on_preremoveobject=function() error('must not execute') end;b=bag(p,object())
check(exec(g,'equip',b).code=='unsupported_item_transfer','replacement cannot enter implicit removal veto')
g,p,map=fixture();a=bag(p,object{slot='PSIONIC_FOCUS'})
check(exec(g,'equip',a).code=='unsupported_equipment_slot','special equipment slot stays unsupported')
g,p,map=fixture();a=bag(p,object());p.doWear=function() error('modified action') end
check(exec(g,'equip',a).code=='item_operation_modified' and p.energy.value==1000,'modified native method rejected')
g,p,map=fixture();a=bag(p,object());g.dialogs={{}}
check(exec(g,'equip',a).code=='player_busy','dialog blocks item mutation')
g.dialogs={};p.no_inventory_access=true
check(exec(g,'equip',a).code=='inventory_unavailable','inventory access lock')
g,p,map=fixture();a=bag(p,object());p.inven[p.INVEN_BODY][1]=a
check(exec(g,'equip',a).code=='ambiguous_item_id','duplicate item reference rejected')
g,p,map=fixture();a=bag(p,object{on_wear=function() error('native callback failed after transfer') end})
result=exec(g,'equip',a)
check(not result.ok and result.uncertain and result.code=='execution_error' and result.native_message:find('native callback failed',1,true)
    and p.inven[p.INVEN_MAINHAND][1]==a,'partial native exception is uncertain for runtime quarantine')
g,p,map=fixture();a=object{on_pickup=function(_,who) who.energy=nil end};map:addObject(2,2,a)
result=pickup(g,a)
check(not result.ok and result.uncertain and result.code=='execution_error','missing post-native energy is uncertain')
for _,energy in ipairs{1000,true,{value=0/0}} do
    g,p,map=fixture();a=bag(p,object());p.energy=energy
    check(exec(g,'equip',a).code=='player_unavailable' and p.inven[p.INVEN_INVEN][1]==a,'malformed pre-native energy rejected before transfer')
end
-- Differential check against the original Player entry point. The only UI
-- boundary replacement stores the native selector callback and selects after
-- playerPickup returns, preserving its closure's dialog assignment.
for _,multiple in ipairs{false,true} do
    for _,asleep in ipairs{false,true} do
        local function run(bridge)
            local game,who,levelmap=fixture();local chosen=object{name='chosen'}
            levelmap:addObject(2,2,chosen);if multiple then levelmap:addObject(2,2,object()) end
            who.sleep=asleep and 1 or nil
            game.delayedLogMessage=function() end
            function who:getEncumberTitleUpdator() return function() return 'Pickup' end end
            function who:showPickupFloor(_,_,callback)
                self.floor_callback=callback
                return {updateTitle=function() end,used=function() end}
            end
            if bridge then pickup(game,chosen)
            else who:playerPickup();if who.floor_callback then who.floor_callback(chosen,1) end end
            return Json.encode{energy=who.energy.value,carried=#who.inven[who.INVEN_INVEN],
                left=levelmap:getObject(2,2,1) and true or false,changed=who.changed or false,new=chosen.__new_pickup or false}
        end
        check(run(true)==run(false),'pickup adapter matches native Player selection, multiple='..tostring(multiple)..', sleep='..tostring(asleep))
    end
end
print('Items: '..checks..' checks passed')
