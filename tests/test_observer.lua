-- Native source comparisons plus sentinel callbacks: observation must not
-- identify inventory, execute dynamic getters, open doors or choose dialogs.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Observer=require 'mod.mcp_bridge.Observer'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local function read(path) local f=assert(io.open(path));local data=f:read('*a');f:close();return data end
local function nativeModule(path,source)
    local module={}
    local env=setmetatable({_M=module,require=function() return {} end,module=function() end,class={make=true}}, {__index=_G})
    local chunk=assert(loadstring(read(path),'@'..source));setfenv(chunk,env);chunk()
    return module,env
end
local actorlevel=nativeModule('game/engines/default/engine/interface/ActorLevel.lua','/engine/interface/ActorLevel.lua')
local objectid,identifyenv=nativeModule('game/engines/default/engine/interface/ObjectIdentify.lua','/engine/interface/ObjectIdentify.lua')
local source=assert(read('game/modules/tome/class/Grid.lua'):match('(function _M:block_move%(.+)\n%-%-%- Setup minimap color'))
local gridclass={}
local chunk=assert(loadstring(source,'@/mod/class/Grid.lua'));setfenv(chunk,setmetatable({_M=gridclass},{__index=_G}));chunk()
local exp_source=assert(read('game/modules/tome/load.lua'):match('ActorLevel.exp_chart = (function%(level%).-)\n%-%-%[%['))
local exp_chunk=assert(loadstring('return '..exp_source,'@/mod/load.lua'))
setfenv(exp_chunk,setmetatable({util={bound=function(value,lo,hi) return math.max(lo,math.min(hi,value)) end}},{__index=_G}))
local tome_exp=exp_chunk()
local forbidden_calls=0
local function forbidden() forbidden_calls=forbidden_calls+1;error('observation invoked callback') end
local p={uid=1,name='Hero',__is_actor=true,player=true,x=2,y=2,level=1,exp=7,exp_mod=1.2,
    life=60,max_life=100,life_regen=0.25,stamina=80,max_stamina=100,stamina_regen=1,
    unused_stats=3,unused_talents=1,unused_generics=2,unused_talents_types=1,unused_prodigies=1,
    descriptor={race='Human',subrace='Cornac',class='Warrior',subclass='Berserker',secret='HIDDEN'},
    energy={value=1000},getExpChart=actorlevel.getExpChart,exp_chart=tome_exp,
    stats_def={},stats={},inc_stats={},talents={},talents_def={},tmp={},tempeffect_def={},
    inven={},inven_def={},can_see_cache={},open_door=true,
    getStat=forbidden,combatAttack=forbidden,combatPhysicalpower=forbidden,getName=forbidden}
for i,name in ipairs{'str','dex','mag','wil','cun','con','lck'} do
    p.stats_def[name]={id=i};p.stats[i]=10+i;p.inc_stats[i]=i
end
local enemy={uid=2,name='Visible enemy',type='giant',subtype='troll',__is_actor=true,x=3,y=2,level=9,rank=3,life=20,max_life=40,
    global_speed=1.1,movement_speed=0.8,combat_atk=14,combat_def=12,combat_dam=30,resists={FIRE=25,all=5},
    tmp={SLOW={dur=4}},tempeffect_def={SLOW={desc='Slowed',status='detrimental',type='physical'}},
    tooltip=forbidden,combatAttack=forbidden,combatPhysicalpower=forbidden}
local hidden={uid=3,name='Hidden secret enemy',__is_actor=true,x=4,y=2,level=99,life=100,max_life=100}
local map={w=5,h=5,ACTOR=3,TERRAIN=1,map={},seens={},infovs={},lites={}}
for y=0,4 do for x=0,4 do
    local index=x+y*5
    map.map[index]={[1]={name='grass',display='.',block_move=gridclass.block_move}}
    map.seens[index]=true;map.infovs[index]=true;map.lites[index]=true
end end
map.map[p.x+p.y*5][3]=p;map.map[enemy.x+enemy.y*5][3]=enemy;map.map[hidden.x+hidden.y*5][3]=hidden
p.can_see_cache[enemy]={['nil/nil']={true}};p.can_see_cache[hidden]={['nil/nil']={false}}
local g={turn=23,zone={short_name='trollmire',name='Trollmire'},level={level=2,map=map,entities={p,enemy,hidden}},player=p,dialogs={}}
identifyenv.game=g
local meta={session_id='test-session',level_instance_id='level-1',revision=3,phase='ready',
    control_source='remote',battle_companion={enabled=true}}
