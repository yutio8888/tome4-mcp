-- S3 native-trace observer MECHANICS (offline regression, TRACE-02/TRACE-04).
-- These are controlled-function unit tests of the observer's pass-through,
-- arity, restoration, error and yield semantics. They are NOT native Vault
-- evidence; the real native execution is owned by the coordinator's supplemental
-- session (see docs/tome-mcp-0.9.0-s3-evidence-harness.md).
--
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
package.path=root..'/tests/native/tome-s3-observer/overload/?.lua;'..package.path
local Trace=require 'mod.S3NativeTrace'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- TRACE-02 requires the native targeting flow's coroutine.yield() to pass
-- through the observer's pcall. That is a hard language capability: LuaJIT (the
-- VM the game actually runs, game/loader/pre-init.lua) yields across pcall,
-- while plain Lua 5.1 raises "attempt to yield across C-call boundary". The
-- observer cannot be CORRECT under a non-yieldable pcall, so this test refuses
-- to report a mechanics PASS there instead of silently skipping the case.
do
    local probe=coroutine.create(function()
        pcall(function() coroutine.yield('y') end)
        return true
    end)
    local ok,value=coroutine.resume(probe)
    assert(ok and value=='y' and coroutine.resume(probe),
        'this test requires a yieldable pcall (run it under LuaJIT; the game itself '
        ..'selects LuaJIT in game/loader/pre-init.lua)')
end

local function collector() local list={} return list end
local function observer(collect,writer)
    return Trace.newObserver({collect=collect,writer=writer or function() end})
end
-- A fresh actor whose current getTarget is `current` (the saved raw field is
-- the same value unless a test deliberately replaces it before wrapping).
local function actor(current)
    return {getTarget=current}
end

-- 1. Pass-through: identical arg identity, exact return arity, no substitution.
do
    local seen={}
    local typ={type='hit',range=3}
    local entity={uid=7}
    local current=function(self,t,...)
        seen.self,seen.typ,seen.rest=self,t,{n=select('#',...),...}
        return 12,34,entity
    end
    local a=actor(current,nil)
    local list=collector()
    local obs=observer(list)
    a.getTarget=Trace.observeGetter(obs,current,1,'T_VAULT',a)
    local x,y,e=a.getTarget(a,typ,'extra',false)
    check(seen.typ==typ,'the delegate passes the exact typ table identity')
    check(seen.rest.n==2 and seen.rest[1]=='extra' and seen.rest[2]==false,
        'the delegate passes identical varargs to the original getter')
    check(x==12 and y==34 and e==entity,'the delegate returns the original values unchanged')
    check(list[1].kind=='request' and list[2].kind=='answer',
        'one request then one answer record are emitted')
    check(list[1].request==1 and list[1].typ.type=='hit' and list[1].typ.range==3,
        'the real typ shape/range are recorded')
    check(list[2].answer.x==12 and list[2].answer.y==34 and list[2].answer.uid==7,
        'the real answered coordinates and returned actor UID are recorded')
end

-- 2. Multi-return arity: nil vs false are preserved distinctly, arity is exact.
do
    local cases={{{n=0},0},{{n=3,false,nil,nil},3},{{n=3,5,nil,nil},3},{{n=3,5,6,false},3}}
    for _,case in ipairs(cases) do
        local returns=case[1]
        local current=function() return unpack(returns,1,returns.n) end
        local list=collector()
        local obs=observer(list)
        local wrapped=Trace.observeGetter(obs,current,1,'T',actor(current,nil))
        local a={getTarget=wrapped}
        local r={n=select('#',a.getTarget(a,{type='hit'}))}
        check(r.n==case[2],'return arity is preserved exactly ('..case[2]..')')
        local answer=list[2].answer
        check(answer.arity==case[2],'the recorded answer arity matches')
        if case[2]==3 and returns[1]==false then
            check(answer.x==false and answer.x_class=='false','an explicit false answer is kept as false')
        end
    end
    -- nil is distinguishable from false in the record (absent coordinate).
    local list=collector()
    local obs=observer(list)
    local current=function() return nil end
    local wrapped=Trace.observeGetter(obs,current,1,'T',actor(current,nil))
    local a={getTarget=wrapped}
    a.getTarget(a,{type='hit'})
    check(list[2].answer.x==nil and list[2].answer.x_class=='nil','a nil answer stays nil, not false')
