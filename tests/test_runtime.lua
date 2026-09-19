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
-- Build a fixture method at an audited engine source path so the movement helper
-- identity check accepts it via the headless hash-unavailable fallback.
local function engineFn(source,src)
    return assert(loadstring(src,'@'..source))()
end
local base={
    display=function() end,
    tick=function(g)
        if g.nested_error and not g.nesting then g.nesting=true;return g:tick() end
        local queued=g.queue;g.queue={};for _,fn in ipairs(queued) do fn() end
        if g.tick_failure then error('native failure sentinel') end
    end,
    loaded=function(g) g.tick_failure=false;g.nested_error=false;g.nesting=false;g.player.energy.value=1000;g.paused=true end,
    onRegisterDialog=function() end,onUnregisterDialog=function() end,
    changeLevelReal=function(g) if g.change_failure then error('change failure sentinel') end end,
    saveGame=function(g) if g.save_failure then error('save failure sentinel') end end,
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
    function p:canProject() return true end
    Runtime.reset(g);g:display()
    local seq=0
    local function request(op,args)
        seq=seq+1;channel.options.onRequest{v=4,id=tostring(seq),op=op,args=args}
        return channel.messages[#channel.messages]
    end
    local hello=request('connect',{token='unit-test-token'}).result
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
    local function reconnect() local fresh=request('connect',{token='unit-test-token'}).result
        for k in pairs(hello) do hello[k]=nil end;for k,v in pairs(fresh) do hello[k]=v end;return hello end
    return g,p,enemy,hello,request,observe,act,status,ready,reconnect
end

local g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
local original=observe()
check(original.phase=='ready' and #original.actors==1,'ordinary native perception fallback without callbacks')
check(observe().revision==original.revision and g.turn==1 and p.energy.value==1000,'repeated observe changes neither game nor revision')
check(original.map.cells[1].blocked==false,'explicit passable boolean preserved')
p.can_see_cache={[enemy]={['nil/nil']={false}}}
check(#observe().actors==0,'negative cache takes priority')
p.can_see_cache=nil;enemy.invisible=10
check(#observe().actors==0,'uncached invisibility hidden')
enemy.invisible=nil;p.attr=function() return nil end
-- NO-AUDIT: a replaced perception helper is not a gate; the visible actor stays visible.
check(#observe().actors==1,'a replaced perception helper does not hide the actor')
p.attr=attr
local rev=observe().revision
check(act('move',{type='move',direction=4},rev).result.status=='queued','single action queued')
check(act('move',{type='move',direction=4},rev).result.status=='queued','queued duplicate returns record')
g:tick();g:display()
check(status('move').status=='settling' and p.x==1,'action awaits native settlement')
ready()
local result=status('move')
check(result.status=='completed' and result.energy_spent==1000 and result.snapshot.phase=='ready','completed next-ready snapshot')
check(act('move',{type='move',direction=4},rev).result.status=='completed' and p.x==1,'completed duplicate cannot move twice')
check(act('move',{type='wait'},rev).error.code=='command_conflict','conflicting command rejected')
check(act('stale',{type='wait'},rev).error.code=='stale_revision','stale revision rejected')
check(act('manual',{type='wait'}).result.status=='queued','queued before manual takeover')
g.key:receiveKey(1,false,false,false,false,'',false)
check(channel.disconnected=='manual_input','key disconnects before native input')
reconnect()
check(status('manual').status=='cancelled','cancelled record survives reconnect')
g:tick();g:display()

g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
-- v4 ledger: capacity is bounded by eviction, never by rejecting new writes.
check(observe().history.next_command_id=='cmd-1','fresh session starts at cmd-1')
act('ledger-a',{type='wait'});g:tick();ready()
act('ledger-b',{type='wait'});g:tick();ready()
check(observe().history.last_accepted_seq==2 and observe().history.next_command_id=='cmd-3',
    'accepted commands advance the canonical sequence and expose the next id')
check(status('ledger-a').status=='completed','an earlier receipt is still queryable')
local dialog={key={receiveKey=function() end},mouse={receiveMouse=function() end}}
g.dialogs={dialog};g:onRegisterDialog(dialog)
reconnect()
check(observe().phase=='needs_input','dialog prevents world actions')
dialog.key:receiveKey(1,false,false,false,false,'',false)
check(channel.disconnected=='manual_input','dialog input revokes and disconnects')

g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
act('error',{type='wait'})
g.tick_failure=true;g.nested_error=true
local ok,err=pcall(g.tick,g)
check(not ok and tostring(err):find('native failure sentinel',1,true),'nested native error rethrown')
local polls=channel.polls;g:display()
check(channel.polls>polls,'nested error balances tick depth and leaves transport alive')
local failed=status('error')
check(failed.status=='failed' and failed.uncertain and failed.code=='native_tick_error','partial action reports uncertain native error')
check(failed.action_ok==false,'a failed command reports action_ok=false, not nil')
reconnect()
check(observe().phase=='unavailable','native error remains read-only after reconnect')
check(act('after_error',{type='wait'}).error.code=='not_ready','native error forbids writes')
local abandoned=request('abandon',{session_id=hello.session_id,control_token=hello.control_token})
check(abandoned.result and abandoned.result.recovered
    and abandoned.result.recovery~='fresh_load_required','abandon clears bridge isolation')
check(abandoned.result.phase~=nil,'abandon reports the phase it left the game in')
check(observe().phase~='unavailable' and observe().control_lease=='held','abandon restores a usable session')
check(request('abandon',{session_id=hello.session_id,control_token=hello.control_token}).error.code=='not_isolated','a second abandon reports not_isolated')
g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
-- An unowned native rest must not lock the session: the next action cancels it.
p.resting={cnt=1}
p.restStop=function(self) self.resting=nil end
check(observe().native_activity=='rest_unowned','observe reports an unowned native rest')
local cleared=act('unowned-rest',{type='wait'})
check(cleared.result~=nil and p.resting==nil,'an unowned native rest is cancelled before admitting the action')
g:tick();g:display()
check(status('unowned-rest').status~='failed','the command proceeds after cancelling the unowned rest')
-- auto_explore: a visible hostile refuses; otherwise the native run is owned.
g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
local function nativeAt(suffix,body) return assert(loadstring('return '..body,'@'..suffix))() end
p.autoExplore=nativeAt('/mod/class/interface/PlayerExplore.lua','function(self) self.running={explore="unseen",cnt=0} return true end')
p.runStep=nativeAt('/engine/interface/PlayerRun.lua','function(self) self.running.cnt=self.running.cnt+1 return self.running.cnt<3 end')
p.enoughEnergy=nativeAt('/engine/Actor.lua','function(self) return true end')
p.runStop=function(self) self.running=nil end
g.level.entities={p,enemy}
p.can_see_cache={[enemy]={['nil/nil']={true}}}
enemy.reaction=-1
act('explore-blocked',{type='auto_explore'});g:tick();g:display()
check(status('explore-blocked').code=='enemies_in_sight' and status('explore-blocked').action_ok==false,
    'auto-explore refuses with a visible hostile')
-- A visible friendly escort is not hostile and must not block auto-explore.
enemy.reaction=1
p.running=nil
act('explore-friendly',{type='auto_explore'});g:tick();g:display()
check(status('explore-friendly').code~='enemies_in_sight','a friendly escort does not block auto-explore')
p.running=nil;g:tick();g:display()
g.level.entities={p}
act('explore',{type='auto_explore'});g:tick();g:display()
check(p.running~=nil and status('explore').status~='failed','auto-explore starts the native run')
check(observe().phase=='settling','an owned auto-explore run settles the game')
p.running=nil
g:tick();g:display()
check(status('explore').status=='completed','auto-explore completes when the native run ends')
g.level.no_autoexplore=true
act('explore-forbidden',{type='auto_explore'});g:tick();g:display()
check(status('explore-forbidden').code=='no_autoexplore','a no_autoexplore level refuses auto-explore')
g.level.no_autoexplore=nil
-- The native "Running..." popup belongs to the owned run; it must not be
-- treated as an unanswered interaction that aborts the run.
g.level.entities={p}
g.dialogs={}
p.running=nil
p.autoExplore=nativeAt('/mod/class/interface/PlayerExplore.lua',
    'function(self) self.running={explore="unseen",cnt=0} '
    ..'self.running.dialog={title="Running...",key={virtuals={}},uis={}} '
    ..'g.dialogs={self.running.dialog} g:onRegisterDialog(self.running.dialog) return true end')
act('explore-owned',{type='auto_explore'});g:tick();g:display()
check(status('explore-owned').code~='explore_interrupted','the Running popup does not abort auto-explore')
check(observe().phase~='needs_input','the Running popup keeps the run settling, not needs_input')
p.running=nil;g.dialogs={}
g:tick();g:display()
local old_session=hello.session_id
g:loaded();g:display();reconnect()
check(hello.session_id~=old_session and observe().phase=='ready','reload creates usable new session')
check(request('status',{session_id=old_session,command_id='cmd-1'}).error.code=='session_mismatch','old session rejected')
g.save_failure=true;ok=pcall(g.saveGame,g);g:display()
check(not ok and observe().phase=='unavailable','save exception keeps frame access and quarantines writes')
g:loaded();g:display();reconnect()
g.change_failure=true;ok=pcall(g.changeLevelReal,g);g:display()
check(not ok and observe().phase=='unavailable','change exception keeps frame access and quarantines writes')
local old_game=setmetatable({}, {__mode='v'})
do
    local previous={key={receiveKey=function() end},mouse={receiveMouse=function() end},dialogs={}}
    old_game[1]=previous
    require('mod.mcp_bridge.Input').attach(previous)
end
collectgarbage('collect');collectgarbage('collect')
check(old_game[1]==nil,'input handler registry does not retain old game')
local native_attack=assert(loadstring('return function() end','@/data/talents/misc/misc.lua'))()
local attacker={x=1,y=1,T_ATTACK='T_ATTACK',energy={value=1000},talents_def={T_ATTACK={action=native_attack,target=native_attack}},
    useTalent=function(self) self.energy.value=0;return false end}
local rejected=require('mod.mcp_bridge.Actions').execute({player=attacker},{type='attack',target_id='target'},{x=2,y=1})
check(not rejected.ok and rejected.native_return==false and rejected.energy_spent==1000,'native attack pre-use failure retains false and energy cost')
local running,stops=false,0
package.loaded['mod.battle_companion.Controller']={
    isRunning=function() return running end,
    observation=function() return {state=running and 'running' or 'paused',actions=3} end,
    remoteTakeover=function() running=false;stops=stops+1 end,
}
g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
running=true
local watched=request('connect_observer',{token='unit-test-token'}).result
check(watched.mode=='observe' and watched.control_token==require('mod.mcp_bridge.Json').null,'observer receives no control lease')
check(not Runtime.hasControl(p) and running and stops==0,'observer preserves local combat')
check(watched.snapshot.control_source=='battle_companion' and watched.snapshot.phase=='unavailable','local combat is the reported action owner')
check(watched.snapshot.battle_companion.actions==3,'snapshot exposes a small controller summary')
local watched_revision=observe().revision
check(request('connect_observer',{token='unit-test-token'}).result.revision==watched_revision,'repeated observer connect does not invalidate a snapshot')
check(act('observer-write',{type='wait'}).error.code=='read_only_connection','observer cannot act even with a former lease')
check(request('stop',{session_id=hello.session_id,control_token=hello.control_token}).error.code=='read_only_connection','observer cannot stop local combat')
check(#g.queue==0 and p.energy.value==1000,'observer writes queue no action and spend no energy')
check(request('connect',{token='wrong'}).error.code=='authentication_failed' and running,'failed authentication never stops local combat')
reconnect()
check(not running and stops==1 and Runtime.hasControl(p),'explicit control pauses local combat before granting lease')
check(observe().control_source=='remote' and observe().phase=='ready','remote lease is the only owner after takeover')
act('downgrade',{type='wait'})
request('connect_observer',{token='unit-test-token'})
check(status('downgrade').status=='cancelled','downgrading to observation cancels an unstarted remote action')
g:tick();g:display()
check(p.energy.value==1000 and not running,'downgrade never executes or restarts local combat')
check(observe().control_source=='manual' and not Runtime.hasControl(p),'observer leaves manual ownership when no assistant runs')
g.key:receiveKey(1,false,false,false,false,'',false)
check(channel.disconnected=='manual_input','manual input still disconnects observer sessions')
package.loaded['mod.battle_companion.Controller']=nil

-- Exercise new irreversible point/inventory mutations through the real command
-- queue. These handlers are controlled unit stand-ins; ordinary native growth
-- and equipment evidence is supplied by the saved-campaign acceptance runner.
local Actions=require 'mod.mcp_bridge.Actions'
local original_execute=Actions.execute
local executed=0
local uncertain=false
Actions.execute=function(game,action,target,metadata)
    executed=executed+1
    check(metadata.session_id~=nil and metadata.level_instance_id~=nil,'item execution receives current ID scope')
    game.player.unused_stats=(game.player.unused_stats or 9)-1
    if uncertain then return {ok=false,code='native_growth_error',energy_spent=0,uncertain=true,native_message='partial native change'} end
    return {ok=true,code='action_complete',energy_spent=0,
        points_spent=action.type=='spend_stat' and 1 or nil,
        point_pool=action.type=='spend_stat' and 'stats' or nil,
        previous_value=action.type=='spend_stat' and 15 or nil,
        new_value=action.type=='spend_stat' and 16 or nil}
end
g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
p.unused_stats=9
rev=observe().revision
local stat_action={type='spend_stat',stat='str'}
check(act('point',stat_action,rev).result.status=='queued','single point mutation queued')
check(act('point',stat_action,rev).result.status=='queued' and p.unused_stats==9,'queued duplicate consumes no points')
g:tick();g:display()
local learned=status('point')
check(learned.status=='completed' and p.unused_stats==8 and executed==1,'instant point change settles once')
check(learned.points_spent==1 and learned.point_pool=='stats' and learned.previous_value==15 and learned.new_value==16,
    'completed growth retains scalar cost and value evidence in command status')
check(learned.snapshot.revision>rev and learned.snapshot.world_tick==1,'zero-energy growth still changes revision')
check(act('point',stat_action,rev).result.status=='completed' and p.unused_stats==8,'completed duplicate consumes no second point')
check(act('point',{type='spend_stat',stat='dex'},rev).error.code=='command_conflict','different stat cannot share command id')
reconnect()
check(act('point',stat_action,rev).result.status=='completed' and executed==1,'reconnected duplicate recovers committed growth')
local inventory_action={type='equip',item_id=hello.session_id..':object-42'}
rev=observe().revision
act('equipment',inventory_action,rev);g:tick();g:display()
check(status('equipment').status=='completed' and executed==2,'inventory mutation settles through ordinary queue')
check(act('equipment',{type='equip',item_id=hello.session_id..':object-43'},rev).error.code=='command_conflict','different item id cannot share command id')
check(act('equipment',inventory_action,rev).result.status=='completed' and executed==2,'equipment duplicate does not call native operation twice')
act('cancelled-growth',{type='learn_talent',talent_id='T_WEAPONS_MASTERY'})
request('stop',{session_id=hello.session_id,control_token=hello.control_token})
g:tick();g:display()
check(status('cancelled-growth').status=='cancelled' and executed==2,'stop cancels queued learning before point use')
reconnect();uncertain=true
act('partial-growth',stat_action);g:tick();g:display()
local partial=status('partial-growth')
check(partial.status=='failed' and partial.uncertain and partial.native_message=='partial native change','partial native growth failure preserves uncertainty')
check(observe().phase=='unavailable' and observe().control_source=='manual','partial mutation revokes lease and preserves read-only state')
reconnect()
check(act('after-partial',stat_action).error.code=='not_ready','reconnect cannot bypass failed mutation quarantine')
check(executed==3 and p.unused_stats==6,'failed partial mutation is not rolled back or repeated')
Actions.execute=original_execute

-- NEW-03 (P1): a replaced-but-callable on_levelup_close can schedule the undo
-- with the real native pattern game:onTickEnd (official talents do this too,
-- e.g. data/talents/psionic/solipsism.lua:48). Both synchronous checks inside
-- Progression.execute see the requested delta, so Runtime stores the already
-- successful result while the queued callback later restores the
-- pre-operation state. The settlement path must re-validate the recorded
-- postcondition AFTER the native tick-end queue drained and settle a mismatch
-- as a typed uncertain failure, never as success.
local Progression=require 'mod.mcp_bridge.Progression'
local Json=require 'mod.mcp_bridge.Json'
local deferred_undo=false
local deferred_recheck=false
Actions.execute=function(game,action,target,metadata)
    local pl=game.player
    pl.talents={T_RUSH=(pl.talents and pl.talents.T_RUSH or 0)+1}
    pl.unused_talents=(pl.unused_talents or 5)-1
    -- The real native scheduling pattern: an owned callback queued for the
    -- end of the current tick, after execute's own postcondition checks.
    game:onTickEnd(function()
        if deferred_undo then pl.talents.T_RUSH=pl.talents.T_RUSH-1;pl.unused_talents=pl.unused_talents+1 end
    end)
    return {ok=true,code='progression_applied',energy_spent=0,points_spent=1,point_pool='class',
        previous_value=pl.talents.T_RUSH-1,new_value=pl.talents.T_RUSH,
        postcondition={pool='unused_talents',expected_points=pl.unused_talents,
            operation='learn_talent',target='T_RUSH',expected_value=pl.talents.T_RUSH}}
end
g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
p.unused_talents=5
deferred_undo=true
rev=observe().revision
check(act('deferred-undo',{type='learn_talent',talent_id='T_RUSH'},rev).result.status=='queued','deferred-undo growth queued')
g:tick();g:display()
check(status('deferred-undo').status=='settling' and p.talents.T_RUSH==1 and p.unused_talents==4,
    'the owned deferred callback keeps the command settling after the accepted mutation')
g:tick();g:display()
local deferred=status('deferred-undo')
check(deferred.status=='failed' and deferred.uncertain and deferred.code=='native_progression_mismatch'
    and deferred.action_ok==false and p.talents.T_RUSH==0 and p.unused_talents==5,
    'a deferred game:onTickEnd undo settles as a typed uncertain failure through the Runtime settlement path: '..Json.encode(deferred))
check(observe().phase=='unavailable' and observe().control_source=='manual','a settled progression mismatch quarantines the session')
reconnect()
check(act('after-deferred',{type='wait'}).error.code=='not_ready','reconnect cannot bypass a settled mismatch quarantine')

g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
p.unused_talents=5
deferred_undo=false
rev=observe().revision
check(act('deferred-keep',{type='learn_talent',talent_id='T_RUSH'},rev).result.status=='queued','deferred-keep growth queued')
g:tick();g:display()
g:tick();g:display()
local kept=status('deferred-keep')
check(kept.status=='completed' and kept.action_ok==true and p.talents.T_RUSH==1 and p.unused_talents==4,
    'success is published only when the drained final state still matches the claim: '..Json.encode(kept))
Actions.execute=original_execute
-- M3: tome.list frozen collection pagination.
g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
p.talents={T_X=1,T_Y=2}
p.talents_def={T_X={id='T_X',mode='activated',name='X'},T_Y={id='T_Y',mode='activated',name='Y'}}
local list_first=request('list_collection',{session_id=hello.session_id,request={type='first',collection='talents',page_size=1}}).result
check(list_first and list_first.returned_count==1 and list_first.total_count==2
    and list_first.capture_complete==true and list_first.has_more,'tome.list freezes and pages a full collection')
local list_second=request('list_collection',{session_id=hello.session_id,request={type='next',cursor=list_first.next_cursor}}).result
check(list_second and list_second.returned_count==1 and list_second.has_more==false
    and list_second.items[1].id~=list_first.items[1].id,'the next cursor returns the remaining item without duplication')
reconnect()
local list_expired=request('list_collection',{session_id=hello.session_id,request={type='next',cursor=list_first.next_cursor}})
check(list_expired.error and list_expired.error.code=='cursor_expired','a new connection generation expires old cursors')
check(#observe().collection_refs==9,'observe advertises the nine collection refs')
local list_bad=request('list_collection',{session_id=hello.session_id,request={type='first',collection='nope'}})
check(list_bad.error and list_bad.error.code=='unsupported_collection','an unknown collection is rejected')
local list_badfilter=request('list_collection',{session_id=hello.session_id,request={type='first',collection='actors',filter={x=1}}})
check(list_badfilter.error and list_badfilter.error.code=='invalid_filter','an unknown filter is rejected')
-- M4: capability diagnostics (CMP-05/06).
check(hello.capabilities and hello.capabilities.action_support
    and hello.capabilities.action_support.learn_talent.implementation=='supported'
    and hello.capabilities.action_support.learn_talent.requirements=='native_checked'
    and hello.capabilities.action_support.use_talent.implementation=='supported',
    'capabilities expose an action_support matrix with native-checked growth')
local compat_inspect=request('inspect',{session_id=hello.session_id,kind='compatibility',id='runtime'}).result
check(compat_inspect and type(compat_inspect.scope)=='string' and type(compat_inspect.providers)=='table',
    'inspect compatibility returns an audited provider summary')
local compat_list=request('list_collection',{session_id=hello.session_id,request={type='first',collection='compatibility'}}).result
check(compat_list and compat_list.collection=='compatibility','the compatibility collection is enumerable')
-- F3: snapshots have their own 16-entry budget, independent of the receipt
-- ledger. Eviction keeps the receipt queryable but drops the snapshot.
g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
for i=1,17 do
    act('snap-'..i,{type='wait'});g:tick();ready()
end
local old_snapshot=status('snap-1')
check(old_snapshot.status=='completed','an old receipt survives beyond the snapshot window')
check(old_snapshot.snapshot_availability=='evicted' and old_snapshot.snapshot==nil,
    'an old snapshot is evicted independently of its receipt')
local new_snapshot=status('snap-17')
check(new_snapshot.snapshot_availability=='retained' and new_snapshot.snapshot~=nil,
    'the newest snapshot is retained')
-- Round-2 report 3.a/3.f: native target geometry and blocked moves.
local ActionsMod=require 'mod.mcp_bridge.Actions'
local wall=setmetatable({x=1,y=1,energy={value=1000},moveDir=function(self) return true end},
    {__index={}})
local blocked_move=ActionsMod.execute({player=wall},{type='move',direction=4},nil)
check(not blocked_move.ok and blocked_move.code=='blocked' and blocked_move.energy_spent==0,
    'a move that neither moves nor spends energy reports blocked')
-- P1a: auto-combat policy authoring surface (execution is a later slice).
do
    local policy={schema='tome-auto-combat/v1',id='p1',name='unit',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35},
        targeting={default='nearest_hostile'},
        rules={{id='beam',priority=1,when={enemy_count={ge=1}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}
    local invalid=request('policy',{session_id=hello.session_id,policy_op='validate',policy={schema='x'}})
    check(not invalid.result and invalid.error.code=='invalid_policy','policy validate refuses an invalid policy')
    local valid=request('policy',{session_id=hello.session_id,policy_op='validate',policy=policy})
    check(valid.result and valid.result.hash,'policy validate accepts a valid policy')
    local draft=request('policy',{session_id=hello.session_id,policy_op='set_draft',policy=policy}).result
    check(draft and draft.draft_hash,'policy set_draft stores a valid policy')
    check(type(g.player.auto_combat_policy)=='table' and g.player.auto_combat_policy.draft~=nil,
        'a policy write is persisted on the character')
    local conflict=request('policy',{session_id=hello.session_id,policy_op='set_draft',policy=policy,expected_hash='deadbeef'})
    check(not conflict.result and conflict.error.code=='policy_conflict','a stale policy write conflicts')
    local approved=request('policy',{session_id=hello.session_id,policy_op='approve',expected_hash=draft.draft_hash}).result
    check(approved and approved.approved_hash,'policy approve certifies the draft')
    local activated=request('policy',{session_id=hello.session_id,policy_op='activate',expected_hash=approved.approved_hash}).result
    check(activated and activated.running_hash,'policy activate promotes the approved policy')
    check(g.player.auto_combat_policy.approved~=nil,'the approved policy is persisted on the character')
    -- Planning-level dry run is a read: it evaluates the running policy against
    -- the audited snapshot without executing anything.
    local dry=request('policy',{session_id=hello.session_id,policy_op='dry_run'})
    check(dry.result and dry.result.dry_run==true and dry.result.executed==false
        and dry.result.side_effects=='none','dry_run is a read that runs nothing')
    check(dry.result.decision=='act' or dry.result.decision=='hold' or dry.result.decision=='pause',
        'dry_run returns a decision')
    check(type(dry.result.results)=='table','dry_run returns the per-rule trace')
    check(dry.result.snapshot and dry.result.snapshot.level_instance_id~=nil,
        'dry_run carries snapshot metadata')
    check(dry.result.policy_source=='running','dry_run defaults to the running policy')
    local start=request('policy',{session_id=hello.session_id,policy_op='start'})
    check(not start.result and start.error.code=='execution_not_available','execution is not wired yet')
    local policy_status=request('policy',{session_id=hello.session_id,policy_op='status'}).result
    check(policy_status and policy_status.control_owner=='auto_combat','policy status reports the lease owner')
    local log=request('policy_log',{session_id=hello.session_id,limit=5}).result
    check(log and log.events~=nil,'policy_log returns the event ring')
    local replay=request('policy',{session_id=hello.session_id,policy_op='replay',limit=8}).result
    check(replay and replay.replay==true and replay.executed==false and replay.header~=nil,
        'replay returns an ordered decision history with a header')
    Runtime.manualInput(g,'unit')
    local after=request('policy',{session_id=hello.session_id,policy_op='status'})
    check(after.error and after.error.code=='not_connected','a manual input returns control and closes the session')
end
-- P1a: dry_run is a read, so it is allowed on an observe connection even when
-- live execution is disabled.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
    local h=request('connect',{token='unit-test-token'}).result
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='beam',priority=1,when={enemy_count={ge=1}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}
    request('policy',{session_id=h.session_id,policy_op='set_draft',policy=pl})
    local obs=request('connect_observer',{token='unit-test-token'}).result
    local dry=request('policy',{session_id=obs.session_id,policy_op='dry_run'})
    check(dry.result and dry.result.dry_run==true and dry.result.executed==false
        and dry.result.policy_source~=nil,
        'dry_run is allowed on an observe connection with execution disabled')
    local replay=request('policy',{session_id=obs.session_id,policy_op='replay',limit=4})
    check(replay.result and replay.result.replay==true and replay.result.executed==false,
        'replay is a read available on an observe connection')
    local blocked=request('policy',{session_id=obs.session_id,policy_op='set_draft',policy=pl})
    check(blocked.error and blocked.error.code=='read_only_connection',
        'observe mode still refuses policy writes')
    local assist={format='tome-auto-combat-assistant-export/v1',
        assistant={addon='auto_talent_assistant',addon_version={2,3,9},tome_version={1,7,4}},
        class='celestial/anorithil',settings={min_hp_pct=35},
        talents={{talent='T_HEALING_LIGHT',enabled=true,priority=100,emergency=true,
            when={hp_pct={lt=50}}}}}
    local draft_before=Runtime.autoCombatStatus(g).draft_hash
    local generated=request('policy',{session_id=obs.session_id,policy_op='import_assistant',config=assist})
    check(generated.result and generated.result.imported==true and generated.result.draft~=nil,
        'assistant generation is a read available on an observe connection')
    check(Runtime.autoCombatStatus(g).draft_hash==draft_before,'observe generation does not store a draft')
    local store_blocked=request('policy',{session_id=obs.session_id,policy_op='import_assistant',
        config=assist,store=true})
    check(store_blocked.error and store_blocked.error.code=='read_only_connection',
        'storing an imported draft is control-only')
    reconnect()
end
-- P3: assistant import generates a draft (and stores it only on request).
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
    local h=request('connect',{token='unit-test-token'}).result
    local assist={format='tome-auto-combat-assistant-export/v1',
        assistant={addon='auto_talent_assistant',addon_version={2,3,9},tome_version={1,7,4}},
        class='celestial/anorithil',settings={min_hp_pct=35},
        talents={{talent='T_HEALING_LIGHT',enabled=true,priority=100,emergency=true,
            when={hp_pct={lt=50}}}},
        sustains={{talent='T_CHANT_OF_FORTRESS',enabled=true,priority=20}}}
    local generated=request('policy',{session_id=h.session_id,policy_op='import_assistant',config=assist})
    check(generated.result and generated.result.imported==true and generated.result.stored==nil,
        'import_assistant generates a draft without storing it')
    local approved_before=Runtime.autoCombatStatus(g).approved_hash
    local stored=request('policy',{session_id=h.session_id,policy_op='import_assistant',
        config=assist,store=true})
    check(stored.result and stored.result.stored and stored.result.stored.draft_hash,
        'import_assistant stores the draft on explicit request')
    check(g.player.auto_combat_policy and g.player.auto_combat_policy.draft~=nil,
        'the stored import is persisted on the character')
    check(Runtime.autoCombatStatus(g).approved_hash==approved_before,'import_assistant never approves')
    local wrong=request('policy',{session_id=h.session_id,policy_op='import_assistant',
        config={format='tome-auto-combat-assistant-export/v1',
            assistant={addon='auto_talent_assistant',addon_version={9,9,9}},
            talents={{talent='T_HEALING_LIGHT',enabled=true,priority=1,when={always={}}}}}})
    check(wrong.error and wrong.error.code=='assistant_version_mismatch',
        'import_assistant refuses a wrong assistant version')
    reconnect()
end
-- P1a: reading a character restores the policy but never the run.
do
    check(type(g.player.auto_combat_policy)=='table' and g.player.auto_combat_policy.approved~=nil,
        'the character carries an approved policy')
    Runtime.reset(g);g:display()
    local h3=request('connect',{token='unit-test-token'}).result
    local restored=request('policy',{session_id=h3.session_id,policy_op='status'}).result
    check(restored.approved_hash~=nil and restored.active==false,
        'reading a character restores the policy but not the run')
    check(restored.control_owner=='manual','control stays with the player on load')
end
-- P1a: live execution is opt-in; when enabled the pump is wired and fails safe.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    Runtime.reset(g);g:display()
    local h2=request('connect',{token='unit-test-token'}).result
    -- R-1 note: this pump fixture uses a `wait` rule so the production executor
    -- completes a real charged action on this headless fixture and the pump
    -- keeps the auto-combat lease. (An action the fixture cannot execute is a
    -- settled no-energy reject under the resolved R-1 contract: the run stops
    -- honestly and releases the lease instead of pausing with the lease held.)
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='wait',priority=1,when={always={}},['then']={action='wait'}}}}
    request('policy',{session_id=h2.session_id,policy_op='set_draft',policy=pl})
    local ap=request('policy',{session_id=h2.session_id,policy_op='approve'}).result
    request('policy',{session_id=h2.session_id,policy_op='activate',expected_hash=ap.approved_hash})
    local st=request('policy',{session_id=h2.session_id,policy_op='start'})
    check(st.result and st.result.state~=nil,'live execution starts when enabled')
    Runtime.beforeTick(g);g.turn=g.turn+10;p.energy.value=1000;g.paused=true
    Runtime.onReady(p);Runtime.afterTick(g)
    local pump_ok=pcall(Runtime.onFrame,g)
    check(pump_ok,'the auto-combat pump does not raise')
    local ps=request('policy',{session_id=h2.session_id,policy_op='status'}).result
    check(ps and ps.control_owner=='auto_combat','the pump keeps the auto-combat lease')
    ready()  -- the charged wait spent the fixture energy; return to a ready boundary
    -- Owner exclusivity: a remote act is refused while auto-combat owns the
    -- lease, and reconnecting control takes it back atomically.
    for k,v in pairs(h2) do hello[k]=v end
    local observed_auto=observe().auto_combat
    check(observed_auto and observed_auto.enabled==true and observed_auto.state~=nil,
        'observe exposes a bounded auto-combat summary')
    local blocked=act('auto-blocked',{type='wait'})
    check(blocked.error and blocked.error.code=='control_conflict',
        'a remote act during auto-combat is refused with control_conflict')
    reconnect()
    local taken=request('policy',{session_id=hello.session_id,policy_op='status'}).result
    check(taken and taken.control_owner=='manual','reconnecting control takes the auto-combat lease')
    -- The charged wait spent the fixture energy again; after the reconnect the
    -- run loses the lease (control_lost) on the next pump, so this boundary
    -- stays ready for the remote act.
    ready()
    local allowed=act('auto-allowed',{type='wait'})
    check(allowed.result and allowed.result.status=='queued','after reconnect the remote can act again')
    g:tick();ready()
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
end
-- Round-3 follow-up #45 (Option A): a safety pause releases the lease and
-- stops the run, so a remote act needs no reconnect; observe.auto_combat is a
-- stable object before activation and after the handoff.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
    Runtime.reset(g);g:display()
    local h2=request('connect',{token='unit-test-token'}).result
    for k,v in pairs(h2) do hello[k]=v end
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,flee_below_hp_pct=25},targeting={default='nearest_hostile'},
        rules={{id='attack',priority=1,when={always={}},['then']={action='attack',target='nearest_hostile'}}}}
    request('policy',{session_id=h2.session_id,policy_op='set_draft',policy=pl})
    local ap=request('policy',{session_id=h2.session_id,policy_op='approve'}).result
    request('policy',{session_id=h2.session_id,policy_op='activate',expected_hash=ap.approved_hash})
    request('policy',{session_id=h2.session_id,policy_op='start'})
    -- Force the safety threshold and pump one frame.
    p.life=10
    Runtime.beforeTick(g);g.turn=g.turn+10;p.energy.value=1000;g.paused=true
    Runtime.onReady(p);Runtime.afterTick(g)
    pcall(Runtime.onFrame,g)
    local after=observe().auto_combat
    check(after and after.state=='stopped' and after.enabled==true,
        'a safety pause leaves a stopped run in the stable observe summary')
    local ps=request('policy',{session_id=h2.session_id,policy_op='status'}).result
    check(ps and ps.control_owner=='manual','a safety pause releases the auto-combat lease')
    -- The same remote lease acts without reconnecting (no control_conflict).
    local allowed=act('flee-act',{type='wait'})
    check(allowed.result and allowed.result.status=='queued','a remote act succeeds after a safety handoff')
    g:tick();ready()
    -- Stable shape with execution disabled and no policy at all.
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
    reconnect()
    local idle=observe().auto_combat
    check(idle~=nil and idle.state=='stopped' and idle.enabled==false and idle.active==false
        and idle.policy_id~=nil and idle.policy_hash~=nil and idle.generation~=nil
        and type(idle.last_decisions)=='table',
        'observe.auto_combat is a stable stopped object before activation')
end
-- P1a: standalone in-game editor accessors. No MCP transport is involved, so
-- this is the "works with no MCP client" path required by the design.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='attack',priority=1,when={always={}},['then']={action='attack',target='nearest_hostile'}}}}
    local set=Runtime.autoCombatHandle(g,'set_draft',{policy=pl})
    check(set.ok and set.draft_hash,'the local editor can write a draft')
    check(g.player.auto_combat_policy and g.player.auto_combat_policy.draft~=nil,
        'the local editor write is persisted on the character')
    local approved=Runtime.autoCombatHandle(g,'approve',{expected_hash=set.draft_hash})
    check(approved.ok,'the local editor can approve')
    local activated=Runtime.autoCombatHandle(g,'activate',{expected_hash=approved.approved_hash})
    check(activated.ok,'the local editor can activate locally')
    local status=Runtime.autoCombatStatus(g)
    check(status and status.control_owner=='auto_combat','local activation grants the auto-combat lease')
    local blocked=Runtime.autoCombatHandle(g,'start',{})
    check(not blocked.ok and blocked.error.code=='execution_not_available',
        'start stays behind the local execution gate')
    check(Runtime.setAutoCombatExecution(g,true),'the editor can grant local execution')
    check(Runtime.autoCombatExecutionEnabled(g),'the local execution authorization is reflected')
    local start=Runtime.autoCombatHandle(g,'start',{})
    check(start.ok and start.run,'the standalone editor can start execution')
    local stopped=Runtime.autoCombatHandle(g,'stop',{reason='editor'})
    check(stopped.ok,'the standalone editor can stop execution')
    Runtime.setAutoCombatExecution(g,false)
    check(not Runtime.autoCombatExecutionEnabled(g),'local execution can be revoked')
end
-- Wave 1 production-path: scalar resources, the executor guard and hasControl.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,max_selffire_risk=0},targeting={default='nearest_hostile'},
        rules={{id='ray',priority=1,when={always={}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}
    -- AC-02: scalar resources with min_/max_ and an unlocked pool.
    p.positive=40;p.max_positive=100;p.min_positive=0
    p.negative=10;p.max_negative=50;p.min_negative=0
    p.resources_def={positive={talent='T_POS_POOL'},negative={talent='T_NEG_POOL'}}
    p.talents={T_POS_POOL=1,T_NEG_POOL=1}
    local read=Runtime.buildAutoCombatReadHostFor(g,pl)
    check(read.resource_value('positive')==40,'the scalar positive resource is read correctly')
    check(read.resource_pct('positive')==40,'the scalar positive percent is value/max')
    check(read.resource_value('negative')==10 and read.resource_pct('negative')==20,
        'the negative resource is read correctly')
    local logged=read.resources()
    check(logged and logged.positive==40 and logged.negative==10,
        'resource logging keeps the scalar values instead of nil')
    p.resources_def={positive={talent='T_LOCKED'}}
    local locked=Runtime.buildAutoCombatReadHostFor(g,pl)
    check(locked.resource_value('positive')==nil,'an unlocked-pool gate hides a locked resource')
    p.resources_def=nil

    -- AC-03: the version-pinned guard over the real bound target.
    p.x,p.y=2,2
    -- The production guard requires the pinned native builder for a
    -- builder-backed entry; supply one in this headless fixture.
    local saved_defs=p.talents_def
    p.talents_def={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',
        target=function() return {type='beam',range=10} end}}
    local ally={uid=99,name='ally',__is_actor=true,x=3,y=2,life=100,max_life=100,reaction=1,attr=p.attr}
    enemy.x,enemy.y=4,2;enemy.reaction=-1
    g.level.entities={[1]=p,[2]=ally,[3]=enemy}
    g.level.map.map[12][3]=p;g.level.map.map[13][3]=ally;g.level.map.map[14][3]=enemy
    local live=Runtime.buildAutoCombatHostFor(g,pl,{drift=function() return true end})
    local ctx=live.snapshot('nearest_hostile')
    local target=ctx and ctx.bound_target
    check(target~=nil,'the hostile target binds for the guard test')
    local hard=live.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})
    check(hard and hard.action=='reject' and hard.reason=='selffire_risk',
        'max_selffire_risk=0 rejects a beam with an ally in the line')
    local soft=Runtime.buildAutoCombatHostFor(g,{schema='tome-auto-combat/v1',id='p2',name='unit',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35,max_selffire_risk=50},
        targeting={default='nearest_hostile'},rules=pl.rules},{drift=function() return true end})
    local above=soft.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})
    check(above and above.action=='reject' and above.detail and above.detail.measurement==100,
        'a known risk above max_selffire_risk is rejected with its measurement')
    local within=Runtime.buildAutoCombatHostFor(g,{schema='tome-auto-combat/v1',id='p3',name='unit',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35,max_selffire_risk=100},
        targeting={default='nearest_hostile'},rules=pl.rules},{drift=function() return true end})
    local permitted=within.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})
    check(permitted and permitted.action=='permit' and permitted.detail.threshold==100,
        'a known risk within policy tolerance is permitted')
    check(live.guard({action='use_talent',talent='T_SEARING_LIGHT',bound_target=target})==nil,
        'a single-target adapter passes the ally guard')
    p.talents_def=saved_defs

    -- AC-07: the standalone lease is part of hasControl (native automatic
    -- talents are suppressed without any MCP control token).
    Runtime.reset(g);g:display()
    local set=Runtime.autoCombatHandle(g,'set_draft',{policy=pl})
    Runtime.autoCombatHandle(g,'approve',{expected_hash=set.draft_hash})
    local activated=Runtime.autoCombatStatus(g)
    Runtime.autoCombatHandle(g,'activate',{expected_hash=activated.approved_hash})
    check(Runtime.hasControl(p) and Runtime.autoCombatStatus(g).control_owner=='auto_combat',
        'the standalone auto-combat lease is part of hasControl')
    Runtime.autoCombatHandle(g,'deactivate',{})
    check(not Runtime.hasControl(p),'releasing the lease removes hasControl')
