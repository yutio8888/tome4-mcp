-- NativeActivity: the generic multi-turn activity registry (P1b).
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local NativeActivity=require 'mod.mcp_bridge.NativeActivity'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function nativeAt(src,body) return assert(loadstring('return '..body,src))() end
local function session()
    local p={energy={value=1000},x=1,y=1}
    local g={player=p,level={entities={}},turn=1}
    return {game=g,native_activity=nil,control_token='tok',revision=1,
        auto_combat={arbiter={owner='auto_combat'}}},g,p
end
local function restPlayer(p)
    p.restInit=nativeAt('@/engine/interface/PlayerRest.lua','function(self) self.resting={cnt=1} end')
    p.restStop=nativeAt('@/engine/interface/PlayerRest.lua','function(self,reason) self.resting=nil end')
end
local function explorePlayer(p)
    p.autoExplore=nativeAt('@/mod/class/interface/PlayerExplore.lua',
        'function(self) self.running={explore="unseen",cnt=0} return true end')
    p.runStep=nativeAt('@/engine/interface/PlayerRun.lua',
        'function(self) self.running.cnt=self.running.cnt+1 return self.running.cnt<3 end')
    p.enoughEnergy=nativeAt('@/engine/Actor.lua','function(self) return true end')
    p.runStop=nativeAt('@/engine/interface/PlayerRun.lua','function(self,reason) self.running=nil end')
end

-- rest -----------------------------------------------------------------------
do
    local s,g,p=session();restPlayer(p)
    local activity={owner='command',command={input_owner='remote'}}
    check(NativeActivity.is('rest') and NativeActivity.is('auto_explore') and not NativeActivity.is('wait'),
        'only native activities are recognised')
    local result=NativeActivity.start(s,activity,'rest',{max_turns=3})
    check(result.ok and activity.native_rest==p.resting and NativeActivity.live(activity,p),
        'rest starts and is registered on the session')
    check(s.native_activity==activity and NativeActivity.holds(s,activity),
        'a command-owned rest holds the lease')
    -- The rest popup is only claimed while restInit is running.
    s.starting_rest=true
    local dialog={}
    check(NativeActivity.ownsDialog(s,activity,dialog,true)=='owned' and activity.rest_dialog==dialog,
        'the rest dialog is claimed while starting')
    check(NativeActivity.ownsDialog(s,activity,dialog,false)=='owned','a known rest dialog stays owned')
    s.starting_rest=false
    -- Per-step budget and lease checks.
    p.resting.cnt=2
    check(NativeActivity.beforeStep(s,p)==true,'a rest under max_turns keeps stepping')
    p.resting.cnt=3
    check(NativeActivity.beforeStep(s,p)==false and p.resting==nil,
        'reaching max_turns stops the rest')
    check(activity.stop_reason=='max_turns','the stop reason is recorded')
    -- Explicit stop.
    local again={owner='command',command={input_owner='remote'}}
    NativeActivity.start(s,again,'rest',{max_turns=10})
    NativeActivity.stop(s,again,'manual')
    check(p.resting==nil and again.stop_reason=='manual','an explicit stop invokes the native restStop')
end
do
    -- A control change stops a command-owned rest and quarantines the lease.
    local s,g,p=session();restPlayer(p)
    s.control_token=nil
    local activity={owner='command',command={input_owner='remote'}}
    NativeActivity.start(s,activity,'rest',{max_turns=10})
    check(NativeActivity.beforeStep(s,p)==false and p.resting==nil,
        'a lost lease stops the rest instead of stepping it')
end

-- auto_explore ---------------------------------------------------------------
do
    local s,g,p=session()
    local refusal=NativeActivity.start(s,{owner='command',command={input_owner='remote'}},'auto_explore')
    check(refusal.ok==false and refusal.code=='auto_explore_unavailable',
        'auto_explore refuses non-native entrypoints')
    explorePlayer(p)
    local activity={owner='command',command={input_owner='remote'}}
    local result=NativeActivity.start(s,activity,'auto_explore')
    check(result.ok and result.code=='exploring' and activity.native_run==p.running,
        'auto_explore starts the native run')
    check(NativeActivity.live(activity,p),'the run is live')
    NativeActivity.stop(s,activity,'interaction')
    check(p.running==nil,'stopping the run invokes the native runStop')
    check(NativeActivity.reap(s)==nil,'a command-owned activity is not reaped by the module')
end
do
    -- Auto-combat ownership: reap clears a finished activity, and a stop failure
    -- does not touch the remote lease.
    local s,g,p=session();explorePlayer(p)
    s.control_token=nil
    local activity={owner='auto_combat'}
    NativeActivity.start(s,activity,'auto_explore')
    check(s.native_activity==activity and NativeActivity.holds(s,activity),
        'an auto-combat run holds the auto lease')
    p.running=nil
    NativeActivity.reap(s)
    check(s.native_activity==nil,'a finished auto-combat activity is reaped')
end

print('Native activity: '..checks..' checks passed')
