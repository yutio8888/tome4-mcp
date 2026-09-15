-- Protocol 3 action validation/admission plus the real CHANGE_LEVEL callback
-- fixture. Interactive execution lifecycle is covered by test_talent_query and
-- test_interactive_runtime.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Actions=require 'mod.mcp_bridge.Actions'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local function read(path) local file=assert(io.open(path));local data=file:read('*a');file:close();return data end

-- validate: every supported action, protocol 3 only
check(Actions.validate({type='move',direction=6}).direction==6,'move direction')
for _,d in ipairs{0,5,10,-1,1.5,'6'} do check(not Actions.validate({type='move',direction=d}),'invalid move direction '..tostring(d)) end
check(Actions.validate({type='wait'}),'wait accepted')
check(Actions.validate({type='change_level'}),'change_level accepted')
check(not Actions.validate({type='change_level',force=true}),'change_level rejects bypass')
for _,value in ipairs{0,1001,-1,1.5,math.huge,'10'} do
    check(not Actions.validate({type='rest',max_turns=value}),'invalid rest limit rejected')
end
check(Actions.validate({type='rest'}).max_turns==1000,'rest defaults to 1000 turns')
check(Actions.validate({type='attack',target_id='a'}).target_id=='a','attack target')
check(not Actions.validate({type='attack'}),'attack requires target')
check(Actions.validate({type='use_talent',talent_id='T_A'}).talent_id=='T_A','use_talent id only')
check(Actions.validate({type='use_talent',talent_id='T_A',target_id='a'}).target_id=='a','use_talent actor prefill')
check(Actions.validate({type='use_talent',talent_id='T_A',x=1,y=2}).x==1,'use_talent position prefill')
for _,bad in ipairs{
    {type='use_talent',talent_id='T_A',target_id='a',x=1,y=2},
    {type='use_talent',talent_id='T_A',x=1},
    {type='use_talent',talent_id='T_A',x=-1,y=2},
    {type='use_talent',talent_id='T_A',callback='x'},
    {type='use_talent'},
} do check(not Actions.validate(bad),'invalid use_talent rejected: '..Json.encode(bad)) end
check(Actions.validate({type='set_sustain',talent_id='T_S',enabled=true}).enabled==true,'set_sustain accepted')
check(not Actions.validate({type='set_sustain',talent_id='T_S',enabled='yes'}),'set_sustain requires boolean')
check(not Actions.validate({type='set_sustain',talent_id='T_S'}),'set_sustain requires enabled')
check(not Actions.validate({type='use_item'}),'use_item requires id')
check(Actions.validate({type='spend_stat',stat='str'}).stat=='str','progression routed')
check(Actions.validate({type='unlearn_talent',talent_id='T_A'}).talent_id=='T_A','respec routed')
check(not Actions.validate({type='unknown'}),'unknown action rejected')

-- admit / describe / capabilities
local realMatches=Compat.matches
Compat.matches=function(name,fn) if name=='useTalent' then return true end return realMatches(name,fn) end
local defs={
    T_A={id='T_A',name='Alpha',mode='activated',action=function() end},
    T_S={id='T_S',name='Sustain',mode='sustained',activate=function() end,deactivate=function() end},
    T_P={id='T_P',name='Passive',mode='passive'},
    T_ATTACK={id='T_ATTACK',name='Attack',mode='activated',action=function() end,target=function() end},
}
local p={talents_def=defs,talents={T_A=1,T_S=2,T_P=1,T_ATTACK=1},talents_cd={T_S=4},sustain_talents={T_S={}},useTalent=function() end}
check(Actions.admit(p,'T_A','activated')~=nil,'activated talent admitted')
check(select(2,Actions.admit(p,'T_A','sustained'))=='talent_mode_unsupported','mode mismatch rejected')
check(select(2,Actions.admit(p,'T_P','activated'))=='talent_mode_unsupported','passive rejected')
check(select(2,Actions.admit(p,'T_MISSING','activated'))=='talent_not_learned','unlearned rejected')
local d=Actions.describe(p,'T_S')
check(d.supported and d.target=='runtime' and d.activation.entrypoint=='set_sustain'
    and d.activation.interaction_coverage=='runtime_checked' and d.sustained_active==true,'sustain describe')
