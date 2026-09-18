-- Native PlayerRest functions and CHANGE_LEVEL command, with a small engine
-- lifecycle fixture. Ordinary campaign acceptance separately exercises the
-- real scheduler, recovery rules, terrain generation and disk saves.
-- P3-b (TODO #63): derive the addon root from this test's own path so a bare
-- relative invocation fails loudly instead of silently testing the canonical
-- `game/addons/tome-mcp-bridge` tree from another checkout.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
package.path=root..'/overload/?.lua;'..package.path
local checks,channel=0
local function check(value,message) checks=checks+1;assert(value,message) end
local function read(path) local f=assert(io.open(path));local value=f:read('*a');f:close();return value end
package.loaded['mod.mcp_bridge.TransportSocket']={new=function(options)
    channel={options=options,messages={},polls=0,
        send=function(self,value) self.messages[#self.messages+1]=value;return true end,
        poll=function(self) self.polls=self.polls+1 end,
        disconnectClient=function(self,reason) self.options.onDisconnect(reason) end,
        close=function() end}
    return channel
end}
config={settings={tome_mcp_bridge={token='task-test-token'}}}
core={game={getTime=function() return 123 end}}
local Runtime=require 'mod.mcp_bridge.Runtime'
local Json=require 'mod.mcp_bridge.Json'
local base={
    display=function() end,
    tick=function(g)
        local queued=g.queue;g.queue={};for _,fn in ipairs(queued) do fn() end
        if g.tick_work then g.tick_work() end
        if g.tick_failure then error('native tick failure sentinel') end
    end,
    loaded=function() end,
    onRegisterDialog=function() end,onUnregisterDialog=function() end,
    changeLevelReal=function(g,level,zone)
        g.changes=g.changes+1
        g.level={level=level,map=g.newMap()}
        if zone then g.zone={short_name=zone,name=zone} end
        if g.save_on_change then savefile_pipe={saving=false,pipe={{}}} end
    end,
    saveGame=function() end,
}
loadPrevious=function() return base end
local Game=dofile(root..'/superload/mod/class/Game.lua')

-- Keep the real restInit/restStop implementation and its actual source path
-- so Runtime's production audit is exercised as well as the lifecycle.
string.capitalize=function(s) return s:sub(1,1):upper()..s:sub(2) end
string.tformat=string.format
_t=function(s) return s end
local Rest={}
local function dialog() return {key={receiveKey=function() end},mouse={receiveMouse=function() end}} end
local fakeDialog={simplePopup=function()
    local d=dialog();game:registerDialog(d);return d
end}
local restEnv=setmetatable({_M=Rest,module=function() end,class={make=true},
    require=function(name) if name=='engine.ui.Dialog' then return fakeDialog end end},{__index=_G})
local restFile=assert(loadfile('game/engines/default/engine/interface/PlayerRest.lua'))
setfenv(restFile,restEnv);restFile()
local Player={act=function() end,automaticTalents=function() end,
    restInit=Rest.restInit,restStep=Rest.restStep,restStop=Rest.restStop,
    onTakeHit=function(self) self:restStop('taken damage') end,
    on_set_temporary_effect=function(self) self:restStop('detrimental status effect') end}
loadPrevious=function() return Player end
package.loaded['engine.Map']={}
Player=dofile(root..'/superload/mod/class/Player.lua')

local command=assert(read('game/modules/tome/class/Game.lua'):match('CHANGE_LEVEL = (function%(%)%s*.-)%s*,%s*REST = function'))
local stairsFactory=assert(loadstring('return function(self,Map) return '..command..' end','@/mod/class/Game.lua'))()
local attr=assert(loadstring('return function(self,key) return self[key] end','@/engine/Entity.lua'))()

local function fixture()
    savefile_pipe=nil
    local p={uid=1,name='task-player',__is_actor=true,player=true,x=2,y=2,life=100,max_life=100,
        energy={value=1000},talents={},tmp={},tempeffect_def={},attr=attr}
    local function newMap()
        local map={w=5,h=5,ACTOR=3,TERRAIN=1,map={},seens={},infovs={},lites={}}
        for i=0,24 do
            map.map[i]={[1]={name='floor',display='.',block_move=false}}
            map.seens[i]=true;map.infovs[i]=true;map.lites[i]=true
        end
        map.map[12][1].change_level=1;map.map[12][3]=p
        return setmetatable(map,{__call=function(self,x,y,layer) return self.map[x+y*self.w][layer] end})
    end
    local g=setmetatable({player=p,level={level=1,map=newMap()},zone={short_name='trollmire',name='Trollmire'},
        paused=true,turn=1,energy_to_act=1000,dialogs={},queue={},changes=0,newMap=newMap,stop_callbacks=0,
        key={receiveKey=function() end,virtuals={}},mouse={receiveMouse=function() end},log=function() end},{__index=Game})
    game=g
    function g:onTickEnd(fn) self.queue[#self.queue+1]=fn end
    function g:onTickEndExists() return #self.queue>0 end
    function g:registerDialog(d) self.dialogs[#self.dialogs+1]=d;self:onRegisterDialog(d) end
    function g:unregisterDialog(d)
        for i,x in ipairs(self.dialogs) do
            if x==d then table.remove(self.dialogs,i);self:onUnregisterDialog(d);return end
        end
    end
    function g:changeLevel(level,zone,params)
        if self.pending_change then self:registerDialog(dialog())
        else self:changeLevelReal(level,zone,params) end
    end
    g.key.virtuals.CHANGE_LEVEL=stairsFactory(g,{TERRAIN=1})
    for key,value in pairs(Player) do p[key]=value end
    function p:enoughEnergy() return self.energy.value>=1000 end
    function p:useEnergy() self.energy.value=self.energy.value-1000;g.paused=false end
    function p:onRestStart() end
    function p:onRestStop() g.stop_callbacks=g.stop_callbacks+1 end
    function p:restCheck()
        if #g.dialogs>1 then return false,'dialog is displayed' end
        if g.rest_done then self.resting.rested_fully=true;return false,'all resources and life at maximum' end
        return true
    end
    Runtime.reset(g);g:display()
    local seq=0
    local function request(op,args)
        seq=seq+1;channel.options.onRequest{v=4,id=tostring(seq),op=op,args=args}
        return channel.messages[#channel.messages]
    end
    local hello=request('connect',{token='task-test-token'}).result
    local function observe() return request('observe',{session_id=hello.session_id}).result end
    local labels={}
    local function nextId(label)
        if not labels[label] then labels[label]=observe().history.next_command_id end
        return labels[label]
    end
    local function act(id,action,revision)
        local reply=request('act',{session_id=hello.session_id,control_token=hello.control_token,
            command_id=nextId(id),expected_revision=revision or observe().revision,action=action})
        if not reply.result and reply.error then
            local code=reply.error.code
            if code=='command_in_progress' or code=='not_ready' or code=='control_lost'
                or code=='stale_revision' or code=='read_only_connection' then labels[id]=nil end
        end
        return reply
    end
    local function status(id) return request('status',{session_id=hello.session_id,command_id=nextId(id)}).result end
    local function ready()
        Runtime.beforeTick(g);g.turn=g.turn+10;p.energy.value=1000;g.paused=true
        Runtime.onReady(p);Runtime.afterTick(g);g:display()
    end
    local function step()
        Runtime.beforeTick(g);g.turn=g.turn+10;p.energy.value=1000
        if not p:restStep() then g.paused=true end
        Runtime.onReady(p);Runtime.afterTick(g);g:display()
    end
    local function start(limit)
        local revision=observe().revision
        check(act('rest-task',{type='rest',max_turns=limit},revision).result.status=='queued','rest accepted once')
        g:tick();g:display();return revision
    end
    return g,p,hello,request,observe,act,status,ready,step,start
end

for _,limit in ipairs{1,3} do
    local g,p,hello,request,observe,act,status,ready,step,start=fixture()
    local revision=start(limit)
    check(p.resting.cnt==1 and observe().control_source=='remote' and observe().phase=='settling','only native rest popup retains lease')
    for i=2,limit do step();check(p.resting.cnt==i,'native rest step counted') end
    step()
    local result=status('rest-task')
    check(result.status=='completed' and result.turns_executed==limit and result.code=='max_turns','strict max_turns includes native initial step')
    check(result.energy_spent==limit*1000 and g.stop_callbacks==1 and not p.resting and #g.dialogs==0,'energy and native stop cleanup preserved')
    check(act('rest-task',{type='rest',max_turns=limit},revision).result.status=='completed' and not p.resting,'deduplicated rest never restarts')
end
for _,reason in ipairs{'stopped','disconnected','saving'} do
    local g,p,hello,request,observe,act,status,ready,step,start=fixture()
    start(3)
    if reason=='stopped' then request('stop',{session_id=hello.session_id,control_token=hello.control_token})
    elseif reason=='disconnected' then channel.options.onDisconnect('eof')
    else g:saveGame() end
    check(not p.resting and #g.dialogs==0 and g.stop_callbacks==1 and not g.paused,'interruption does not freeze enemy settlement: '..reason)
    check(Runtime.hasControl(p),'unsettled task prevents competing automation: '..reason)
    if reason=='disconnected' then request('connect_observer',{token='task-test-token'}) end
    check(status('rest-task').status=='settling','rest cancellation waits for native boundary: '..reason)
    ready()
    local result=status('rest-task')
    check(result.status=='cancelled' and result.turns_executed==1 and result.stop_reason==reason,'original rest cancellation cause retained: '..reason)
    check(not Runtime.hasControl(p),'task ownership released after settlement: '..reason)
end
local g,p,hello,request,observe,act,status,ready,step,start=fixture()
p.onRestStop=function()
    g.stop_callbacks=g.stop_callbacks+1
    if g.stop_callbacks==1 then g:registerDialog(dialog()) end
end
start(3)
local ok,err=pcall(p.restStop,p,'natural native stop')
check(ok and not p.resting and g.stop_callbacks==1,'natural restStop boundary cannot re-enter cleanup')
ready();check(status('rest-task').status=='needs_input','foreign dialog is never owned by rest')
g,p,hello,request,observe,act,status,ready,step,start=fixture()
g.rest_done=true;start(3)
check(status('rest-task').status=='completed' and status('rest-task').turns_executed==0
    and status('rest-task').stop_reason=='native_complete','native fully recovered rest completes with zero steps')
g,p,hello,request,observe,act,status,ready,step,start=fixture()
start(3);p:onTakeHit();ready()
check(status('rest-task').stop_reason=='damaged' and not p.resting,'native damage stops owned rest and preserves reason')
g,p,hello,request,observe,act,status,ready,step,start=fixture()
start(3)
local owned=p.resting
local other={cnt=9,dialog=dialog()};p.resting=other
request('stop',{session_id=hello.session_id,control_token=hello.control_token})
check(p.resting==other and g.stop_callbacks==0,'lease cleanup never stops a replacement native rest')
p.resting=owned;p:restStop();ready()

g,p,hello,request,observe,act,status,ready,step,start=fixture()
local old=observe()
check(act('stairs',{type='change_level'},old.revision).result.status=='queued','native stair action accepted')
g.save_on_change=true
g:tick();g:display()
check(g.changes==1 and status('stairs').status=='settling','queued save delays completion before its coroutine starts')
check(observe().control_source=='manual','scene transition revokes old control lease')
savefile_pipe.pipe={};savefile_pipe.saving=true;g:display()
check(status('stairs').status=='settling','running save pipeline delays completion')
savefile_pipe.saving=false;g:display()
local changed=status('stairs')
check(changed.status=='completed' and changed.level_changed and changed.snapshot.phase=='ready'
    and changed.snapshot.level_instance_id~=old.level_instance_id,'completed stairs report stable new level')
check(act('stairs',{type='change_level'},old.revision).result.status=='completed' and g.changes==1,'deduplicated stairs never change level twice')
check(act('old-lease',{type='change_level'}).error.code=='control_lost','a new action needs an explicit new lease after stairs')
g,p,hello,request,observe,act,status,ready,step,start=fixture()
g.pending_change=true
act('pending-stairs',{type='change_level'});g:tick();g:display()
check(status('pending-stairs').status=='needs_input' and g.changes==0 and #g.dialogs==1,'native stair confirmation remains for the user')

-- A second native error during rest cleanup must not strand the already
-- accepted command in settling after the bridge has quarantined writes.
g,p,hello,request,observe,act,status,ready,step,start=fixture()
start(3)
p.onRestStop=function() error('native rest stop failure sentinel') end
g.tick_failure=true
ok,err=pcall(g.tick,g)
check(not ok and tostring(err):find('native tick failure sentinel',1,true),'original native tick error is rethrown')
local polls=channel.polls;g:display()
local failed=status('rest-task')
check(channel.polls>polls and failed.status=='failed' and failed.uncertain,'cleanup failure still leaves a readable terminal command')
check(observe().phase=='unavailable','native cleanup failure quarantines further actions')
check(p.resting~=nil,'bridge does not pretend failed native cleanup completed')
local energy,cnt=p.energy.value,p.resting.cnt
check(p:restStep()==false and p.energy.value==energy and p.resting.cnt==cnt,'failed native rest never advances automatically')
for _,mode in ipairs{'natural','max_turns'} do
    g,p,hello,request,observe,act,status,ready,step,start=fixture()
    start(1)
    p.onRestStop=function() error('native rest stop failure sentinel') end
    if mode=='natural' then
        g.tick_work=function() p:restStop('native completion') end
        ok,err=pcall(g.tick,g)
        check(not ok and tostring(err):find('native rest stop failure sentinel',1,true),'natural native restStop error is rethrown')
        g:display()
    else step() end
    failed=status('rest-task')
    check(failed.status=='failed' and failed.uncertain,'rest cleanup error has a terminal uncertain result: '..mode)
    check(observe().control_source=='manual' and not Runtime.hasControl(p),'rest cleanup error revokes control lease: '..mode)
    check(observe().phase=='unavailable' and p.resting~=nil,'failed cleanup remains quarantined without fabricating success: '..mode)
end
-- P1b: the auto-combat service owns a native rest through NativeActivity.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    local g,p,hello,request,observe,act,status,ready,step,start=fixture()
    p.life=50;p.max_life=100
    local saved_check=p.restCheck
    p.restCheck=function() return true end
    local pol={schema='tome-auto-combat/v1',id='rest-policy',name='rest',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35},
        targeting={default='nearest_hostile'},
        rules={{id='camp',priority=10,when={hp_pct={lt=100}},
            ['then']={action='rest',max_turns=2}}}}
    Runtime.autoCombatHandle(g,'set_draft',{policy=pol})
    local approved=Runtime.autoCombatHandle(g,'approve',{})
    Runtime.autoCombatHandle(g,'activate',{expected_hash=approved.approved_hash})
    Runtime.autoCombatHandle(g,'start',{})
    ready()
    Runtime.onFrame(g)
    check(p.resting~=nil and observe().native_activity=='rest_owned',
        'the auto-combat pump starts an owned native rest')
    local run=Runtime.autoCombatStatus(g).run
    check(run and run.state=='waiting_native','the controller waits while the native rest runs')
    Runtime.autoCombatHandle(g,'stop',{reason='test'})
    Runtime.onFrame(g)
    check(p.resting==nil and observe().native_activity==nil,
        'stopping the run stops and reaps the native rest')
    p.restCheck=saved_check
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
end
print('Tasks: '..checks..' checks passed')