end
-- MOV-1..MOV-3 production path: the real host plans and executes a plain step,
-- annotates an off-vision grid request and annotates a random teleport landing.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    Runtime.reset(g);g:display()
    local pl={schema='tome-auto-combat/v1',id='mov',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,max_selffire_risk=0},targeting={default='nearest_hostile'},
        rules={{id='kite',priority=1,when={always={}},
            ['then']={action='move',target='nearest_hostile',
                destination={selector='away',anchor='bound_target',
                    accept={visibility='any',passability='native',hazard='any',landing='allow_random'}}}}}}
    p.x,p.y=2,2;enemy.x,enemy.y=3,2
    g.level.map.map[12][3]=p;g.level.map.map[13][3]=enemy
    -- Phase Door is level-scoped; a known effective level lets the planner's
    -- variant check pass (an unknown level now fails closed). The `attr` reader
    -- returns a definite absent attribute, and the def pins the audited dynamic
    -- getters the factory resolves.
    local saved_attr=p.attr
    -- Keep the audited Entity.lua source so `Observer.visible` still trusts the
    -- read, but make the absent `phase_door_force_precise` attribute a definite
    -- false (a successful read) rather than an error.
    p.attr=assert(loadstring('return function(self,name) return nil end','@/engine/Entity.lua'))()
    p.getTalentLevel=engineFn('/engine/interface/ActorTalents.lua',
        'return function(self,def) return def and def.probe_level or 1 end')
    p.talents_def=p.talents_def or {}
    p.talents_def.T_PHASE_DOOR={id='T_PHASE_DOOR',mode='activated',probe_level=1,
        getRange=function() return 6 end,getRadius=function() return 1 end}
    -- The movement adapter for a grid talent now calls the pinned builder for
    -- live geometry after the drift preflight; supply the audited-shaped fixture.
    p.talents_def.T_SKIRMISHER_CUNNING_ROLL={id='T_SKIRMISHER_CUNNING_ROLL',mode='activated',
        target=function() return {type='beam',range=4} end}
    local live2=Runtime.buildAutoCombatHostFor(g,pl,{drift=function() return true end})
    local bound=live2.snapshot('nearest_hostile').bound_target
    local planned=live2.plan({action='move',destination=pl.rules[1]['then'].destination,bound_target=bound})
    check(planned and planned.plan and planned.plan.kind=='step','the live host plans a plain step')
    local before_x=p.x
    local outcome=live2.request({action='move',plan=planned.plan,rule='kite'})
    check(outcome.status=='ok','the live host executes the planned step through Actions.execute')
    check(p.x~=before_x,'the native moveDir actually moved the player')
    -- An in-bounds but unseen grid request is annotated, not refused.
    g.level.map.seens[24]=nil;g.level.map.infovs[24]=nil;g.level.map.lites[24]=nil
    local grid=live2.plan({action='use_talent',talent='T_SKIRMISHER_CUNNING_ROLL',
        destination={selector='position',x=4,y=4,
            accept={visibility='any',passability='native',hazard='any',landing='allow_random'}}})
    check(grid and grid.plan.kind=='grid' and grid.plan.annotation.visible==false
        and grid.plan.annotation.known_passable=='unknown',
        'an off-vision grid request is annotated, not refused')
    -- MFT-REV-04: a known trap is `hazard=true` (known hazard), and avoid_known
    -- rejects it; the provider never labels an unknown cell safe.
    g.level.map.seens[24]=true;g.level.map.infovs[24]=true;g.level.map.lites[24]=true
    g.level.map.map[24][4]={all_know=true}
    local trapped=live2.plan({action='use_talent',talent='T_SKIRMISHER_CUNNING_ROLL',
        destination={selector='position',x=4,y=4,
            accept={visibility='any',passability='native',hazard='avoid_known',landing='allow_random'}}})
    check(trapped==nil,'a known trap is reported as a known hazard and rejected by avoid_known')
    g.level.map.map[24][4]=nil
    local random=live2.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',
            accept={visibility='any',passability='native',hazard='any',landing='allow_random'}}})
    check(random and random.plan.kind=='native_random'
        and random.plan.annotation.landing.kind=='random',
        'the live host annotates a random teleport landing')
    local strict=live2.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',
            accept={visibility='any',passability='native',hazard='any',landing='deterministic'}}})
    check(strict==nil,'a deterministic-landing policy rejects the random teleport as policy, not a plugin veto')
    p.attr=saved_attr
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
end
-- MAF-REV-06 (no-strict-audit): planning calls the live getter directly. A
-- replaced getter that returns a usable value is used; one that errors, is
-- missing or returns nil yields movement_derivation_unknown.
do
    Runtime.reset(g);g:display()
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local pl={schema='tome-auto-combat/v1',id='nogate',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,max_selffire_risk=0},targeting={default='nearest_hostile'},
        rules={{id='door',priority=1,when={always={}},
            ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',
                destination={selector='native_random',accept=accept}}}}}
    local plan={action='use_talent',talent='T_PHASE_DOOR',target='self',
        destination={selector='native_random',accept=accept}}
    p.attr=engineFn('/engine/Entity.lua','return function(self,id) return self[id] end')
    p.getTalentLevel=engineFn('/engine/interface/ActorTalents.lua',
        'return function(self,def) return 1 end')
    p.talents_def=p.talents_def or {}
    local saved_door=p.talents_def.T_PHASE_DOOR
    local host=Runtime.buildAutoCombatHostFor(g,pl,{drift=function() return true end})
    -- A replaced getter returning a usable value is used (no identity gate).
    p.talents_def.T_PHASE_DOOR={id='T_PHASE_DOOR',mode='activated',
        getRange=function() return 7 end,getRadius=function() return 2 end}
    local used,usedErr=host.plan(plan)
    check(used and used.plan and used.plan.kind=='native_random' and usedErr==nil,
        'a replaced live getter returning a usable value is used, not gated')
    -- An erroring getter is movement_derivation_unknown (value not obtainable).
    p.talents_def.T_PHASE_DOOR.getRange=function() error('boom') end
    local bad,err=host.plan(plan)
    check(bad==nil and err and err.reason=='movement_derivation_unknown',
        'an erroring live getter is movement_derivation_unknown')
    -- A missing getter is movement_derivation_unknown.
    p.talents_def.T_PHASE_DOOR.getRange=nil
    bad,err=host.plan(plan)
    check(bad==nil and err and err.reason=='movement_derivation_unknown',
        'a missing live getter is movement_derivation_unknown')
    -- A nil-returning getter is movement_derivation_unknown.
    p.talents_def.T_PHASE_DOOR.getRange=function() return nil end
    bad,err=host.plan(plan)
    check(bad==nil and err and err.reason=='movement_derivation_unknown',
        'a nil-returning live getter is movement_derivation_unknown')
    p.talents_def.T_PHASE_DOOR=saved_door