check(d.cooldown==4 and d.level==2 and d.mode=='sustained','sustain summary fields')
local attack=Actions.describe(p,'T_ATTACK')
check(attack.supported and attack.action_adapter=='attack','T_ATTACK exposes the attack adapter')
check(Actions.describe(p,'T_A').action_adapter==nil,'ordinary talent has no adapter')
local ids=Actions.capabilities(p)
check(#ids==3 and ids[1]=='T_A' and ids[2]=='T_ATTACK' and ids[3]=='T_S','capabilities list only admitted activated/sustained talents')
Compat.matches=realMatches

local g={player=p}

local default_rest=assert(Actions.validate{type='rest'})
check(default_rest.max_turns==1000,'rest defaults to 1000 turns')
for _,value in ipairs{0,1001,-1,1.5,math.huge,'10'} do
    check(not Actions.validate{type='rest',max_turns=value},'invalid rest limit rejected')
end
local short=assert(Actions.validate{type='rest',max_turns=1})
check(Actions.fingerprint(short,1)~=Actions.fingerprint(default_rest,1),'rest limit participates in dedup fingerprint')
check(Actions.execute(g,short).code=='runtime_managed_action','rest reserved for runtime ownership')
check(not Actions.validate{type='change_level',force=true},'change level rejects bypass flags')

-- Extract the current native callback without reimplementing its stair rules.
local command=assert(read('game/modules/tome/class/Game.lua'):match('CHANGE_LEVEL = (function%(%)%s*.-)%s*,%s*REST = function'))
local factory=assert(loadstring('return function(self,Map) return '..command..' end','@/mod/class/Game.lua'))()
local function stairs(terrain)
    local actor={x=1,y=1,energy={value=1000},tmp={},tempeffect_def={},
        enoughEnergy=function(self) return self.energy.value>=1000 end,attr=function(self,key) return self[key] end}
    local map=setmetatable({}, {__call=function() return terrain end})
    local game={player=actor,level={level=1,map=map},zone={short_name='trollmire'},dialogs={},key={virtuals={}},changes={},
        log=function() end}
    function game:changeLevel(lev,zone,params)
        self.changes[#self.changes+1]={level=lev,zone=zone,params=params}
        self.level={level=lev,map=map}
    end
    game.key.virtuals.CHANGE_LEVEL=factory(game,{TERRAIN=1})
    return game,actor
end
g,p=stairs({})
check(Actions.execute(g,{type='change_level'}).code=='native_rejected' and #g.changes==0,'non-stair native refusal')
local terrain={change_level=1,keep_old_lev=true,force_down=true,change_zone_auto_stairs='zone-stair',
    change_level_auto_stairs='level-stair',change_level_shift_back=true}
g,p=stairs(terrain);p.never_move=true
check(Actions.execute(g,{type='change_level'}).code=='native_rejected' and #g.changes==0,'native never_move respected')
g,p=stairs{change_level=1,change_zone='wilderness'}
p.tmp.slow={};p.tempeffect_def.slow={status='detrimental',desc='Slow'}
check(Actions.execute(g,{type='change_level'}).code=='native_rejected' and #g.changes==0,'native wilderness effect restriction respected')
g,p=stairs{change_level=1,change_level_check=function() return true end}
check(Actions.execute(g,{type='change_level'}).code=='native_rejected' and #g.changes==0,'native terrain callback may deny')
g,p=stairs(terrain)
local result=Actions.execute(g,{type='change_level'})
check(result.ok and result.level_changed and result.energy_spent==0 and g.level.level==2,'native relative stairs complete without artificial energy')
local params=g.changes[1].params
check(params.keep_old_lev and params.force_down and params.auto_zone_stair=='zone-stair'
    and params.auto_level_stair=='level-stair' and params.temporary_zone_shift_back,'all native stair options preserved')
g,p=stairs{change_level=5,change_level_abs=true}
check(Actions.execute(g,{type='change_level'}).ok and g.level.level==5,'native absolute stairs preserved')
g,p=stairs{change_level=1}
g.changeLevel=function() end
check(Actions.execute(g,{type='change_level'}).code=='native_rejected','native changeLevel denial is not false success')
g,p=stairs{change_level=1}
g.changeLevel=function(self) self.dialogs[1]={name='Native transmutation confirmation'} end
result=Actions.execute(g,{type='change_level'})
check(result.ok and result.pending and not result.level_changed and #g.dialogs==1,'native confirmation remains pending and untouched')
check(Actions.execute(g,{type='change_level'}).code=='player_busy','cannot issue another stair action through a dialog')
g,p=stairs{change_level=1};g.key.virtuals.CHANGE_LEVEL=function() error('external override') end
check(Actions.execute(g,{type='change_level'}).code=='change_level_unavailable','overridden native stair command rejected')
g,p=stairs{change_level=1};g.changeLevel=function() error('native generation error') end
result=Actions.execute(g,{type='change_level'})
check(not result.ok and result.code=='execution_error' and result.uncertain
    and result.native_message:find('native generation error',1,true),'native stair exception reports uncertain partial changes without replay')
print('Actions: '..checks..' checks passed')
