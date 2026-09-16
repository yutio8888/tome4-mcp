local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local count,channel=0
local function check(value,message) count=count+1;assert(value,message) end
package.loaded['mod.mcp_bridge.TransportSocket']={new=function(options)
    channel={options=options,messages={},polls=0,
        send=function(self,value) self.messages[#self.messages+1]=value;return true end,
        poll=function(self) self.polls=self.polls+1 end,
        disconnectClient=function(self,reason) self.disconnected=reason;self.options.onDisconnect(reason) end,
        close=function() end}
    return channel
end}
config={settings={tome_mcp_bridge={token='unit-test-token'}}}
core={game={getTime=function() return 123 end}}
local Runtime=require 'mod.mcp_bridge.Runtime'
local forbidden=assert(loadstring('return function() error("observer invoked native callback") end','@/mod/class/Actor.lua'))()
local attr=assert(loadstring('return function() error("observer invoked attr") end','@/engine/Entity.lua'))()
local base={
    display=function() end,
    tick=function(g)
        if g.nested_error and not g.nesting then g.nesting=true;return g:tick() end
        local queued=g.queue;g.queue={};for _,fn in ipairs(queued) do fn() end
        if g.tick_failure then error('native failure sentinel') end
    end,
    loaded=function(g) g.tick_failure=false;g.nested_error=false;g.nesting=false;g.player.energy.value=1000;g.paused=true end,
    onRegisterDialog=function() end,onUnregisterDialog=function() end,
    changeLevelReal=function(g) if g.change_failure then error('change failure sentinel') end;if g.scene_fixture then g.scene_fixture() end end,
    saveGame=function(g) if g.save_failure then error('save failure sentinel') end;g.save_calls=(g.save_calls or 0)+1 end,
}
loadPrevious=function() return base end
local Game=dofile(root..'/superload/mod/class/Game.lua')
local function fixture()
    local p={uid=1,name='player',__is_actor=true,player=true,x=2,y=2,life=100,max_life=100,energy={value=1000},
        talents={},tmp={},canSee=forbidden,canSeeNoCache=forbidden,attr=attr}
    local enemy={uid=2,name='dummy',__is_actor=true,x=3,y=2,life=100,max_life=100,attr=attr}
    local map={w=5,h=5,ACTOR=3,TERRAIN=1,map={},seens={},infovs={},lites={}}
    for i=0,24 do
        map.map[i]={[1]={name='floor',display='.',block_move=false}}
        map.seens[i]=true;map.infovs[i]=true;map.lites[i]=true
    end
    map.map[12][3]=p;map.map[13][3]=enemy
    local g=setmetatable({player=p,level={map=map,entities={[1]=p,[2]=enemy}},paused=true,turn=1,
        energy_to_act=1000,dialogs={},queue={},key={receiveKey=function() end},mouse={receiveMouse=function() end}}, {__index=Game})
    function g:onTickEnd(fn) self.queue[#self.queue+1]=fn end
    function g:onTickEndExists() return #self.queue>0 end
    function p:moveDir() self.x=self.x-1;self.energy.value=0;g.paused=false;return true end
    function p:waitTurn() self.energy.value=0;g.paused=false end
    Runtime.reset(g);g:display()
    local seq=0
    local function request(op,args,version)
        seq=seq+1;channel.options.onRequest{v=version or 4,id=tostring(seq),op=op,args=args}
        return channel.messages[#channel.messages]
    end
    local hello=request('connect',{token='unit-test-token'}).result
    local v4hello=request('connect',{token='unit-test-token'})
    check(v4hello.v==4 and v4hello.result.protocol_version==4 and v4hello.result.capabilities.talent_query==true,
        'v4 request returns a v4 envelope, protocol and query capability')
    local oldproto=request('connect',{token='unit-test-token'},3)
    check(oldproto.error and oldproto.error.code=='protocol_mismatch','a v3 request is rejected without taking control')
    local restored=request('connect',{token='unit-test-token'}).result
    for k in pairs(hello) do hello[k]=nil end
    for k,v in pairs(restored) do hello[k]=v end
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
    local function status(id,response_id) return request('status',{session_id=hello.session_id,command_id=nextId(id),response_id=response_id}).result end
    local function ready()
        Runtime.beforeTick(g);g.turn=g.turn+10;p.energy.value=1000;g.paused=true
        Runtime.onReady(p);Runtime.afterTick(g);g:display()
    end
    local function reconnect() local fresh=request('connect',{token='unit-test-token'}).result
        for k in pairs(hello) do hello[k]=nil end;for k,v in pairs(fresh) do hello[k]=v end;return hello end
    return g,p,enemy,hello,request,observe,act,status,ready,reconnect
end

-- Controlled native producer, real invocation/interaction/runtime machinery.
-- The native game suite checks the engine seams separately.
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Interactions=require 'mod.mcp_bridge.Interactions'
local Actions=require 'mod.mcp_bridge.Actions'
local steps,partial,error_after,unknown=2,0,false,false
local native_body
Actions.execute=function(g,action,target,meta,command)
    Tracker.start(g,command,function()
        return Tracker.call(g.player,'T_FIXTURE',function()
            native_body=Tracker.createBody(function()
                for i=1,steps do
                    local d={key={receiveKey=function() end},mouse={receiveMouse=function() end}}
                    local function accept()
                        Interactions.closeDialog(d);g.dialogs={}
                        -- Intentionally ignore resume's failure, like native targetMode.
                        coroutine.resume(native_body)
                    end
                    if not unknown then
                        Interactions.openDialog(d,'dialog.confirm','Fixture','Choose',{{label='Continue',apply=accept}},accept)
                    end
                    g.dialogs={d};g:onRegisterDialog(d)
                    coroutine.yield()
                    partial=partial+1
                    if error_after then error('after-resume-fixture') end
                end
                return true
            end)
            assert(coroutine.resume(native_body))
        end)
    end)
    return {ok=true,energy_spent=0}
end
local g,p,enemy,hello,request,observe,act,status,ready,reconnect
local function fresh()
    steps,partial,error_after,unknown=2,0,false,false
    g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
end
local function frame() g:tick();g:display() end
local function start(id)
    act(id,{type='use_talent',talent_id='T_FIXTURE'});frame();return status(id)
end
local function answer(record,id)
    return {session_id=hello.session_id,control_token=hello.control_token,command_id=record.command_id,
        interaction_id=record.interaction.interaction_id,response_id=id,expected_revision=record.revision,
        answer={type='option',option_id=record.interaction.options[1].option_id}}
end
fresh()
local first=start('multi')
check(first.status=='awaiting_input' and not first.execution_released,'first native yield is nonterminal')
local before=observe()
for i=1,10 do status('multi');observe() end
check(observe().revision==before.revision and partial==0,'reading prompts does not mutate game or revision')
local a=answer(first,'r1')
check(request('respond',a).result.response_receipt.state=='queued','response queues once')
check(request('respond',a).result.response_receipt.state=='queued','queued retry retrieves same receipt')
local duplicate=answer(first,'r2')
check(request('respond',duplicate).error.code=='interaction_consumed','second response id cannot resume consumed prompt')
local conflict=answer(first,'r1');conflict.answer={type='cancel'}
check(request('respond',conflict).error.code=='response_conflict','conflicting response reuse rejected')
frame()
local second=status('multi','r1')
check(second.status=='awaiting_input' and second.interaction.sequence==2 and partial==1,'native continuation produces second question')
check(second.interaction.interaction_id~=first.interaction.interaction_id,'questions have different opaque IDs')
check(request('respond',duplicate).error.code=='interaction_consumed','old prompt tombstone survives next question')
check(request('respond',a).result.response_receipt.state=='applied' and partial==1,'applied retry cannot repeat continuation')
local b=answer(second,'r2');request('respond',b);frame()
check(status('multi').status=='completed' and status('multi').execution_released and partial==2,'final native return releases lifecycle')
reconnect()
check(request('respond',a).result.response_receipt.state=='applied' and partial==2,'old lease can recover authenticated receipt without executing')

fresh();first=start('stopped');a=answer(first,'queued-stop');request('respond',a)
request('stop',{session_id=hello.session_id,control_token=hello.control_token});frame()
local stopped=status('stopped','queued-stop')
check(stopped.status=='needs_input' and stopped.response_receipt.state=='rejected' and partial==0,'stop between receive and tick rejects queued answer')
check(stopped.input_owner=='manual' and not stopped.execution_released and Runtime.hasControl(p),'manual handoff retains execution barrier')
reconnect()
check(act('blocked',{type='wait'}).error.code=='command_in_progress','new lease cannot bypass suspended native invocation')
check(request('respond',answer(stopped,'manual-bypass')).error.code=='interaction_not_owned','new lease cannot steal manual handoff')
g.dialogs={};coroutine.resume(native_body);g.dialogs={};coroutine.resume(native_body);frame()
check(status('stopped').status=='needs_input' and status('stopped').execution_released,'manual completion releases barrier without rewriting command outcome')

fresh();first=start('orphan');a=answer(first,'old');channel.options.onDisconnect('eof');frame();reconnect()
local reclaimed=status('orphan')
check(reclaimed.input_owner=='remote' and reclaimed.interaction.interaction_id==first.interaction.interaction_id,'explicit reconnect reclaims untouched orphan prompt')
check(request('respond',a).error.code=='control_lost','old lease cannot submit a new response')
a=answer(reclaimed,'new');request('respond',a);frame()
check(partial==1 and status('orphan').status=='awaiting_input','reconnected native continuation works once')

fresh();first=start('stale');a=answer(first,'stale')
Runtime.beforeTick(g);Runtime.afterTick(g)
check(request('respond',a).error.code=='stale_revision' and partial==0,'stale answer is rejected before native callback')
first=status('stale');a=answer(first,'stale-tick');request('respond',a)
Runtime.beforeTick(g);Runtime.afterTick(g);frame()
local rejected=status('stale','stale-tick')
check(rejected.response_receipt.state=='rejected' and rejected.response_receipt.code=='stale_revision' and partial==0,
    'revision is checked again at execution boundary')
check(rejected.interaction.interaction_id~=first.interaction.interaction_id,'rejected queued answer reissues native prompt without replay')

fresh();first=start('disconnect-race');a=answer(first,'orphan-queued');request('respond',a)
channel.options.onDisconnect('eof');frame();reconnect()
local orphan=status('disconnect-race','orphan-queued')
check(orphan.status=='awaiting_input' and orphan.response_receipt.state=='rejected' and partial==0,
    'disconnect after queue never applies the old answer')
check(orphan.interaction.interaction_id~=first.interaction.interaction_id and orphan.input_owner=='remote',
    'reconnect receives newly issued unconsumed native question')

fresh();first=start('manual-race');a=answer(first,'manual-queued');request('respond',a)
g.key:receiveKey(1,false,false,false,false,'',false);frame();reconnect()
check(status('manual-race','manual-queued').response_receipt.state=='rejected' and partial==0,
    'physical input before queued answer wins control without remote continuation')

fresh();first=start('scene-race');a=answer(first,'scene-queued');request('respond',a)
g.level={map=g.level.map,entities=g.level.entities};frame()
check(status('scene-race','scene-queued').response_receipt.state=='rejected' and partial==0,
    'scene change before queued response never resumes old native coroutine')
check(status('scene-race').status=='needs_input' and not status('scene-race').execution_released,
    'suspended invocation in changed context retains manual execution barrier')

fresh();first=start('death-race');a=answer(first,'death-queued');request('respond',a)
p.dead=true;p.life=-1;frame()
check(status('death-race','death-queued').response_receipt.state=='rejected' and partial==0,
    'native death before response execution prevents continuation even before revision bump')
check(status('death-race').status=='failed','native terminal state reports failed command')

fresh();first=start('budget');Interactions.MAX_RESPONSES=0
check(request('respond',answer(first,'over')).error.code=='response_budget_exhausted','response cap hands off without answering')
frame();check(status('budget').status=='needs_input' and partial==0,'response budget preserves native prompt')
Interactions.MAX_RESPONSES=128

fresh();unknown=true;first=start('unknown')
check(first.status=='needs_input' and first.input_owner=='manual' and not first.execution_released,'unknown UI requires manual handoff')
reconnect();check(act('unknown-bypass',{type='wait'}).error.code=='command_in_progress','unknown UI keeps game occupied')

fresh();error_after=true;first=start('late-error');a=answer(first,'error-answer');request('respond',a);frame()
local failed=status('late-error','error-answer')
check(failed.status=='failed' and failed.uncertain and partial==1 and failed.native_message:find('after-resume-fixture',1,true),
    'ignored resume error retains partial effects and uncertainty')
check(failed.response_receipt.state=='applied' and not failed.execution_released,'callback was applied despite native failure; no retry')
reconnect();check(observe().phase=='unavailable' and act('error-bypass',{type='wait'}).error.code=='command_in_progress','native failure quarantines further actions')
check(request('respond',a).result.response_receipt.state=='applied' and partial==1,'failed native answer remains idempotently queryable')

-- Ordinary synchronous actions can commit their effects before stacking UI.
fresh()
local rewards,closes=0,{}
Actions.execute=function(g)
    rewards=rewards+1
    local stack={}
    for i=1,3 do
        local index=i
        local d={key={virtuals={},receiveKey=function() end},mouse={receiveMouse=function() end}}
        d.key.virtuals.EXIT=function()
            closes[#closes+1]=index
            for n,entry in ipairs(g.dialogs) do if entry==d then table.remove(g.dialogs,n);break end end
            g:onUnregisterDialog(d)
        end
        Interactions.openNotice(d,'audited-fixture','Notice '..i,'Already awarded')
        stack[i]=d
    end
    -- Deliberately differs from constructor order. The visible top is 2.
    for _,i in ipairs{1,3,2} do g.dialogs[#g.dialogs+1]=stack[i];g:onRegisterDialog(stack[i]) end
    return {ok=false,code='native_rejected',energy_spent=0}
end
first=start('reward')
check(first.status=='awaiting_input' and first.interaction.prompt=='Notice 2' and rewards==1,
    'synchronous action retains topmost native notice after committing side effects')
local original_sequence=first.interaction.sequence
act('reward',{type='use_talent',talent_id='T_FIXTURE'},first.revision_before)
check(rewards==1,'duplicate ordinary action does not award again')
local prior=observe();for i=1,5 do status('reward');observe() end
check(observe().revision==prior.revision,'notice reads do not issue new IDs or revise state')
request('respond',answer(first,'close-2'));frame()
local lower=status('reward')
check(lower.status=='awaiting_input' and lower.interaction.prompt=='Notice 3' and lower.interaction.sequence>original_sequence,
    'closing actual top exposes next native layer with increasing sequence')
check(#closes==1 and closes[1]==2 and rewards==1,'one answer closes exactly one layer without reward replay')
request('respond',answer(lower,'close-3'));frame()
lower=status('reward');request('respond',answer(lower,'close-1'));frame()
local done=status('reward')
check(done.status=='failed' and done.code=='native_rejected' and done.execution_released,
    'last notice preserves original synchronous false result')
check(#closes==3 and closes[2]==3 and closes[3]==1 and rewards==1,'stack closure follows actual native order once')

fresh()
Actions.execute=function(g)
    g:onTickEnd(Tracker.callback(g,function()
        local d={key={virtuals={},receiveKey=function() end},mouse={receiveMouse=function() end}}
        d.key.virtuals.EXIT=function() g.dialogs={};g:onUnregisterDialog(d) end
        Interactions.openNotice(d,'audited-fixture','Deferred quest','Committed on earlier callback')
        g.dialogs={d};g:onRegisterDialog(d)
    end))
    return {ok=true,code='item_action_complete',points_spent=1,energy_spent=0}
end
first=start('deferred');frame();first=status('deferred')
check(first.status=='awaiting_input' and first.interaction.prompt=='Deferred quest','native deferred callback retains command ownership')
request('respond',answer(first,'deferred-close'));frame()
check(status('deferred').status=='completed' and status('deferred').points_spent==1,
    'deferred notice closes without losing original action metadata')
local utf8=Interactions.noticeText{uis={{ui={text=string.rep('x',2040)}},{ui={text='中文剧情说明'}}}}
check(#utf8<=2048 and utf8:sub(2042)=='中...',
    'native notice text truncation preserves complete UTF-8 characters')

-- Background autosave must wait for the native UI without making it manual.
fresh();first=start('autosave-chat')
g:saveGame();frame()
check(status('autosave-chat').status=='awaiting_input' and status('autosave-chat').input_owner=='remote'
    and not g.save_calls,'autosave defers without stealing remote dialog ownership')
request('respond',answer(status('autosave-chat'),'auto-last'));frame();frame();frame()
check(status('autosave-chat').status=='completed' and g.save_calls==1,'one deferred save runs after the native UI finishes')

-- A controlled change-level producer exercises the real owned-scene state
-- machine. Full Game/companion source checks run in normal campaign acceptance.
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local matches=Compat.matches
Compat.matches=function(name,fn) if name=='changeLevelReal' and fn==Game.changeLevelReal then return true end;return matches(name,fn) end
fresh();local changes=0
local revision=observe().revision
Actions.execute=function(gg,action,target,meta,command)
    gg.scene_fixture=function()
        changes=changes+1
        local owner=Tracker.current()
        local waiting={}
        Interactions.claimSceneWaiter(waiting);gg.dialogs={waiting};gg:onRegisterDialog(waiting)
        check(Interactions.dialogOwner(waiting)==owner.root,'native loader waiter has passive scene ownership')
        gg:onUnregisterDialog(waiting);gg.dialogs={}
        gg.level={map=gg.level.map,entities=gg.level.entities}
        local d={}
        Interactions.openDialog(d,'dialog.choice','Escort offer','Choose',{{label='Continue',apply=function()
            Interactions.closeDialog(d);gg.dialogs={}
        end}})
        gg.dialogs={d};gg:onRegisterDialog(d)
    end
    gg:changeLevelReal()
    return {ok=true,code='level_changed',level_changed=true,energy_spent=0}
end
act('scene-chat',{type='change_level'},revision);frame()
local scene=status('scene-chat')
check(scene.status=='awaiting_input' and scene.input_owner=='orphaned' and changes==1,
    'declared native scene change retains new-level input and revokes only the lease')
reconnect();scene=status('scene-chat')
check(scene.input_owner=='remote','explicit reconnect reclaims scene-owned native input')
request('respond',answer(scene,'scene-close'));frame()
check(status('scene-chat').status=='completed' and status('scene-chat').execution_released and changes==1,
    'answer completes original change-level invocation without reentry')
act('scene-chat',{type='change_level'},revision);frame()
check(changes==1,'duplicate completed change-level command cannot run native change again')
Compat.matches=matches

-- Round-9 feedback: observe.sections must not erase control metadata, an
-- unknown section is rejected, a player sub-field prunes the player container,
-- an unknown talent id differs from an unlearned one, and static target
-- geometry (incl. the native self-fire default) is advertised before acting.
fresh()
p.talents_def={T_FIXTURE={id='T_FIXTURE',name='Fixture',type={'fixture'},mode='activated',
    target={type='ball',range=6,radius=1},cooldown=3}}
p.talents={T_FIXTURE=1}
p.talents_cd={}
local trimmed=request('observe',{session_id=hello.session_id,sections={'effects'}}).result
check(trimmed.actionable~=nil and trimmed.phase~=nil,'sections keeps control metadata')
check(trimmed.map==nil and trimmed.actors==nil,'sections omits unrequested domains')
check(type(trimmed.player)=='table' and trimmed.player.id~=nil,'effects section keeps player identity')
check(trimmed.player.effects~=nil and trimmed.player.inventory==nil,'effects section prunes unrelated player fields')
check(request('observe',{session_id=hello.session_id,sections={'bogus'}}).error.code=='invalid_sections','unknown section rejected')
local talent=request('inspect',{session_id=hello.session_id,kind='talent',id='T_FIXTURE'}).result
check(talent.range==6 and talent.target_shape=='ball','inspect advertises the static range and shape')
check(talent.target_geometry and talent.target_geometry.selffire==true,'a ball without selffire defaults to self-fire true')
check(request('inspect',{session_id=hello.session_id,kind='talent',id='T_NOPE'}).error.code=='unknown_talent','unknown talent id distinct from unlearned')

print('Interactive Runtime: '..count..' checks passed')