local unknown={uid=10,name='SECRET ARTIFACT',unided_name='old sword',type='weapon',subtype='greatsword',identified=false,
    combat={dam=999},wielder={combat_atk=888},slot='MAINHAND',require={stat={str=99}},isIdentified=objectid.isIdentified,
    getName=forbidden,getDesc=forbidden,getUnidentifiedName=forbidden}
local known={uid=11,name='iron greatsword',identified=true,type='weapon',subtype='greatsword',combat={dam=12,atk=3,secret=999},
    wielder={combat_def=4,secret=999},slot='MAINHAND',offslot='OFFHAND',material_level=1,encumber=3,
    require={stat={str=15},talent={{'T_ARMOUR_TRAINING',1}}},getRequirementDesc=forbidden,
    getName=forbidden,isIdentified=forbidden,stacked={{}}}
p.inven[1]={short_name='INVEN',unknown};p.inven[2]={short_name='MAINHAND',worn=true,known}
local snapshot=Observer.capture(g,meta,2)
check(snapshot.scene.zone_id=='trollmire' and snapshot.scene.zone_name=='Trollmire' and snapshot.scene.level==2,'native scene scalar fields')
check(snapshot.player.level==1 and snapshot.player.exp==7 and snapshot.player.exp_next==p:getExpChart(2),'current level experience and native next threshold')
check(snapshot.player.unused_stats==3 and snapshot.player.unused_talents==1 and snapshot.player.unused_generics==2
    and snapshot.player.unused_talents_types==1,'all unspent point pools')
check(snapshot.player.unused_prodigies==1 and snapshot.player.descriptor.subrace=='Cornac'
    and snapshot.player.descriptor.subclass=='Berserker' and snapshot.player.descriptor.secret==nil,'visible character descriptors and prodigy points')