end
-- MAF-REV-06 real-dispatch: the fixtures implement the actual call graph
-- (getTalentLevel -> alterTalentLevelRaw/getTalentMastery -> getTalentTypeMastery
-- -> getTalentTypeFrom, and Phase Door getRange -> combatTalentSpellDamage ->
-- combatSpellpower -> combatSpellpowerRaw -> knowTalent/callTalent/getCun/...).
-- The live chain plans and is used directly; an erroring leaf only fails the
-- value.
do
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local saved_defs,saved_talents=p.talents_def,p.talents
    local A='/engine/interface/ActorTalents.lua'
    local ACT='/mod/class/Actor.lua'
    local C='/mod/class/interface/Combat.lua'
    local S='/engine/interface/ActorStats.lua'
    local E='/engine/interface/ActorTemporaryEffects.lua'
    local ENT='/engine/Entity.lua'
    local function installRealChain(actor)
        actor.getTalentLevelRaw=engineFn(A,'return function(self,id) if type(id)=="table" then id=id.id end return self.talents[id] or 0 end')
        actor.alterTalentLevelRaw=engineFn(ACT,'return function(self,t,lvl) if self:attr("all_talents_bonus_level") then lvl=lvl+self:attr("all_talents_bonus_level") end return lvl end')
        actor.getTalentTypeFrom=engineFn(A,'return function(self,id) local t=self.talents_def[id] return t and t.type and t.type[1] end')
        actor.getTalentTypeMastery=engineFn(ACT,'return function(self,tt,only_base) local def=self:getTalentTypeFrom(tt) if only_base then return 1 end return 1 end')
        actor.getTalentMastery=engineFn(A,'return function(self,t) return self:getTalentTypeMastery(t.type[1]) end')
        actor.getTalentLevel=engineFn(A,'return function(self,id) local t if type(id)=="table" then t,id=id,id.id else t=self.talents_def[id] end if not t then return 0 end local lvl=self:getTalentLevelRaw(id) if lvl>0 then lvl=self:alterTalentLevelRaw(t,lvl) end return lvl*(self:getTalentMastery(t) or 0) end')
        actor.getTalentRange=engineFn(A,'return function(self,t) if type(t.range)=="function" then return t.range(self,t) end return t.range end')
        actor.knowTalent=engineFn(A,'return function(self,id) return self.talents and self.talents[id]~=nil end')
        actor.getTalentFromId=engineFn(A,'return function(self,id) return self.talents_def and self.talents_def[id] end')
        actor.callTalent=engineFn(A,'return function(self,tid,name) local t=self:getTalentFromId(tid) if t and t[name] then return t[name](self,t) end end')
        actor.attr=engineFn(ENT,'return function(self,prop) return self.attrs and self.attrs[prop] end')
        actor.getCun=engineFn(S,'return function(self) return self.cun or 10 end')
        actor.getWil=engineFn(S,'return function(self) return self.wil or 10 end')
        actor.getMag=engineFn(S,'return function(self) return self.mag or 10 end')
        actor.hasEffect=engineFn(E,'return function(self,id) return self.tmp and self.tmp[id] end')
        actor.combatTalentScale=engineFn(C,'return function(self,t,low,high) local tl=type(t)=="table" and self:getTalentLevel(t) or t if tl<=0 then tl=0.1 end return low+(high-low)*tl/5 end')
        actor.combatLimit=engineFn(C,'return function(self,x,limit,ylow,xlow,yhigh,xhigh) return limit end')
        actor.combatTalentLimit=engineFn(C,'return function(self,t,limit,low,high,raw,mastery) local tl=type(t)=="table" and self:getTalentLevel(t) or t if tl<=0 then tl=0.5 end return limit end')
        actor.rescaleCombatStats=engineFn(C,'return function(self,v) return v end')
        actor.rescaleDamage=engineFn(C,'return function(self,dam) return dam end')
        actor.combatSpellpowerRaw=engineFn(C,'return function(self,add) add=add or 0 if self:knowTalent("T_ARCANE_CUNNING") then add=add+self:callTalent("T_ARCANE_CUNNING","getSpellpower")*self:getCun()/100 end if self:hasEffect("EFF_BLOODLUST") then add=add+self:hasEffect("EFF_BLOODLUST").spellpower end if self:attr("spellpower_reduction") then end return math.max(0,(self.combat_spellpower or 0)+add+self:getMag()),1 end')
        actor.combatSpellpower=engineFn(C,'return function(self,mod,add) mod=mod or 1 local d,am=self:combatSpellpowerRaw(add) return self:rescaleCombatStats(d)*mod*am end')
        actor.combatTalentSpellDamage=engineFn(C,'return function(self,t,base,max) local mod=max/((base+100)*((math.sqrt(5)-1)*0.8+1)) return self:rescaleDamage((base+self:combatSpellpower())*((math.sqrt(self:getTalentLevel(t))-1)*0.8+1)*mod) end')
    end
    local vaultPolicy={schema='tome-auto-combat/v1',id='chain',name='unit',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35,max_selffire_risk=0},
        targeting={default='nearest_hostile'},rules={{id='vault',priority=1,when={always={}},
            ['then']={action='use_talent',talent='T_SKIRMISHER_VAULT',destination={
                selector='position',x=3,y=2,accept=accept}}}}}
    local vaultPlan={action='use_talent',talent='T_SKIRMISHER_VAULT',
        destination={selector='position',x=3,y=2,accept=accept}}
    local function setupVault()
        p.x,p.y=2,2
        p.talents={T_SKIRMISHER_VAULT=5}
        installRealChain(p)
        p.talents_def=p.talents_def or {}
        p.talents_def.T_SKIRMISHER_VAULT={id='T_SKIRMISHER_VAULT',mode='activated',type={'technique/acrobatics',1},
            range=engineFn('/data/talents/techniques/acrobatics.lua','return function(self,t) return math.floor(self:combatTalentScale(t,3,8)) end'),
            target=function(self,t) return {type='beam',range=self:getTalentRange(t)} end}
        return Runtime.buildAutoCombatHostFor(g,vaultPolicy,{drift=function() return true end})
    end
    Runtime.reset(g);g:display()
    local ok,okErr=setupVault().plan(vaultPlan)
    check(ok and ok.plan and okErr==nil,'the live Vault chain plans')
    -- A replaced leaf returning a usable value is used directly.
    Runtime.reset(g);g:display()
    local liveHost=setupVault()
    p.combatTalentScale=function() return 3 end
    local livePlan,liveErr=liveHost.plan(vaultPlan)
    check(livePlan and livePlan.plan and liveErr==nil,
        'a replaced scaling helper returning a usable value is used, not gated')
    -- An erroring leaf is movement_derivation_unknown (value not obtainable).
    Runtime.reset(g);g:display()
    local errHost=setupVault()
    p.combatTalentScale=function() error('boom') end
    local bad,badErr=errHost.plan(vaultPlan)
    check(bad==nil and badErr and badErr.reason=='movement_derivation_unknown',
        'an erroring live helper is movement_derivation_unknown')
    -- Phase Door getRange reaches the spell-power chain.
    local doorPolicy={schema='tome-auto-combat/v1',id='door',name='unit',
        limits={max_actions_per_tick=1},safety={min_hp_pct=35,max_selffire_risk=0},
        targeting={default='nearest_hostile'},rules={{id='door',priority=1,when={always={}},
            ['then']={action='use_talent',talent='T_PHASE_DOOR',target='self',destination={
                selector='native_random',accept=accept}}}}}
    local doorPlan={action='use_talent',talent='T_PHASE_DOOR',target='self',
        destination={selector='native_random',accept=accept}}
    local function setupDoor()
        p.x,p.y=2,2
        p.talents={T_PHASE_DOOR=1,T_ARCANE_CUNNING=1}
        installRealChain(p)
        p.talents_def=p.talents_def or {}
        p.talents_def.T_PHASE_DOOR={id='T_PHASE_DOOR',mode='activated',type={'spell/conveyance',1},
            getRange=engineFn('/data/talents/spells/conveyance.lua','return function(self,t) return self:combatLimit(self:combatTalentSpellDamage(t,10,15),40,4,0,13.4,9.4) end'),
            getRadius=engineFn('/data/talents/spells/conveyance.lua','return function(self,t) return math.floor(self:combatTalentLimit(t,0,6,1)) end')}
        p.talents_def.T_ARCANE_CUNNING={id='T_ARCANE_CUNNING',mode='passive',type={'cunning/ambush',1},
            getSpellpower=engineFn('/data/talents/techniques/magical-combat.lua','return function(self,t) return 20 end')}
        return Runtime.buildAutoCombatHostFor(g,doorPolicy,{drift=function() return true end})
    end
    Runtime.reset(g);g:display()
    local dok,dokErr=setupDoor().plan(doorPlan)
    check(dok and dok.plan and dok.plan.kind=='native_random','the live Phase Door getRange chain plans')
    -- An erroring spell-power leaf is movement_derivation_unknown.
    Runtime.reset(g);g:display()
    local dHost=setupDoor()
    p.getCun=function() error('boom') end
    local dbad,dbadErr=dHost.plan(doorPlan)
    check(dbad==nil and dbadErr and dbadErr.reason=='movement_derivation_unknown',
        'an erroring spell-power leaf is movement_derivation_unknown')
    -- A missing spell-power method is movement_derivation_unknown too.
    Runtime.reset(g);g:display()
    local mHost=setupDoor()
    p.getMag=nil
    local mbad,mbadErr=mHost.plan(doorPlan)
    check(mbad==nil and mbadErr and mbadErr.reason=='movement_derivation_unknown',
        'a missing spell-power method is movement_derivation_unknown')
    p.talents_def,p.talents=saved_defs,saved_talents
