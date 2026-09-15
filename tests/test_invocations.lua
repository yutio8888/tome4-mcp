local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local count=0
local function check(value,message) count=count+1;assert(value,message) end
local player={}
local game={player=player,level={}}
local events={}
local function reset() Tracker.reset(function(r) events[#events+1]={done=r.done,pending=r.pending,error=r.error} end) end
reset()
local body,after_first,after_second,post
local function invoke(p,id)
    return Tracker.call(p,id,function()
        body=Tracker.createBody(function()
            local one=coroutine.yield('first')
            after_first=one
            local two=coroutine.yield('second')
            after_second=two
            post=true
            return one=='a' and two=='b'
        end)
        assert(coroutine.resume(body))
    end)
end
local command={command_id='two'}
local owned=Tracker.start(game,command,function() return invoke(player,'T_EXAMPLE') end)
check(not owned.done and owned.pending==1,'first useTalent return must retain the suspended body')
check(Tracker.current()==nil,'starting scope does not leak onto main thread')
check(Tracker.forCoroutine(body).root==owned,'suspended native coroutine retains invocation ownership')
check(not post and not after_first,'no code past first yield ran early')
check(coroutine.resume(body,'a'),'native callback resumes first input')
check(after_first=='a' and not after_second and not owned.done,'second yield keeps same invocation pending')
check(coroutine.resume(body,'b'),'native callback resumes second input')
check(owned.done and owned.pending==0 and owned.native_return==true and post,'completion includes code after final input')
check(Tracker.forCoroutine(body)==nil,'finished coroutine ownership is removed')
Tracker.release(owned)
check(owned.player==nil and owned.game==nil and owned.command==nil,'release drops game references')

reset()
local rejected=Tracker.start(game,{command_id='cooldown'},function()
    return Tracker.call(player,'T_COOLDOWN',function() return false end)
end)
check(rejected.done and rejected.native_return==false and not rejected.error,'pre-body cooldown rejection is a known result')

reset()
local error_body
local partial={value=0}
local broken=Tracker.start(game,{command_id='error'},function()
    return Tracker.call(player,'T_ASYNC_ERROR',function()
        error_body=Tracker.createBody(function()
            coroutine.yield()
            partial.value=7
            error('after-resume-sentinel')
        end)
        assert(coroutine.resume(error_body))
    end)
end)
check(not broken.done and not broken.error,'yield is not an error')
local ok,err=coroutine.resume(error_body)
check(not ok and tostring(err):find('after-resume-sentinel',1,true),'native resume still receives the original error')
check(broken.done and broken.error:find('after-resume-sentinel',1,true),'late coroutine error is tracked even if caller ignores resume result')
check(partial.value==7,'tracking does not pretend to undo partial mutation')
check(Tracker.current()==nil and Tracker.forCoroutine(error_body)==nil,'errors clean scope bindings')

reset()
local outer,child
local nested=Tracker.start(game,{command_id='nested'},function()
    return Tracker.call(player,'T_OUTER',function()
        outer=Tracker.createBody(function()
            Tracker.call(player,'T_CHILD',function()
                child=Tracker.createBody(function() coroutine.yield();return true end)
                assert(coroutine.resume(child))
            end)
            return true
        end)
        assert(coroutine.resume(outer))
    end)
end)
check(nested.primary.done and not nested.done and nested.pending==1,'outer return cannot abandon a suspended child invocation')
check(coroutine.resume(child) and nested.done and nested.pending==0,'last child completion releases root lifecycle')
check(Tracker.current()==nil,'nested invocation restores previous context')

reset()
local sentinel={root={}}
local ok=pcall(Tracker.scope,sentinel,function() error('scope failure') end)
check(not ok and Tracker.current()==nil,'scope cleanup runs when native callback raises')
check(sentinel.root.error:find('scope failure',1,true),'callback scope preserves failure on root')

reset()
local callback
local entry=Tracker.startAction(game,{command_id='ordinary'},function()
    callback=Tracker.callback(game,function() return Tracker.current().root end)
    return false
end)
check(entry.done and entry.pending==0 and not entry.error and not entry.result_from_talent,
    'ordinary action lifetime completes without inventing a talent result')
check(callback()==entry and Tracker.current()==nil,'deferred native callback restores its causal command scope')
Tracker.release(entry)
local stale=Tracker.callback(game,function() return Tracker.current() end)
check(stale()==nil,'unowned native callbacks never acquire an active command')

reset()
local item_body
local item_root=Tracker.startAction(game,{command_id='item'},function()
    return Tracker.call(player,false,function()
        item_body=Tracker.createBody(function()
            coroutine.yield()
            Tracker.itemResult(player,{used=true,destroy=true})
            -- Native Player returns nil for many successful item uses.
        end)
        assert(coroutine.resume(item_body))
        return true
    end)
end)
check(not item_root.done and item_root.pending==1,'item body remains owned across native yield')
check(coroutine.resume(item_body) and item_root.done and item_root.native_return,
    'item success comes from native used result including subsequent cleanup')

reset()
local old_level=game.level
local old_callback,new_callback
local transitioned=Tracker.startAction(game,{command_id='scene'},function()
    old_callback=Tracker.callback(game,function() return Tracker.current() end)
    game.level={}
    new_callback=Tracker.callback(game,function() return Tracker.current() end)
end)
transitioned.level=game.level
check(old_callback()==nil,'old-level callback cannot inherit rebased invocation ownership')
check(new_callback()==transitioned,'new-level callback retains same invocation after owned scene change')
Tracker.release(transitioned)
check(new_callback()==nil,'released scene invocation cannot be revived by deferred callback')
game.level=old_level

print('Invocations: '..count..' checks passed')
