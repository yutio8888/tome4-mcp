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
check(#observe().actors==0,'modified perception disables fallback')
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
    local pl={schema='tome-auto-combat/v1',id='p1',name='unit',limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},
        rules={{id='attack',priority=1,when={always={}},['then']={action='attack',target='nearest_hostile'}}}}
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
    local pausable=soft.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})
    check(pausable and pausable.action=='pause' and pausable.reason=='selffire_risk',
        'max_selffire_risk>0 pauses on the same risk')
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
    -- V2-REV-02: without live hash services the adapter is disabled, not
    -- silently trusted. This host uses the real (absent) fs/md5 path.
    local undrifted=Runtime.buildAutoCombatHostFor(g,pl)
    local disabled=undrifted.guard({action='use_talent',talent='T_MOONLIGHT_RAY',bound_target=target})
    check(disabled and disabled.reason=='adapter_source_drift',
        'missing live hash services reject with adapter_source_drift')
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
-- DYN-REV-01 (Runtime path): an overridden/unverifiable spellFriendlyFire makes
-- the audited dynamic input unknown; a raw builder selffire=0 must not turn that
-- into a permissive verdict.
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
    p.spellFriendlyFire=function() return 0 end
    local live=Runtime.buildAutoCombatHostFor(g,pl,{drift=function() return true end})
    local target=live.snapshot('nearest_hostile').bound_target
    local verdict=live.guard({action='use_talent',talent='T_FIREFLASH',bound_target=target})
    check(verdict and verdict.reason=='selffire_risk',
        'an overridden spellFriendlyFire fails closed even when the builder returns 0')
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
print('Runtime: '..count..' checks passed')