end
-- Round-5 correction: the guard reads the real target spec from the audited
-- native builder and applies the engine filter defaults, not a catalog shorthand.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,max_selffire_risk=0},targeting={default='nearest_hostile'},
        rules={{id='ray',priority=1,when={always={}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}
    p.x,p.y=2,2
    local ally={uid=99,name='ally',__is_actor=true,x=4,y=2,life=100,max_life=100,reaction=1}
    enemy.x,enemy.y=6,2;enemy.reaction=-1
    g.level.entities={[1]=p,[2]=ally,[3]=enemy}
    g.level.map.map[12][3]=p;g.level.map.map[14][3]=ally;g.level.map.map[16][3]=enemy
    local saved_def,saved_talents,saved_attr=p.talents_def,p.talents,p.attr
    p.talents={T_FLAME=1}
    local live=Runtime.buildAutoCombatHostFor(g,pl,{drift=function() return true end})
    local target=live.snapshot('nearest_hostile').bound_target
    -- NO-AUDIT (v1.6): the absent fs/md5 hash service is advisory telemetry; it
    -- does not disable the action. The live builder is used directly.
    local undrifted=Runtime.buildAutoCombatHostFor(g,pl)
    local advisory=undrifted.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})
    check(advisory==nil or advisory.reason~='adapter_source_drift',
        'missing live hash services are advisory, not a runtime gate')
    -- The builder spec wins over the catalog: a friendly-safe ball over a beam
    -- catalog entry passes even though the catalog would warn about the ally line.
    p.talents_def={T_MOONLIGHT_RAY={id='T_MOONLIGHT_RAY',
        target=function() return {type='ball',range=6,radius=1,selffire=false,friendlyfire=false} end}}
    check(live.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})==nil,
        'the guard uses the builder spec, not the catalog shape')
    -- A self-containing ball with engine-default filters rejects.
    p.talents_def.T_MOONLIGHT_RAY.target=function()
        return {type='ball',range=6,radius=5,selffire=true,friendlyfire=true} end
    local selfhit=live.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})
    check(selfhit and selfhit.reason=='selffire_risk' and selfhit.detail.phase=='instant',
        'a self-containing ball with engine defaults rejects')
    -- Flame-like: a clear wide-line passes without Burning Wake; its positive-FF
    -- ground zone rejects once Burning Wake is active (even when empty).
    p.talents_def.T_FLAME={id='T_FLAME',target=function()
        return {type='widebeam',range=10,radius=1,selffire=false,friendlyfire=false} end}
    ally.x,ally.y=4,4
    -- Keep p.attr native-lookalike so Observer.visible still resolves the target.
    p.attr=assert(loadstring('return function(self,name) return nil end','@/engine/Entity.lua'))()
    check(live.guard({action='use_talent',talent='T_FLAME',bound_target=target})==nil,
        'a clear wide-line Flame passes without Burning Wake')
    p.attr=assert(loadstring('return function(self,name) if name=="burning_wake" then return 5 end end','@/engine/Entity.lua'))()
    local ground=live.guard({action='use_talent',talent='T_FLAME',bound_target=target})
    check(ground and ground.reason=='selffire_risk' and ground.detail.phase=='ground',
        'an active Burning Wake ground zone rejects')
    p.talents_def,p.talents,p.attr=saved_def,saved_talents,saved_attr