check(snapshot.player.stats.str.base==11 and snapshot.player.stats.str.bonus==1 and snapshot.player.stats.lck==nil,'six visible raw stats omit hidden luck')
check(snapshot.player.life_regen==0.25 and snapshot.player.resources.stamina.regen==1 and snapshot.player.regeneration_is_raw,'raw regeneration')
check(snapshot.control_source==meta.control_source and snapshot.battle_companion==meta.battle_companion,'existing control source and BC metadata retained')
check(#snapshot.actors==1 and snapshot.actors[1].name=='Visible enemy','visible actor only')
check(snapshot.player.inventory_count==1 and snapshot.player.equipment_count==1
    and snapshot.player.inventory==nil,'compact snapshot keeps inventory counts only')
local player_details=assert(Observer.inspect(g,meta,'character','self'))
check(player_details.inventory[1].name=='old sword' and not player_details.inventory[1].identified
    and player_details.inventory[1].combat==nil and player_details.inventory[1].type==nil,'unidentified item only exposes unknown appearance')
check(player_details.inventory[1].requirements==nil and player_details.inventory[1].equipment_slot==nil,
    'unidentified inventory hides equipment slot and requirements')
check(not Json.encode(player_details):find('SECRET ARTIFACT',1,true) and not unknown.identified,'no secret item identity or identification mutation')
check(player_details.equipment[1].combat.dam==12 and player_details.equipment[1].combat.secret==nil
    and player_details.equipment[1].wielder.secret==nil and player_details.equipment[1].count==2,'known equipped scalar whitelist and stack count')
local equipped=player_details.equipment[1]
check(equipped.equipment_slot=='MAINHAND' and equipped.offslot=='OFFHAND' and equipped.material_level==1
    and equipped.encumbrance==3 and equipped.encumbrance_is_per_item,'identified equipment slot, tier and per-item weight')
check(equipped.requirements.stats.str==15 and equipped.requirements.talents[1].id=='T_ARMOUR_TRAINING'
    and equipped.requirements_are_raw,'identified equipment requirements are raw and do not invoke getters')
check(snapshot.map.radius==2 and snapshot.map.window.x_min==0 and snapshot.map.window.x_max==4
    and snapshot.map.merge_scope:find('level_instance_id',1,true) and snapshot.map.block_scope:find('terrain only',1,true),'bounded map window and merge/block scope')
check(snapshot.map.cells[1].blocked==false and snapshot.map.cells[1].block_status=='passable','ordinary native grass is passable')
local details=assert(Observer.inspect(g,meta,'actor',Observer.actorId(meta,enemy)))
check(details.level==9 and details.rank==3 and details.speed.global_speed==1.1,'visible enemy level rank and stored speed')
check(details.type=='giant' and details.subtype=='troll','visible actor type and subtype')
check(details.effects[1].id=='SLOW' and details.effects[1].duration==4 and details.effect_duration_is_raw,'native stored effect duration')
check(details.base_combat.combat_atk==14 and details.base_resists.FIRE==25 and details.combat_values_are_raw,'raw enemy combat values labeled raw')
enemy.hide_level_tooltip=true
check(Observer.inspect(g,meta,'actor',Observer.actorId(meta,enemy)).level=='unknown','hidden enemy level remains hidden')
check(select(2,Observer.inspect(g,meta,'actor',Observer.actorId(meta,hidden)))=='actor_not_visible','hidden enemy inspection denied')

-- Reconstruct identification only from native rules and never change the item.
g.object_known_types={weapon={greatsword={['SECRET ARTIFACT']=true}}}
snapshot=Observer.capture(g,meta,2,{include_map=false,detail='full'})
check(snapshot.map==Json.null and snapshot.scene.zone_id=='trollmire'
    and #snapshot.actors==1 and snapshot.player.exp==7,'map omission retains other observations')
check(snapshot.player.inventory[1].identified and snapshot.player.inventory[1].name=='SECRET ARTIFACT'
    and unknown.identified==false,'native known-type identification is read-only')
g.object_known_types=nil;unknown.auto_id=true
check(Observer.capture(g,meta,2,{detail='full'}).player.inventory[1].identified and unknown.identified==false,'native auto-id is read-only')
unknown.auto_id=nil;unknown.isIdentified=forbidden
g.object_known_types={weapon={greatsword={['SECRET ARTIFACT']=true}}}
check(not Observer.capture(g,meta,2,{detail='full'}).player.inventory[1].identified,'overridden identification cannot disclose additional knowledge')
g.object_known_types=nil

-- Compare the pure projection to the actual native act=false terrain branch.
for _,terrain in ipairs{
    {name='grass'}, {name='tree',does_block_move=true},
    {name='closed door',door_opened='OPEN'},
    {name='wall',does_block_move=true,can_pass={pass_wall=1}},
    {name='thick wall',does_block_move=true,can_pass={pass_wall=3}},
} do
    terrain.block_move=gridclass.block_move;p.can_pass={pass_wall=2}
    local native_block=terrain:block_move(p.x,p.y,p,false,false) and true or false
    local summary=Details.terrain(terrain,p)
    check(summary.blocked==native_block,'native terrain result '..terrain.name)
    if terrain.door_opened then check(summary.door and summary.can_open,'door metadata without opening') end
end
local dynamic=Details.terrain({name='dynamic',block_move=forbidden,does_block_move=false},p)
check(dynamic.blocked==nil and dynamic.block_status=='unknown','dynamic movement override remains unknown')
check(Details.terrain({name='dynamic field',block_move=gridclass.block_move,does_block_move=forbidden},p).block_status=='unknown','dynamic obstruction remains unknown')
check(Details.terrain({name='dynamic pass',block_move=gridclass.block_move,does_block_move=true,can_pass={pass_wall=forbidden}},p).block_status=='unknown','dynamic pass condition remains unknown')
check(Details.terrain({name='door',block_move=gridclass.block_move,door_opened='OPEN',door_player_check='Confirm'},p).confirmation_required,'door confirmation is described only')

-- Seeing an actor with ESP does not reveal terrain beneath it.
Observer.reset();map.infovs[enemy.x+enemy.y*5]=false
snapshot=Observer.capture(g,meta,2)
check(snapshot.map.cells[enemy.x+enemy.y*5+1].known==false and #snapshot.actors==1,'ESP actor does not disclose unseen terrain')
map.infovs[enemy.x+enemy.y*5]=true
Observer.capture(g,meta,2)
map.seens[0]=false;map.map[0][1].name='NEW HIDDEN TERRAIN'
snapshot=Observer.capture(g,meta,2)
check(snapshot.map.cells[1].name=='grass' and not snapshot.map.cells[1].visible,'memory retains only previously observed terrain')
Observer.reset()
check(not Observer.capture(g,meta,2).map.cells[1].known,'session reset drops old map memory')
map.seens[0]=true

-- A wilderness observation must use the reviewed no-store FOV path. The
-- checksum/identity registration itself is also exercised in native acceptance.
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local original_matches=Compat.matches
local admitted={playerFOV=true,computeFOV=true,['map.applyLite']=true,['map.cleanFOV']=true}
Compat.matches=function(name) return admitted[name]==true end
g.zone.wilderness=true;Observer.reset()
map.infovs={};map.seens={[0]=0.6,[12]=1};map.has_seens={[1]=true};map.remembers={[1]=true};map.lites[1]=true
map.map[0][1]={name='Visible world entrance',display='>',change_zone='private-destination',block_move=gridclass.block_move}
map.map[1][1]={name='UNDISCOVERED WORLD ENTRANCE',display='>',change_zone='private-destination',block_move=gridclass.block_move}
snapshot=Observer.capture(g,meta,2)
check(snapshot.map.cells[1].visible and snapshot.map.cells[1].is_exit and snapshot.map.cells[1].blocked==false,
    'audited world applyLite terrain and entrance visible without infovs')
check(snapshot.map.cells[13].visible and snapshot.map.cells[13].known,'world terrain beneath player is known')
check(not snapshot.map.cells[2].known and not Json.encode(snapshot):find('UNDISCOVERED WORLD ENTRANCE',1,true)
    and not Json.encode(snapshot):find('private-destination',1,true),'remembered and lit world cells do not disclose unseen entrance or destination')
map.seens[0]=nil;map.map[0][1].name='CHANGED OUTSIDE SIGHT'
snapshot=Observer.capture(g,meta,2)
check(snapshot.map.cells[1].known and not snapshot.map.cells[1].visible and snapshot.map.cells[1].name=='Visible world entrance',
    'world memory retains only bridge-observed terrain after FOV moves')
Observer.reset();map.seens[0]=0
check(not Observer.capture(g,meta,2).map.cells[1].known,'zero visibility and session reset cannot reveal world terrain')
map.seens[0]=1
for name in pairs(admitted) do
    admitted[name]=false;Observer.reset()
    check(not Observer.capture(g,meta,2).map.cells[1].known,'modified wilderness entrypoint fails closed: '..name)
    admitted[name]=true
end
p.blind=1;Observer.reset()
check(not Observer.capture(g,meta,2).map.cells[1].known,'blind world observer cannot learn terrain')
p.blind=nil;g.zone.wilderness=nil;Observer.reset()
check(not Observer.capture(g,meta,2).map.cells[1].known,'dungeon still requires infovs despite admitted world methods')
map.infovs[0]=true;p.blind=1
check(not Observer.capture(g,meta,2).map.cells[1].known,'blind dungeon observer cannot learn terrain')
p.blind=nil;Compat.matches=original_matches
for i=0,24 do map.seens[i]=true;map.infovs[i]=true end

g.dialogs={{title='Confirm transition',uis={
    {ui={text='Items will be transmuted',getText=forbidden}},
    {ui={text='Continue',fct=forbidden}},
    {ui={text='HIDDEN LABEL',fct=forbidden},hidden=true},
    {ui={text='HIDDEN WIDGET',hidden=true}},
    {ui={text='NATIVE HIDDEN BUTTON',hide=true,fct=forbidden}},
    {ui={text=setmetatable({}, {__tostring=forbidden}),fct=forbidden}},
}}}
snapshot=Observer.capture(g,meta,2)
check(snapshot.dialogs[1].title=='Confirm transition' and #snapshot.dialogs[1].widgets==2
    and snapshot.dialogs[1].widgets[2].kind=='button','read existing visible dialog labels without callbacks')
check(not Json.encode(snapshot):find('HIDDEN LABEL',1,true),'hidden dialog content omitted')
check(not Json.encode(snapshot):find('NATIVE HIDDEN BUTTON',1,true),'native ui.hide button text omitted')
g.dialogs[2]={title='Topmost popup',uis={}}
check(Observer.capture(g,meta,2).dialogs[1].title=='Topmost popup','native last dialog is preserved first')
g.dialogs[2].hide=true
check(#Observer.capture(g,meta,2).dialogs==1,'hidden dialog omitted')

for _,chart in ipairs{actorlevel.exp_chart,tome_exp,{[2]=99,[11]=999,[50]=9999}} do
    p.exp_chart=chart
    for _,level in ipairs{1,10,49} do
        p.level=level
        check(Details.expNext(p)==p:getExpChart(level+1),'native exp parity at level '..level)
    end
end
p.exp_chart=forbidden
check(Details.expNext(p)=='unknown','dynamic experience chart is not called')
p.exp_chart=tome_exp;p.getExpChart=forbidden
check(Details.expNext(p)=='unknown','dynamic experience getter is not called')
p.getExpChart=actorlevel.getExpChart;p.level=1
local chinese='战斗观察'
for limit=3,14 do
    local text=Details.text(chinese..chinese,limit)
    check(#text<=limit and pcall(Json.decode,Json.encode(text)),'UTF-8 truncation remains valid at byte limit '..limit)
end
check(forbidden_calls==0,'all observation callbacks stayed untouched')

-- Stress all list and text limits together within transport headroom.
local noisy=string.rep('"\\',1000)
p.name=noisy;p.tmp={};p.tempeffect_def={};p.talents={};p.talents_def={};p.inven[1]={}
for i=1,200 do
    p.tmp['E'..i]={dur=i};p.tempeffect_def['E'..i]={desc=noisy,status=noisy,type=noisy}
    local id=string.rep('"',250)..i
    p.talents[id]=1;p.talents_def[id]={name=noisy,mode=noisy}
    p.inven[1][i]={uid=100+i,identified=true,name=noisy,add_name=noisy,type=noisy,subtype=noisy,
        combat={dam=1},wielder={combat_atk=1},isIdentified=forbidden}
end
local full=Observer.capture(g,meta,2,{include_map=false,detail='full'})
check(#full.player.equipment==1 and full.player.equipment[1].name=='iron greatsword'
    and not full.player.equipment_truncated and full.player.inventory_truncated,'full backpack retains equipped items and independent truncation flags')
g.dialogs={}
for i=1,8 do
    g.dialogs[i]={title=noisy,uis={}}
    for j=1,32 do g.dialogs[i].uis[j]={ui={text=noisy,fct=forbidden}} end
end
map.w=25;map.h=25;p.x=12;p.y=12;map.map={};map.seens={};map.infovs={};map.lites={};g.level.entities={p}
for y=0,24 do for x=0,24 do
    local index=x+y*25
    map.map[index]={[1]={name=noisy,display='"',block_move=gridclass.block_move,door_opened='OPEN',door_player_check='Confirm'}}
    map.seens[index]=true;map.infovs[index]=true;map.lites[index]=true
    if index<100 then
        local a={uid=1000+index,name=noisy,faction=noisy,x=x,y=y,__is_actor=true,life=10,max_life=10}
        map.map[index][3]=a;g.level.entities[#g.level.entities+1]=a;p.can_see_cache[a]={['nil/nil']={true}}
    end
end end
map.map[p.x+p.y*25][3]=p
snapshot=Observer.capture(g,meta,10000,{detail='full'})
check(snapshot.map.radius==12 and #snapshot.map.cells==625,'direct observer calls also cap map size')
check(#snapshot.talents<=64 and snapshot.talents_truncated and #snapshot.actors<=32 and snapshot.actors_truncated,'actor and talent limits explicit')
check(#snapshot.player.inventory+#snapshot.player.equipment<=32 and snapshot.player.inventory_truncated
    and #snapshot.player.effects<=24 and snapshot.player.effects_truncated,'inventory and effect limits explicit')
check(#snapshot.dialogs<=4 and snapshot.dialogs_truncated and #snapshot.dialogs[1].widgets==16
    and snapshot.dialogs[1].widgets_truncated,'dialog and widget limits explicit')
local bytes=#Json.encode(snapshot)
check(bytes<192*1024 and snapshot.truncated and snapshot.map.names_truncated,'bounded capture leaves 64 KiB journal/transport headroom: '..bytes)
check(forbidden_calls==0,'stress observations stay read-only')
-- Round-11 backlog: static damage scope, ground effects, ego name cleanup.
local dscope,dres=Details.damageScope('ball',nil,1)
check(dscope=='area' and dres==1,'area shape reports residual radius')
check(select(1,Details.damageScope('beam'))=='line','beam damage is a line')
check(select(1,Details.damageScope('ball',true))=='single','a direct hit is single-target')
check(select(1,Details.damageScope('unknown'))=='unknown','an unknown shape has unknown damage scope')
g.level.map.effects={{x=p.x+1,y=p.y,duration=5,damtype={type='LIGHT'},radius=1,fake_overlay={type='light_zone'}}}
local effects,effects_truncated=Details.groundEffects(g,p,8)
check(#effects==1 and effects[1].kind=='light_zone' and effects[1].damage_type=='LIGHT' and effects[1].remaining==5
    and not effects_truncated,'ground persistent effects are visible with kind and damage type')
g.level.map.effects=nil
local ego=Details.item(g,{uid=77,identified=true,name='iron longsword ()',type='weapon',subtype='longsword',
    ego={{name='flaming'}}},meta)
check(ego.name=='iron longsword flaming','ego name drops placeholders and keeps the stored ego name')
print('Observer: '..checks..' checks passed; stress snapshot '..bytes..' bytes')