end

-- 3. nolock: absent vs explicit false vs true are distinguished.
do
    local function facts(typ)
        local list=collector()
        local obs=observer(list)
        local current=function() return 1,2 end
        Trace.observeGetter(obs,current,1,'T',actor(current,nil))(nil,typ)
        return list[1].typ
    end
    local absent=facts({type='hit',range=1})
    check(absent.present==true and absent.nolock_present==false and absent.nolock==nil,
        'an ABSENT nolock is reported as not present (no explicit false)')
    local explicitFalse=facts({type='hit',range=1,nolock=false})
    check(explicitFalse.nolock_present==true and explicitFalse.nolock==false,
        'an explicit nolock=false is reported as present and false')
    local explicitTrue=facts({type='hit',range=1,nolock=true})
    check(explicitTrue.nolock_present==true and explicitTrue.nolock==true,
        'an explicit nolock=true is reported as present and true')
    local nonTable=facts('hit')
    check(nonTable.present==false and nonTable.raw_type=='string','a non-table typ is reported honestly')
end

-- 4. wrapAction restores the saved raw field after success; the original action
--    is called exactly once and its real return arity passes through.
do
    local calls=0
    local current=function() calls=calls+1 return 9,8 end
    local a=actor(current)
    local list=collector()
    local obs=observer(list)
    local action=function(self,t)
        local x,y=self:getTarget({type='hit'})
        return x==9 and y==8 and 'ok' or 'bad', 3
    end
    local wrapped=Trace.wrapAction(obs,action,'T_VAULT')
    local r={wrapped(a,{})}
    check(r[1]=='ok' and r[2]==3 and #r==2,'the original action result and arity pass through')
    check(calls==1,'the real getter is called exactly once (no builder re-call)')
    check(rawget(a,'getTarget')==current,'the saved raw getTarget field is restored after success')
    check(list[1].kind=='invocation_start' and list[#list].kind=='invocation_finish',
        'invocation start/finish records bracket the action')
    check(list[#list].ok==true,'the finish record reports the real success')
end

-- 5. Restore on an original getTarget error: no fabricated answer, the ORIGINAL
--    error object is rethrown, and the saved field is restored.
do
    local sentinel={}
    local current=function() error(sentinel,0) end
    local a=actor(current)
    local list=collector()
    local obs=observer(list)
    local wrapped=Trace.wrapAction(obs,function(self) self:getTarget({type='hit'}) end,'T_VAULT')
    local ok,err=pcall(wrapped,a,{})
    check(not ok,'an erroring native getter surfaces as a failure')
    check(err==sentinel,'the original error object is rethrown unchanged')
    check(rawget(a,'getTarget')==current,'the saved getter is restored after a getter error')
    local requests,answers=0,0
    for _,record in ipairs(list) do
        if record.kind=='request' then requests=requests+1 end
        if record.kind=='answer' then answers=answers+1 end
    end
    check(requests==1 and answers==0,'the request is observed but no answer is fabricated when the getter errors')
end

-- 6. Restore on an original action error raised AFTER a successful getter.
do
    local current=function() return 1,1 end
    local a=actor(current,nil)
    local list=collector()
    local obs=observer(list)
    local wrapped=Trace.wrapAction(obs,function(self)
        self:getTarget({type='hit'})
        error('action exploded',0)
    end,'T_VAULT')
    local ok,err=pcall(wrapped,a,{})
    check(not ok and err=='action exploded','the original action error is rethrown')
    check(rawget(a,'getTarget')==current,'the saved getter field is restored after an action error')
    check(list[#list].kind=='invocation_finish' and list[#list].ok==false,
        'the finish record reports the real failure')
end

-- 7. Coroutine yield/resume: the real targeting flow yields out of the getter;
--    on resume the answer flows back to the action and the saved field is
--    restored only after the action completes.
do
    local seenAnswer
    local current=function(self,typ)
        local x,y,entity=coroutine.yield({requested=typ.type})
        seenAnswer={x,y,entity}
        return x,y,entity
    end
    local a=actor(current)
    local list=collector()
    local obs=observer(list)
    local action=function(self,t)
        local x,y,e=self:getTarget({type='hit',range=3})
        return x,y,e
    end
    local wrapped=Trace.wrapAction(obs,action,'T_VAULT')
    local co=coroutine.create(wrapped)
    local ok,yielded=coroutine.resume(co,a,{})
    check(ok and type(yielded)=='table' and yielded.requested=='hit',
        'a native yield passes through the observer (request recorded, no answer yet)')
    check(rawget(a,'getTarget')~=current,'the delegate is still installed while suspended')
    local answer={uid=11}
    local ok2,x,y,e=coroutine.resume(co,41,42,answer)
    check(ok2 and x==41 and y==42 and e==answer,'the resumed answer reaches the action unchanged')
    check(seenAnswer[1]==41 and seenAnswer[3]==answer,'the real getter received the resumed values')
    check(rawget(a,'getTarget')==current,'the saved getter is restored after the resumed action completes')
    check(coroutine.status(co)=='dead','the observed action coroutine completes')
    local answers=0
    for _,record in ipairs(list) do if record.kind=='answer' then answers=answers+1 end end
    check(answers==1,'exactly one answer record exists for the resumed request')
end

-- 8. Emitter failure isolation: a throwing sink never changes the game result,
--    is reported honestly, and never suppresses a native error.
do
    local current=function() return 5,6 end
    local a=actor(current,nil)
    local obs=Trace.newObserver({writer=function() error('sink down',0) end})
    local wrapped=Trace.wrapAction(obs,function(self)
        local x,y=self:getTarget({type='hit'})
        return x+y
    end,'T_VAULT')
    local ok,value=pcall(wrapped,a,{})
    check(ok and value==11,'a failing emitter does not alter the native result')
    check(obs.emit_failures==true,'the emission failure is reported honestly')
    -- The failure must not swallow a native error either.
    local obs2=Trace.newObserver({writer=function() error('sink down',0) end})
    local wrapped2=Trace.wrapAction(obs2,function() error('native boom',0) end,'T_VAULT')
    local ok2,err2=pcall(wrapped2,a,{})
    check(not ok2 and err2=='native boom','a failing emitter does not suppress a native error')
end

-- 9. Bounded records: overflow is flagged, never silently claimed as complete.
do
    local list=collector()
    local obs=Trace.newObserver({collect=list,writer=function() end,max_requests=1,max_records=1})
    local current=function() return 1,1 end
    local wrapped=Trace.observeGetter(obs,current,1,'T',actor(current,nil))
    local a={getTarget=wrapped}
    a.getTarget(a,{type='hit'})
    a.getTarget(a,{type='hit'})
    check(obs.requests==2,'every request is counted even past the bound')
    check(obs.truncated==true,'the truncation indicator is set honestly')
end

-- 9b. COORD-HARN-02: request ordinals and the finish count are PER INVOCATION.
--     Two invocations must each report request 1..n and their own finish count;
--     the prior invocation's requests are never conflated with the next.
do
    local current=function() return 1,1 end
    local a=actor(current)
    local list=collector()
    local obs=observer(list)
    local action=function(self)
        self:getTarget({type='hit'})
        self:getTarget({type='hit'})
        return true
    end
    local wrapped=Trace.wrapAction(obs,action,'T_VAULT')
    wrapped(a,{})
    wrapped(a,{})
    local ordinals,finishes={},{}
    for _,record in ipairs(list) do
        if record.kind=='request' then ordinals[#ordinals+1]=record.invocation..':'..record.request end
        if record.kind=='invocation_finish' then finishes[#finishes+1]=record.invocation..':'..record.requests end
    end
    check(table.concat(ordinals,',')=='1:1,1:2,2:1,2:2',
        'each invocation numbers its own requests from 1 (got '..table.concat(ordinals,',')..')')
    check(table.concat(finishes,',')=='1:2,2:2',
        'each invocation finish reports its OWN request count (got '..table.concat(finishes,',')..')')
    check(obs.requests==4,'the observer-level lifetime total is retained separately')
    check(list[#list].lifetime_requests==4,'the finish record exposes the separate lifetime total')
end

-- 10. install(): idempotent, and a missing Vault action is reported, not raised.
do
    package.loaded['engine.interface.ActorTalents']={talents_def={T_VAULT={action=function() end}}}
    Trace.installed=nil
    local first=Trace.install({writer=function() end,collect=collector()})
    check(first.installed==true,'install succeeds when the real Vault action exists')
    local def=package.loaded['engine.interface.ActorTalents'].talents_def.T_VAULT
    check(type(def.action)=='function','install replaces the action in place')
    local second=Trace.install()
    check(second==first,'install is idempotent (second call is a no-op)')
    package.loaded['engine.interface.ActorTalents']={talents_def={}}
    Trace.installed=nil
    local missing=Trace.install()
    check(missing.installed==false and missing.reason=='vault_action_unavailable',
        'a missing Vault action is reported as unavailable, never raised')
    Trace.installed=nil
end

-- 11. COORD-HARN-01: the installation line is a valid JSON trace record, the
--     frozen reader parses every `[S3NativeTrace]` occurrence as JSON.
do
    local lines={}
    local obs=Trace.newObserver({writer=function(line) lines[#lines+1]=line end})
    local ok=Trace.emitRecord(obs,{kind='installation',installed=true,reason=nil,observer='tome-s3-observer/v1'})
    check(ok==true,'the installation record emits successfully')
    local prefix=Trace.prefix..' '
    check(lines[1]:sub(1,#prefix)==prefix,'the installation line carries the trace prefix')
    local json=lines[1]:sub(#prefix+1)
    check(json:find('"kind":"installation"',1,true)~=nil,'the installation payload is JSON with its kind')
    check(json:find('"installed":true',1,true)~=nil,'the installation payload reports the real result')
    check(json:find('"reason"',1,true)==nil or json:find('"reason":null',1,true)
        or json:find('"reason":"',1,true)~=nil,'a nil reason is never an invalid token')
    -- Decode with the game's own strict JSON to prove the line is well formed.
    package.path=root..'/overload/?.lua;'..package.path
    local Json=require 'mod.mcp_bridge.Json'
    local parsed=Json.decode(json)
    check(parsed.kind=='installation' and parsed.installed==true,'the installation line round-trips through strict JSON')
end

-- 12. COORD-HARN-03: exact incoming arity is preserved for the getter. A call
--     with ONLY the actor must reach the current getter with arity 1 (not an
--     injected trailing nil), and the action must see the caller's arity.
do
    local seen={}
    local current=function(...) seen.n=select('#',...); seen.self=...; return 3,4 end
    local list=collector()
    local obs=observer(list)
    local wrapped=Trace.observeGetter(obs,current,1,'T_VAULT',actor(current),{requests=0})
    local a={getTarget=wrapped}
    wrapped(a)
    check(seen.n==1 and seen.self==a,'getTarget(actor) reaches the getter with arity 1')
    check(list[1].typ.present==false,'a missing typ is reported as absent, not invented')
    wrapped(a,{type='hit'})
    check(seen.n==2,'getTarget(actor, typ) reaches the getter with arity 2')
    -- Action-level arity: the original action sees exactly the caller's args.
    local actionN
    local wrappedAction=Trace.wrapAction(obs,function(...) actionN=select('#',...); return true end,'T_VAULT')
    wrappedAction(a)
    check(actionN==1,'wrapAction forwards one argument as arity 1')
    wrappedAction(a,{})
    check(actionN==2,'wrapAction forwards two arguments as arity 2')
    wrappedAction(a,{},nil)
    check(actionN==3,'wrapAction preserves a trailing explicit nil (arity 3)')
end

-- 13. COORD-HARN-04: an original error object with a throwing __tostring is
--     still rethrown as the SAME object; formatting it must not replace it.
do
    local current=function() return 1,1 end
    local a=actor(current)
    local list=collector()
    local obs=observer(list)
    local sentinel=setmetatable({}, {__tostring=function() error('bad __tostring',0) end})
    local wrapped=Trace.wrapAction(obs,function(self)
        self:getTarget({type='hit'})
        error(sentinel,0)
    end,'T_VAULT')
    local ok,err=pcall(wrapped,a,{})
    check(not ok,'the throwing-tostring error still surfaces as a failure')
    check(err==sentinel,'the ORIGINAL error object identity is preserved (throwing __tostring)')
    check(list[#list].kind=='invocation_finish' and list[#list].ok==false,
        'the finish record is still emitted when error formatting is impossible')
    check(list[#list].error~=nil,'the finish record carries some honest error text/type')
end

print('S3 native trace observer mechanics: '..checks..' checks passed')