end
-- NO-AUDIT (v1.6): `spellFriendlyFire` is called directly as a normal
-- entrypoint. A replacement returning a usable number IS used; an erroring or
-- non-finite one is `unknown` and the component then fails closed on its value.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,max_selffire_risk=0},targeting={default='nearest_hostile'},
        rules={{id='fire',priority=1,when={always={}},
            ['then']={action='use_talent',talent='T_FIREFLASH',target='nearest_hostile'}}}}
    p.x,p.y=2,2
    enemy.x,enemy.y=6,2;enemy.reaction=-1
    g.level.entities={[1]=p,[2]=enemy}
    g.level.map.map[12][3]=p;g.level.map.map[16][3]=enemy
    local saved_defs=p.talents_def
    local saved_sff=p.spellFriendlyFire
    p.talents_def={T_FIREFLASH={id='T_FIREFLASH',target=function()
        return {type='ball',range=7,radius=5,selffire=0} end}}
    -- A replacement returning a usable value (0) is used: nothing to reject.
    p.spellFriendlyFire=function() return 0 end
    local live=Runtime.buildAutoCombatHostFor(g,pl,{drift=function() return true end})
    local target=live.snapshot('nearest_hostile').bound_target
    local used=live.guard({action='use_talent',talent='T_FIREFLASH',bound_target=target})
    check(used==nil,'a replaced spellFriendlyFire returning a usable value is used, not gated')
    -- An erroring replacement is unknown; the dynamic component fails closed.
    p.spellFriendlyFire=function() error('boom') end
    local broken=live.guard({action='use_talent',talent='T_FIREFLASH',bound_target=target})
    check(broken and broken.reason=='selffire_risk',
        'an erroring spellFriendlyFire is unknown and the component fails closed')
    p.talents_def,p.spellFriendlyFire=saved_defs,saved_sff
end
-- Wave 2: capability alignment (INT-05) and the full error envelope (INT-02).
do
    Runtime.reset(g);g:display()
    local h=request('connect',{token='unit-test-token'}).result
    local caps=h.capabilities
    local function has(list,value)
        for _,v in ipairs(list or {}) do if v==value then return true end end
        return false
    end
    check(has(caps.actions,'auto_explore'),'capabilities.actions lists remote auto_explore')
    check(caps.action_support.auto_explore and caps.action_support.auto_explore.implementation=='supported',
        'action_support describes auto_explore')
    check(has(caps.native_tasks,'task.auto_explore'),'native_tasks lists task.auto_explore')
    check(caps.auto_combat and has(caps.auto_combat.policy_ops,'get') and has(caps.auto_combat.policy_ops,'clear'),
        'auto_combat capabilities list get and clear')
    local bad=request('policy',{session_id=h.session_id,policy_op='validate',policy={schema='x'}})
    check(bad.error and bad.error.code=='invalid_policy','an invalid policy is refused')
    check(bad.error.category and bad.error.acceptance_scope and bad.error.recovery,
        'the error envelope carries category/acceptance_scope/recovery (INT-02)')
    check(bad.error.uncertain==false or bad.error.uncertain==true,'the error envelope carries uncertain')
end
-- P0/F4: the auto-combat executor never waits unbounded on a native invocation.
-- A live auto invocation that does not settle within the bound is aborted with a
-- typed `native_timeout`: the native targeting UI is cancelled, the invocation
-- released, control restored and a typed policy-log event recorded with the
-- action/talent/target and elapsed ticks.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
    p.x,p.y=2,2;enemy.x,enemy.y=3,2;enemy.reaction=-1
    g.level.map.map[12][3]=p;g.level.map.map[13][3]=enemy
    -- A native target request the auto slot cannot answer: simulate a native
    -- body that suspends itself on an unanswerable popup (the pre-fix Rush
    -- path). The production host still maps the real native_pending outcome.
    -- This is a leaf call (no native task), so the bounded abort applies.
    local Tracker=require 'mod.mcp_bridge.InvocationTracker'
    local Interactions=require 'mod.mcp_bridge.Interactions'
    local ActionsMod=require 'mod.mcp_bridge.Actions'
    local realExecute=ActionsMod.execute
    ActionsMod.execute=function(game,action,target,metadata,cmd)
        Tracker.start(game,cmd,function()
            return Tracker.call(game.player,'T_RUSH',function()
                local body=Tracker.createBody(function()
                    local d={key={receiveKey=function() end},mouse={receiveMouse=function() end}}
                    Interactions.openDialog(d,'dialog.confirm','Unanswerable','Pick',
                        {{label='Close',apply=function() game.dialogs={};game:onUnregisterDialog(d) end}},
                        function() game.dialogs={};game:onUnregisterDialog(d) end)
                    game.dialogs={d};game:onRegisterDialog(d)
                    coroutine.yield()
                    return true
                end)
                assert(coroutine.resume(body))
            end)
        end)
        return {ok=true,code='native_pending',energy_spent=0}
    end
    local set=Runtime.autoCombatHandle(g,'set_draft',{policy={schema='tome-auto-combat/v1',
        id='p1',name='unit',limits={max_actions_per_tick=1},safety={min_hp_pct=35},
        targeting={default='nearest_hostile'},
        rules={{id='rush',priority=1,when={always={}},
            ['then']={action='use_talent',talent='T_RUSH',target='nearest_hostile'}}}}})
    Runtime.autoCombatHandle(g,'approve',{})
    Runtime.autoCombatHandle(g,'activate',{})
    Runtime.setAutoCombatExecution(g,true)
    local started=Runtime.autoCombatHandle(g,'start',{})
    check(started.ok,'the auto-combat run starts')
    -- The pump only drives the controller after a native tick boundary.
    ready()
    -- Pump a frame: the run requests one native invocation. A native body that
    -- suspends itself yields `native_pending`; the controller transitions to
    -- `waiting_native` because the invocation is unresolved.
    local ok_pump=pcall(Runtime.onFrame,g)
    check(ok_pump,'the pump does not raise on a stalled native invocation')
    local ac_status=Runtime.autoCombatStatus(g)
    check(ac_status.run and (ac_status.run.state=='waiting_native'
        or ac_status.run.state=='settling' or ac_status.run.state=='running'),
        'the controller is live while the native call is pending')
    -- The invocation is stalled; no additional native request is submitted.
    local before_attempts=ac_status.run.attempts
    for i=1,5 do pcall(Runtime.onFrame,g) end
    ac_status=Runtime.autoCombatStatus(g)
    check(ac_status.run.attempts==before_attempts,'a pending invocation is never resubmitted')
    check(observe().phase=='settling',
        'the unanswerable native request stalls the session in settling')
    -- P0: the auto request is surfaced with the manual slot's interaction shape
    -- so a caller can answer it before the bounded abort fires.
    local pending=observe().auto_combat.pending_interaction
    check(pending and pending.kind=='dialog.confirm',
        'an auto-slot native request is surfaced as an answerable interaction')
    -- Exceed the frame bound: the executor aborts typed. Stop pumping the moment
    -- the abort appears so the stopped run is still observable.
    local after
    for i=1,Runtime.AUTO_NATIVE_TIMEOUT_FRAMES+5 do
        pcall(Runtime.onFrame,g)
        -- `settle` is the frame's invocation-completion step; pump it too so a
        -- native body that finishes synchronously is reaped before the bound.
        pcall(ready)
        after=observe().auto_combat
        -- `Json.null` is a truthy sentinel; test the typed code explicitly.
        if after.last_native_abort and after.last_native_abort.code then break end
    end
    check(after.last_native_abort and after.last_native_abort.code=='native_timeout',
        'the stalled invocation is aborted with a typed native_timeout')
    check(after.last_native_abort.action=='use_talent' and after.last_native_abort.talent=='T_RUSH',
        'the abort event carries the action, talent and target')
    check((after.last_native_abort.elapsed_frames or 0)>0
        and ((after.last_native_abort.elapsed_frames or 0)>=Runtime.AUTO_NATIVE_TIMEOUT_FRAMES
            or (after.last_native_abort.elapsed_ticks or 0)>=Runtime.AUTO_NATIVE_TIMEOUT_TICKS),
        'the abort event carries the elapsed ticks/frames that hit the bound')
    check(after.state=='stopped' and after.last_decisions~=nil,
        'the aborted run is stopped and the decision ring is available')
    local policy_status=Runtime.autoCombatStatus(g)
    check(policy_status.control_owner=='manual',
        'the abort hands control back to the player (F1: lease released)')
    -- The controller was released by the abort; the typed event is the durable
    -- record (the service log), and the terminal state is observable through it.
    local events=Runtime.autoCombatHandle(g,'log',{limit=16}).events
    local aborted=false
    for _,e in ipairs(events or {}) do if e.kind=='native_aborted' and e.reason=='native_timeout' then aborted=true end end
    check(aborted,'the abort is recorded as a typed policy-log event (F4)')
    -- Control is restored: the session is usable for a remote action again.
    reconnect()
    check(Runtime.autoCombatStatus(g).control_owner=='manual',
        'the abort releases the auto-combat lease (F1)')
    g.dialogs={}
    check(observe().phase=='ready',
        'control is restored to a ready session after the auto-combat native abort')
    ActionsMod.execute=realExecute
    Runtime.setAutoCombatExecution(g,false)
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
end
-- S2 production path: the live auto-combat host lowers a multi-prompt plan into
-- the executor's ordered queue. A test-only fixture talent raises the exact
-- actor-then-grid prompts; the real `Actions.execute` queue answers each with
-- its own decided value in one submission and records the observed sequence.
do
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
    Runtime.reset(g);g:display()
    local Tracker=require 'mod.mcp_bridge.InvocationTracker'
    local Compat=require 'mod.mcp_bridge.NativeCompatibility'
    local ActionsMod=require 'mod.mcp_bridge.Actions'
    local realMatches,realCheck=Compat.matches,Compat.check
    Compat.matches=function(name,fn) if name=='useTalent' then return true end return realMatches(name,fn) end
    Compat.check=function() return true end
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    -- The fixture defines a talent whose action calls getTarget twice, in order.
    local seen={}
    p.talents={T_SEQ_FIXTURE=1}
    p.talents_def=p.talents_def or {}
    p.talents_def.T_SEQ_FIXTURE={id='T_SEQ_FIXTURE',mode='activated',
        action=function(self)
            local a,b=self:getTarget({type='hit',range=10,nowarning=true})
            seen[#seen+1]={a,b}
            local c,d=self:getTarget({type='ball',range=14,radius=1,nowarning=true})
            seen[#seen+1]={c,d}
            return (a and c) and true or nil
        end}
    function p:useTalent(id) return self.talents_def[id].action(self) end
    -- The native `Player:getTarget` seam the queue wrapper replaces.
    function p:getTarget() return 99,99,nil end
    -- A fixture movement adapter declaring the ordered program, installed for the
    -- probe talent only (the manifest is static production data).
    local Factory=require 'mod.auto_combat.MovementAdapterFactory'
    local movement=assert(Factory.expand('request_then_landing',{
        request_sequence={{index=1,request='actor',subject='self',
                observed={cursor_type='hit',nowarning=true}},
            {index=2,request='grid',subject='self',value_source='target_plan',landing_from='envelope',
                observed={cursor_type='ball',nowarning=true}}},
        delivery='teleport',landing='random',center='requested_grid',traverses=false,
        relocates_other=false,radius=1,min_radius=0,range=10}))
    local Manifest=require 'mod.auto_combat.EffectManifest'
    local saved_entry=Manifest.ENTRIES.T_SEQ_FIXTURE
    Manifest.ENTRIES.T_SEQ_FIXTURE={kind='movement',target='self',resource='mana',
        movement=movement,components={},conformance={builder=false}}
    p.attr=engineFn('/engine/Entity.lua','return function(self,id) return self[id] end')
    p.x,p.y=2,2
    p.phase_door_force_precise=nil
    local pl={schema='tome-auto-combat/v1',id='seq',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,max_selffire_risk=0},targeting={default='self'},
        rules={{id='door',priority=1,when={always={}},['then']={action='use_talent',
            talent='T_SEQ_FIXTURE',target='self',
            target_plan={{request='actor',selector='self'},
                {request='grid',destination={selector='position',x=3,y=2,accept=accept}}}}}}}
    local host=Runtime.buildAutoCombatHostFor(g,pl,{drift=function() return true end})
    local planned,planErr=host.plan({action='use_talent',talent='T_SEQ_FIXTURE',target='self',
        target_plan=pl.rules[1]['then'].target_plan,
        destination=pl.rules[1]['then'].target_plan[2].destination})
    check(planned and planned.plan and planned.plan.kind=='sequence' and planErr==nil,
        'the live host plans the ordered prompt-sequence lowering')
    local outcome=host.request({action='use_talent',talent='T_SEQ_FIXTURE',plan=planned.plan,rule='door'})
    check(outcome.status=='ok','the live host executes the ordered queue in one native submission')
    check(seen[1] and seen[1][1]==2 and seen[1][2]==2,
        'the actor prompt is answered with the caster cell')
    check(seen[2] and seen[2][1]==3 and seen[2][2]==2,
        'the landing prompt is answered with its own distinct decided coordinate')
    check(type(outcome.target_sequence)=='table' and #outcome.target_sequence==2,
        'the observed prompt sequence reaches the controller outcome')
    check(outcome.reduced==nil,'a fully answered sequence is not reduced')
    -- Checklist A: the executor re-checks the planner-produced carrier dense+
    -- closed. A malformed carrier must never be answered as a shorter queue; the
    -- ordinary typed failure is `sequence_unavailable` (the executor's own
    -- `Json.denseArray` guard) or `invalid_sequence` (normalizeSequence), never a
    -- silent one-entry queue.
    local sparseCarrier=host.request({action='use_talent',talent='T_SEQ_FIXTURE',
        plan={kind='sequence',values={[1]={kind='self',request='actor',observed={cursor_type='hit',nowarning=true}},
            [3]={kind='grid',request='grid',x=3,y=2,observed={cursor_type='ball',nowarning=true}}}},
        rule='door'})
    check(sparseCarrier.status=='rejected'
        and (sparseCarrier.code=='sequence_unavailable' or sparseCarrier.code=='invalid_sequence'),
        'a sparse internal carrier is rejected, never executed as a shorter queue')
    -- The same dense guard applied directly to the executor's carrier read: a
    -- sparse `action.sequence` yields queueCount==0 (no truncation).
    local JsonMod=require 'mod.mcp_bridge.Json'
    local dense,count=JsonMod.denseArray({[1]='a',[3]='c'},1)
    check(dense==false and count=='hole','the executor carrier check rejects a sparse list')
    Manifest.ENTRIES.T_SEQ_FIXTURE=saved_entry
    Compat.matches,Compat.check=realMatches,realCheck
    Runtime.reset(g);g:display()
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
end

-- S2 rev3/§6.2 handback wiring: outcome mapping survival, reap exactly-once, and
-- the live-handle-first bounded abort. These call the real production seams.
do
    local Interactions=require 'mod.mcp_bridge.Interactions'
    local Service=require 'mod.auto_combat.AutoCombatService'
    -- (a) A real-shaped native_pending result carrying the queue deviation and
    -- `handed_back` survives mapAutoCombatOutcome (no field is swallowed).
    local mapped=Runtime.mapAutoCombatOutcome({ok=true,code='native_pending',energy_spent=0,
        target_sequence={{shape='ball'}},
        sequence_deviation={reason='unexpected_target_request',handed_back=true,
            expected={index=1,request='actor'},observed_shape='ball',skippable=false},
        handed_back=true},'use_talent',nil)
    check(mapped.status=='native_pending'
        and mapped.sequence_deviation and mapped.sequence_deviation.reason=='unexpected_target_request'
        and mapped.sequence_deviation.handed_back==true
        and mapped.handed_back==true and mapped.target_sequence[1].shape=='ball',
        'a native_pending result keeps its deviation/target_sequence (production mapping)')
    -- (b) reapAutoInvocation delivers an undelivered root deviation exactly once
    -- (Path 2), and a delivered one is not delivered twice.
    g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    Runtime.autoCombatHandle(g,'set_draft',{policy={schema='tome-auto-combat/v1',
        id='p2',name='unit',limits={max_actions_per_tick=1},safety={min_hp_pct=35},
        targeting={default='self'},
        rules={{id='w',priority=1,when={always={}},['then']={action='wait'}}}}})
    Runtime.autoCombatHandle(g,'approve',{})
    Runtime.autoCombatHandle(g,'activate',{})
    Runtime.setAutoCombatExecution(g,true)
    Runtime.autoCombatHandle(g,'start',{})
    local svc=Runtime.autoCombatService(g)
    local root={done=true,command={rule='seq'},
        sequence_deviation={reason='unexpected_target_request',handed_back=true,
            expected={index=1,request='actor'}}}
    Runtime.setAutoInvocationFor(g,root)
    Runtime.reapAutoInvocationFor(g)
    check(root.deviation_delivered==true,'the reap marks the root deviation delivered')
    check(svc.arbiter.owner=='manual' and svc.controller.state=='stopped'
        and svc.controller.reason=='unexpected_target_request',
        'the reap delivers the deviation: run stopped + lease released (Path 2)')
    -- Exactly once: a second reap is a no-op (the root is already released).
    Runtime.reapAutoInvocationFor(g)
    check(Runtime.autoInvocationFor(g)==nil,'the root is released after the reap')
    local delivered=0
    for _,event in ipairs(svc.log.entries or {}) do
        if event.kind=='paused' and event.reason=='unexpected_target_request' then delivered=delivered+1 end
    end
    check(delivered==1,'the settle-time deviation is delivered exactly once')
    -- A deviation already delivered inside the step is NOT re-delivered.
    Runtime.autoCombatHandle(g,'start',{})
    local svc2=Runtime.autoCombatService(g)
    svc2.arbiter.owner='auto_combat'
    local root2={done=true,command={},
        sequence_deviation={reason='movement_request_kind_unknown',handed_back=true},
        deviation_delivered=true}
    Runtime.setAutoInvocationFor(g,root2)
    Runtime.reapAutoInvocationFor(g)
    local redelivered=false
    for _,event in ipairs(svc2.log.entries or {}) do
        if event.kind=='paused' and event.reason=='movement_request_kind_unknown' then redelivered=true end
    end
    check(redelivered==false,'an already-delivered deviation is not delivered a second time')
    -- (c) The bounded abort is live-handle-first: with a live target handle and a
    -- handed-back marker (no target_cancelled) it cancels the handle (not the
    -- authoritative fast path).
    Runtime.autoCombatHandle(g,'start',{})
    local svc3=Runtime.autoCombatService(g)
    local Compat=require 'mod.mcp_bridge.NativeCompatibility'
    local liveRoot={command={rule='seq',target_handed_back='unexpected_target_request',
            interactions={},interaction_sequence=0},player=p,level=g.level,game=g}
    -- Register a bridge-side target handle through the real constructor path.
    local realTarget,realTargetCo,realTargetMode=g.target,g.target_co,g.targetMode
    g.target={active=true,setSpot=function() end,target={}};g.target_co=coroutine.create(function() end)
    g.targetMode=function() return 'target' end
    local realOpen=Interactions.openTarget
    -- Build the handle the way the native seam does (Tracker.current must be the
    -- root): run inside the tracker scope so openTarget registers it.
    local Tracker=require 'mod.mcp_bridge.InvocationTracker'
    local opened
    Tracker.reset()
    Tracker.scope({root=liveRoot},function()
        Interactions.openTarget(g,{type='hit',range=10})
    end)
    local h=Interactions.current(liveRoot)
    check(h~=nil and h.target~=nil and h.kind=='target.grid','the production seam registers a live target handle')
    liveRoot.done=true
    Runtime.setAutoInvocationFor(g,liveRoot)
    Runtime.abortAutoInvocationFor(g,{tick=0,ms=0,frames=0},{ticks=Runtime.AUTO_NATIVE_TIMEOUT_TICKS,
        ms=0,frames=Runtime.AUTO_NATIVE_TIMEOUT_FRAMES})
    check(Runtime.autoInvocationFor(g)==nil,'the abort releases the live auto invocation')
    local abortRecord=Runtime.lastNativeAbort(g)
    check(abortRecord and abortRecord.cancelled==true
        and abortRecord.reason=='handed_back_timeout',
        'the bounded abort cancels the LIVE target handle first (not the authoritative fast path)')
    -- (d) Regression: a target_cancelled marker with NO live handle keeps the
    -- authoritative fast path (the abort does not fabricate a live handle).
    Runtime.autoCombatHandle(g,'start',{})
    local deadRoot={done=true,command={rule='seq',target_cancelled='target_out_of_range',
            interactions={},interaction_sequence=0},
        player=p,level=g.level,game=g}
    Runtime.setAutoInvocationFor(g,deadRoot)
    Runtime.abortAutoInvocationFor(g,{tick=0,ms=0,frames=0},{ticks=Runtime.AUTO_NATIVE_TIMEOUT_TICKS,
        ms=0,frames=Runtime.AUTO_NATIVE_TIMEOUT_FRAMES})
    check(Runtime.autoInvocationFor(g)==nil,'a cancelled-marker root with no live handle still aborts')
    local deadRecord=Runtime.lastNativeAbort(g)
    check(deadRecord and deadRecord.reason=='authoritative_target_cancelled',
        'a target_cancelled root with no live handle keeps the authoritative fast path')
    g.target,g.target_co,g.targetMode=realTarget,realTargetCo,realTargetMode
    Interactions.openTarget=realOpen
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
end

-- S2 rev3/§6.2: after the lease is released, the caller answers the handed-back
-- auto invocation's current handle through the ordinary respond/dismiss routing.
-- While the run is live (arbiter still owns auto-combat) the auto handle is NOT
-- a caller target, so the routing grants nothing.
do
    local Interactions=require 'mod.mcp_bridge.Interactions'
    local Tracker=require 'mod.mcp_bridge.InvocationTracker'
    g,p,enemy,hello,request,observe,act,status,ready,reconnect=fixture()
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=true
    Runtime.autoCombatHandle(g,'set_draft',{policy={schema='tome-auto-combat/v1',
        id='p3',name='unit',limits={max_actions_per_tick=1},safety={min_hp_pct=35},
        targeting={default='self'},
        rules={{id='w',priority=1,when={always={}},['then']={action='wait'}}}}})
    Runtime.autoCombatHandle(g,'approve',{})
    Runtime.autoCombatHandle(g,'activate',{})
    Runtime.setAutoCombatExecution(g,true)
    Runtime.autoCombatHandle(g,'start',{})
    local svc=Runtime.autoCombatService(g)
    -- Install a live target handle on the auto invocation.
    local realTarget,realTargetCo,realTargetMode=g.target,g.target_co,g.targetMode
    g.target={active=true,setSpot=function() end,target={}};g.target_co=coroutine.create(function() end)
    g.targetMode=function() return 'target' end
    local autoRoot={command={rule='seq',interactions={},responses={},response_count=0,
        consumed_interactions={},interaction_sequence=0},
        player=p,level=g.level,game=g}
    Tracker.reset()
    Tracker.scope({root=autoRoot},function() Interactions.openTarget(g,{type='hit',range=10}) end)
    local h=Interactions.current(autoRoot)
    check(h~=nil,'the auto invocation has a live target handle')
    Runtime.setAutoInvocationFor(g,autoRoot)
    local revision=observe().revision
    -- (i) While the lease is held, respond to the auto handle is refused (the
    -- run would answer it itself; the caller is granted nothing).
    local held=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=h.interaction_id,response_id='r-held',
        expected_revision=revision,answer={type='cancel'}})
    check(held.error~=nil,'a respond to the auto handle while the lease is held is refused')
    -- (ii) Release the lease (the safety-pause stop) and dismiss the handed-back
    -- prompt through the auto invocation's handle.
    svc.arbiter.owner='manual'
    svc.controller:stop('unexpected_target_request')
    local dismissed=request('dismiss',{session_id=hello.session_id,control_token=hello.control_token,
        interaction_id=h.interaction_id,expected_revision=observe().revision,answer={type='cancel'}})
    check(dismissed.result and dismissed.result.dismissed==true,
        'after the lease is released the handed-back auto prompt is dismissable via the auto handle')
    -- (iii) respond routes to the auto handle too (a live position answer).
    -- Reinstall a fresh live handle for the respond path.
    Tracker.reset()
    Tracker.scope({root=autoRoot},function() Interactions.openTarget(g,{type='hit',range=10}) end)
    local h2=Interactions.current(autoRoot)
    local answered_interaction_id=h2.interaction_id
    -- The fingerprint covers `expected_revision`; capture it so the replay
    -- carries exactly the same request as the first answer.
    local answered_revision=observe().revision
    local answered=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=h2.interaction_id,response_id='r-auto',
        expected_revision=answered_revision,answer={type='position',x=3,y=2}})
    check(answered.result and answered.result.answered==true and answered.result.scope=='auto_combat',
        'respond answers the handed-back auto prompt via the auto handle after lease release')
    -- S2-R3-02: the auto route preserves the same response-fingerprint and
    -- response-budget guards as the command-scoped route.
    check(autoRoot.command.responses and autoRoot.command.responses['r-auto']
        and autoRoot.command.responses['r-auto'].fingerprint~=nil
        and autoRoot.command.response_count==1,
        'an auto-handback answer records its response fingerprint and is counted')
    -- (iv) Reused response_id on a fresh (reissued) interaction is
    -- response_conflict, never silently accepted (classified before any
    -- consumed/ownership check).
    local reissued=Interactions.current(autoRoot)
    check(reissued~=nil and reissued.interaction_id~=answered_interaction_id,
        'an applied auto answer reissues the live handle with a fresh interaction id')
    local conflict=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=reissued.interaction_id,response_id='r-auto',
        expected_revision=observe().revision,answer={type='position',x=3,y=2}})
    check(conflict.error~=nil and conflict.error.code=='response_conflict',
        'a reused auto response_id on a fresh interaction is response_conflict')
    check(autoRoot.command.response_count==1 and reissued.consumed~=true,
        'a conflicting auto response is classified before any consumed state is touched')
    -- (iv-b) S2-R4-02: an EXACT replay of the SUCCESSFUL auto-handback response
    -- is idempotently replayable even though the successful apply reissued a
    -- fresh interaction id. The retained receipt is consulted BEFORE the request
    -- is required to name the current handle, so the old interaction id still
    -- returns the recorded success (and is not counted or reapplied again).
    local replay=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=answered_interaction_id,response_id='r-auto',
        expected_revision=answered_revision,answer={type='position',x=3,y=2}})
    check(replay.result and replay.result.answered==true and replay.result.scope=='auto_combat',
        'an exact replay of a successful auto response returns the recorded idempotent success')
    check(replay.result.interaction_id==answered_interaction_id,
        'the idempotent success echoes the answered interaction id')
    check(autoRoot.command.response_count==1,
        'a successful-response replay is not counted again')
    -- A replay that keeps the response_id but changes the answer is still a
    -- conflict (the fingerprint covers the answer), never a silent reapply.
    local replayConflict=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=answered_interaction_id,response_id='r-auto',
        expected_revision=answered_revision,answer={type='position',x=9,y=9}})
    check(replayConflict.error~=nil and replayConflict.error.code=='response_conflict',
        'a successful receipt with a different answer is still response_conflict')
    check(autoRoot.command.response_count==1,
        'a conflicting successful replay is not counted again')
    -- (v) Idempotent replay: when the first apply FAILED, the retry of the same
    -- response (same id/answer/revision, same live interaction) is answered
    -- idempotently and is not counted again.
    g.target.setSpot=function() error('boom') end
    Tracker.reset()
    Tracker.scope({root=autoRoot},function() Interactions.openTarget(g,{type='hit',range=10}) end)
    local h5=Interactions.current(autoRoot)
    local failed_revision=observe().revision
    local failed=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=h5.interaction_id,response_id='r-fail',
        expected_revision=failed_revision,answer={type='position',x=4,y=3}})
    check(failed.error~=nil and failed.error.code=='dismiss_error',
        'a failed auto answer surfaces the existing native-error code and keeps the receipt')
    check(autoRoot.command.response_count==2
        and autoRoot.command.responses['r-fail'].fingerprint~=nil,
        'a failed auto answer is still fingerprinted and counted')
    g.target.setSpot=function() end
    local retried=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=h5.interaction_id,response_id='r-fail',
        expected_revision=failed_revision,answer={type='position',x=4,y=3}})
    check(retried.result and retried.result.answered==true and retried.result.scope=='auto_combat'
        and autoRoot.command.response_count==2,
        'a retried auto response_id after a failed apply is an idempotent replay, not a new answer')
    -- (vi) The response budget applies unchanged: at the bound a fresh response
    -- on a fresh handed-back prompt is refused.
    Tracker.reset()
    Tracker.scope({root=autoRoot},function() Interactions.openTarget(g,{type='hit',range=10}) end)
    local h4=Interactions.current(autoRoot)
    autoRoot.command.response_count=Interactions.MAX_RESPONSES
    local overBudget=request('respond',{session_id=hello.session_id,control_token=hello.control_token,
        command_id='cmd-999999',interaction_id=h4.interaction_id,response_id='r-budget',
        expected_revision=observe().revision,answer={type='position',x=4,y=2}})
    check(overBudget.error~=nil and overBudget.error.code=='response_budget_exhausted',
        'the auto-handback response budget enforces Interactions.MAX_RESPONSES')
    check(autoRoot.command.response_count==Interactions.MAX_RESPONSES
        and autoRoot.command.responses['r-budget']==nil and h4.consumed~=true,
        'a budget-exhausted auto response is not recorded or applied')
    g.target,g.target_co,g.targetMode=realTarget,realTargetCo,realTargetMode
    config.settings.tome_mcp_bridge.allow_auto_combat_execution=false
    Runtime.reset(g);g:display()
end
print('Runtime: '..count..' checks passed')
