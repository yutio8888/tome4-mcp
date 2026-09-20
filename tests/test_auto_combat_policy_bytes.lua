-- X-doubleprime: immutable canonical-byte policy snapshots + transaction-boundary
-- validation (replaces the X-prime table-identity mechanism).
--
-- Pre-registered falsification matrix rows (see
-- `tmp/mcp-play-support/astra-defect-family-addendum.md`):
--   1. real wire bypass          5. whole-import atomicity
--   2. source/returned mutation  6. codec + diagnostics
--   3. transaction leak          7. cost (measured separately)
--   4. every sink and restore
--
-- This suite pins rows 1-6 in-process; determinism across fresh processes is
-- exercised by the repeated-run harness and by the JSON suite.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
package.path=root..'/overload/?.lua;'..package.path
local Codec=require 'mod.auto_combat.PolicyCodec'
local Schema=require 'mod.auto_combat.PolicySchema'
local Store=require 'mod.auto_combat.PolicyStore'
local Adapter=require 'mod.auto_combat.AssistantAdapter'
local Service=require 'mod.auto_combat.AutoCombatService'
local Presets=require 'mod.auto_combat.PolicyPresets'
local PolicyIO=require 'mod.auto_combat.PolicyIO'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local fixture_dir=root..'/tests/fixtures/assistant/'
local function fixture(name)
    local file=assert(io.open(fixture_dir..name,'r'))
    local text=file:read('*a');file:close()
    return Json.decode(text)
end
local function fresh() return fixture('anorithil_pinned.json') end

-- Pinned before/after content hash: the X-doubleprime codec is a NEW explicit
-- encoding, but the CONTENT-HASH projection must stay byte-compatible.
local PINNED_HASH='2836a530'

local function policy(overrides)
    local p={
        schema='tome-auto-combat/v1',id='p1',name='p1',
        limits={max_actions_per_tick=1},
        safety={min_hp_pct=35,flee_below_hp_pct=25,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        rules={{id='beam',priority=50,when={enemy_count={ge=1}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}},
    }
    for k,v in pairs(overrides or {}) do p[k]=v end
    return p
end

local MALFORMED=function()
    return {schema='tome-auto-combat/v1',id='bad',name='bad',
        limits={max_actions_per_tick=1},safety={},targeting={default='nearest_hostile'},
        sustains={},rules={{id='r',priority=1,when={all={hidden={always={}}}},
            ['then']={action='attack'}}}}
end

-- ===========================================================================
-- Row 6: codec round-trip, stability, empty containers, null/false/absent
-- ===========================================================================
do
    local original=assert(Adapter.translate(fresh()).draft)
    local snapshot,err=Codec.prepare(original,'test')
    check(snapshot~=nil and err==nil,'a valid preset prepares a snapshot')
    check(type(snapshot.bytes)=='string' and snapshot.bytes:sub(1,5)=='xdp1\n',
        'the snapshot is explicit canonical bytes with a versioned header')
    -- decode(encode(valid)) is semantically equivalent and the tree is a fresh
    -- table (not an alias of the caller's).
    local tree=assert(Codec.open(snapshot))
    check(tree~=original,'the working tree is a private decode, not the caller table')
    check(tree.id==original.id and #tree.rules==#original.rules,
        'decode(encode(valid)) preserves the document')
    -- encode(decode(bytes)) is stable (a fixed point).
    check(Codec.encode(tree)==snapshot.bytes,'encode(decode(bytes)) is canonical-stable')
    -- Hash compatibility with the historical projection (the golden valid-input
    -- hash captured before the byte-snapshot slice).
    check(snapshot.hash==PINNED_HASH,'the pinned valid-input content hash does not move (got '
        ..tostring(snapshot.hash)..')')
    -- `updated` metadata is excluded from the content hash but PRESERVED by the
    -- storage encoding.
    local withUpdated=assert(Adapter.translate(fresh()).draft)
    withUpdated.updated='2030-01-01T00:00:00'
    local s2=assert(Codec.prepare(withUpdated,'test'))
    check(s2.hash==snapshot.hash,'`updated` does not change the content hash')
    check(s2.bytes~=snapshot.bytes and #s2.bytes>#snapshot.bytes,
        '`updated` is preserved in the canonical bytes (not dropped by the codec)')
    check(select(1,Codec.open(s2)).updated=='2030-01-01T00:00:00',
        '`updated` survives the storage round-trip')
    -- null / false / absent are distinct in the codec.
    local nullDoc={schema='tome-auto-combat/v1',id='n',name='n',
        limits={max_actions_per_tick=1},safety={pause_on_new_enemy=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        rules={{id='r',priority=1,when={always={}},enabled=false,
            ['then']={action='attack',target='nearest_hostile'}}}}
    local ns=assert(Codec.prepare(nullDoc,'test'))
    local nt=assert(Codec.open(ns))
    check(nt.safety.pause_on_new_enemy==true and nt.safety.flee_below_hp_pct==nil,
        'a `false` boolean is preserved and an absent key stays absent')
    check(nt.rules[1].enabled==false,'explicit `false` is preserved separately from absent')
    check(Codec.encode(nt)==ns.bytes,'boolean/absent round-trip is canonical-stable')
    -- XDP-REV-06: a Json.null value is actually exercised (not just false/absent).
    local nullValueDoc=Adapter.translate(fresh()).draft
    nullValueDoc.updated=Json.null
    local vs=assert(Codec.prepare(nullValueDoc,'test'))
    check(select(1,Codec.open(vs)).updated==Json.null,'a Json.null value survives the round-trip as null')
    -- An empty container is the empty OBJECT in both the codec and the hash.
    local emptyDoc={schema='tome-auto-combat/v1',id='e',name='e',
        limits={max_actions_per_tick=1},safety={},targeting={default='nearest_hostile'},
        rules={{id='r',priority=1,when={always={}},['then']={action='attack'}}}}
    local es=assert(Codec.prepare(emptyDoc,'test'))
    check(assert(Codec.open(es)).safety~=nil,'an empty container survives as an empty object')
    check(es.bytes:find('o0:',1,true)~=nil,'the empty container encodes as `o0:`')
end

-- ===========================================================================
-- Row 6: number representation / bounded decode / diagnostics
-- ===========================================================================
do
    -- Every finite number round-trips exactly, including fractions/fatigue.
    local doc={schema='tome-auto-combat/v1',id='num',name='num',
        limits={max_actions_per_tick=1},
        safety={min_hp_pct=33.333333333333,flee_below_hp_pct=0.5,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        rules={{id='r',priority=1.5,when={hp_pct={lt=12.25}},
            ['then']={action='attack'}}}}
    local s=assert(Codec.prepare(doc,'test'))
    local t=assert(Codec.open(s))
    check(t.safety.min_hp_pct==33.333333333333 and t.rules[1].priority==1.5
        and t.rules[1].when.hp_pct.lt==12.25,'fractional numbers round-trip exactly')
    check(Codec.encode(t)==s.bytes,'numeric re-encode is canonical-stable')
    -- A truncated / tampered / foreign snapshot is refused typed, never
    -- partially decoded.
    local good=s.bytes
    check(select(1,Codec.open('xdp1\n'))==nil,'an empty body is refused')
    check(select(1,Codec.open('notxdp'))==nil,'a foreign header is refused')
    check(select(1,Codec.open(good:sub(1,#good-1)))==nil,'a truncated snapshot is refused')
    check(select(1,Codec.open(good..'x'))==nil,'trailing bytes are refused')
    local hdr=Codec.open(good)
    check(hdr~=nil,'an intact snapshot still opens')
    -- Diagnostics are deterministic for inadmissible key kinds: a type label,
    -- never a tostring address.
    local bad={}
    bad[function() end]=1
    local f=Codec.audit(bad,'cfg')
    check(f~=nil and f.input=='cfg' and f.cause=='invalid_key' and f.key=='<function>',
        'an exotic key is a typed invalid_key with a type label (got '
        ..tostring(f and f.input)..' / '..tostring(f and f.cause)..' / '..tostring(f and f.key)..')')
    local numf=Codec.audit({[1.5]='x'},'cfg')
    check(numf~=nil and numf.cause=='non_integer_key' and numf.key==1.5,
        'a fractional key names the offending key numerically')
end

-- ===========================================================================
-- Row 2: source and returned-object mutation
-- ===========================================================================
do
    -- The store's authoritative state is bytes: mutating the caller table after
    -- set_draft does not change the stored snapshot or its hash.
    local store=Store.new()
    local raw=policy()
    local set=assert(Store.setDraft(store,raw,nil))
    local hash=set.draft_hash
    raw.rules[1].when={always={}}
    raw.rules[1].priority=9999
    raw.name='MUTATED'
    check(Store.hashes(store).draft==hash,'mutating the caller table cannot change the stored draft')
    -- getVersion returns a detached decoded copy; mutating it (including via
    -- rawset) cannot change the stored bytes.
    local view=assert(Store.getVersion(store,'draft'))
    view.rules[1].when={all={hidden={always={}}}}  -- the review's schema-valid? no: malformed
    rawset(view.rules[1],'priority',12345)
    view.name='RETURNED MUTATION'
    check(Store.hashes(store).draft==hash,'mutating a returned copy cannot change the stored draft')
    -- Even a SCHEMA-VALID edit of a returned copy cannot change what is
    -- approved/running: approval binds the specific snapshot bytes.
    local validView=assert(Store.getVersion(store,'draft'))
    validView.rules[1].when={always={}}  -- schema-valid content change
    Store.approve(store,nil)
    local running=Store.activate(store,nil)
    check(running.running_hash==hash,'approval/activation bind the approved snapshot, not the returned copy')
    local afterEdit=Store.hashes(store)
    check(afterEdit.approved==hash and afterEdit.running==hash,
        'a schema-valid edit of any returned copy cannot change the approved/running policy')
    -- Metatable tampering cannot reach the store either: the decoded copy has
    -- no metatable, and the codec refuses an unknown metatable on input.
    local tampered=policy()
    setmetatable(tampered,{})
    local s2,err=Codec.prepare(tampered,'set_draft')
    check(s2==nil and err.code=='invalid_document' and err.cause=='invalid_metatable',
        'a caller table with an unknown metatable is refused typed')
    -- The public service get() is detached too.
    local svc=Service.new()
    local sd=Service.handle(svc,'set_draft',{policy=policy()})
    local got=Service.handle(svc,'get',{})
    check(got.running==nil,'get returns nil for the not-yet-activated running version')
    rawset(got.draft.rules[1],'priority',77)
    got.draft.rules[1].when={all={hidden={always={}}}}
    check(Service.handle(svc,'get',{}).draft_hash==sd.draft_hash,
        'service get() exposes no alias to authoritative state')
end

-- ===========================================================================
-- Row 2 (continued): a schema-valid edit cannot change a running policy or its
-- hash, and the controller evaluates the snapshot
-- ===========================================================================
do
    local svc=Service.new{host_factory=function()
        return {snapshot=function() return {hp_pct=80,enemy_count=1} end,
            request=function() return {status='ok',energy_spent=true} end}
    end}
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local a=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=a.approved_hash})
    local before=Service.status(svc).running_hash
    -- Reproduce XPS1-R2-01: mutate every returned copy, even schema-validly.
    local got=Service.handle(svc,'get',{})
    got.approved.rules[1].when={always={}}
    got.running.rules[1].when={always={}}
    rawset(got.approved,'name','HACKED')
    check(Service.status(svc).running_hash==before,
        'a schema-valid edit of any returned copy cannot change the running hash')
    check(Service.handle(svc,'start',{}).ok,'the run starts from the snapshot')
    local step=Service.step(svc)
    check(step.ok and step.step.rule=='beam','the controller evaluates the snapshot, not a mutated copy')
end

-- ===========================================================================
-- Row 1: real wire bypass - malformed input refuses through every entry
-- ===========================================================================
do
    local svc=Service.new{dry_run_host_factory=function()
        return {snapshot=function() return {hp_pct=80,enemy_count=1} end}
    end}
    local malformed=MALFORMED()
    local function noHash(fn)
        local calls=0
        local real=Schema.hash
        Schema.hash=function(...) calls=calls+1; return real(...) end
        local value=fn()
        Schema.hash=real
        return value,calls
    end
    local v,c1=noHash(function() return Service.handle(svc,'validate',{policy=malformed}) end)
    check(not v.ok and v.error.code=='invalid_policy','validate refuses the review\'s malformed when')
    check(c1==0,'a refused validate performs zero hash projections')
    local d,c2=noHash(function() return Service.handle(svc,'dry_run',{policy=malformed}) end)
    check(not d.ok and d.error.code=='invalid_policy','dry_run refuses the malformed when')
    check(c2==0,'a refused dry_run performs zero hash projections')
    local sd,c3=noHash(function() return Service.handle(svc,'set_draft',{policy=malformed}) end)
    check(not sd.ok,'set_draft refuses the malformed when')
    check(c3==0 and svc.store.draft==nil and svc.revision==0,
        'a refused set_draft performs zero hash projections and stores nothing')
    -- Combined JSON document import.
    local doc=Json.encode{format=1,envelope='tome-auto-combat-policy',policy=malformed}
    local im,c4=noHash(function() return Service.handle(svc,'import',{document=doc}) end)
    check(not im.ok,'the document import refuses the malformed when')
    check(c4==0,'a refused document import performs zero hash projections')
    -- Malformed input cannot be promoted directly through the public Store.
    local store=Store.new()
    local promoted=Store.setDraft(store,malformed,nil)
    check(promoted==nil,'a direct Store.setDraft cannot promote malformed input')
    check(Store.hashes(store).draft==nil,'the failed direct promotion stored nothing')
    -- Valid round-trip: import_assistant(store=false) -> JSON -> fresh table
    -- works through validate/dry_run/set_draft.
    local imported=Service.handle(svc,'import_assistant',{config=fresh()})
    check(imported.ok and imported.hash==PINNED_HASH,'a valid assistant import still works')
    local round=Json.decode(Json.encode(imported.draft))
    check(round~=nil,'the imported draft survives a JSON round-trip')
    local rv=Service.handle(Service.new(),'validate',{policy=round})
    check(rv.ok and rv.hash==PINNED_HASH,'a round-tripped valid policy validates after re-preparation')
    local rd=Service.handle(Service.new{dry_run_host_factory=function()
        return {snapshot=function() return {hp_pct=80,enemy_count=0} end}
    end},'dry_run',{policy=round})
    check(rd.ok and rd.policy_hash==PINNED_HASH,'a round-tripped valid policy dry-runs')
    local svc2=Service.new()
    local rd2=Service.handle(svc2,'set_draft',{policy=round})
    check(rd2.ok and rd2.draft_hash==PINNED_HASH,'a round-tripped valid policy stores')
    -- `store=false` on a valid assistant import is also a full transaction: it
    -- produces no draft and advances no revision, but the hash is validated.
    local svc3=Service.new()
    local gen=Service.handle(svc3,'import_assistant',{config=fresh()})
    check(gen.ok and gen.stored==nil and svc3.store.draft==nil and svc3.revision==0,
        'store=false validates but stores nothing and advances no revision')
end

-- ===========================================================================
-- Row 1 (continued): stored-policy fallback dry_run refusals
-- ===========================================================================
do
    local svc=Service.new{dry_run_host_factory=function()
        return {snapshot=function() return {hp_pct=80,enemy_count=1} end}
    end}
    Service.handle(svc,'set_draft',{policy=policy()})
    check(Service.handle(svc,'dry_run',{}).ok,'the stored draft dry-runs')
    Service.handle(svc,'approve',{})
    check(Service.handle(svc,'dry_run',{}).ok,'the stored approved policy dry-runs')
    Service.handle(svc,'activate',{})
    check(Service.handle(svc,'dry_run',{}).ok,'the stored running policy dry-runs')
end

-- ===========================================================================
-- Row 3: transaction leak through a retained/mutating host factory
-- ===========================================================================
do
    -- The explicit dry-run path: a factory that retains and mutates the policy
    -- it receives must not change the reported hash/decision.
    local retained
    local svc=Service.new{dry_run_host_factory=function(policy)
        retained=policy
        -- Mutate everything the schema allows.
        if policy and policy.rules and policy.rules[1] then
            policy.rules[1].when={always={}}
            rawset(policy.rules[1],'priority',9999)
        end
        if policy then policy.name='MUTATED BY FACTORY' end
        return {snapshot=function() return {hp_pct=80,enemy_count=0} end}
    end}
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local dry=Service.handle(svc,'dry_run',{})
    check(dry.ok and dry.policy_hash==d.draft_hash,
        'a mutating dry-run host factory cannot change the evaluated hash')
    check(retained~=nil and retained~=Service.handle(svc,'get',{}).draft,
        'the factory received a detached copy, not authoritative state')
    check(Service.handle(svc,'get',{}).draft_hash==d.draft_hash,
        'the factory mutation cannot change the stored draft')
    -- The explicit request path (no store) with a mutating factory.
    local req=Service.handle(Service.new{dry_run_host_factory=function(policy)
        policy.rules[1].when={always={}}
        return {snapshot=function() return {hp_pct=80,enemy_count=0} end}
    end},'dry_run',{policy=policy()})
    check(req.ok and req.policy_hash==d.draft_hash,
        'a mutating factory cannot change an explicit request policy\'s reported hash')
    -- A factory that RETAINS the working tree across calls cannot corrupt the
    -- next transaction either.
    local leaked
    local svc2=Service.new{dry_run_host_factory=function(policy)
        leaked=policy
        return {snapshot=function() return {hp_pct=80,enemy_count=1} end}
    end}
    local rd=Service.handle(svc2,'dry_run',{policy=policy()})
    local rhash=rd.policy_hash
    leaked.rules[1].when={always={}}
    check(Service.handle(svc2,'dry_run',{policy=policy()}).policy_hash==rhash,
        'a retained working tree cannot change the next transaction')
end

-- ===========================================================================
-- XDP-REV-02: the callback receives neither `svc` nor the working tree, and a
-- stored-record swap through any reachable alias cannot change the evaluated
-- value (regression for the stored `svc` dry-run leak).
-- ===========================================================================
do
    local args_seen
    local svc=Service.new{dry_run_host_factory=function(...)
        args_seen=select('#',...)
        return {snapshot=function() return {hp_pct=80,enemy_count=0} end}
    end}
    Service.handle(svc,'set_draft',{policy=policy()})
    local dry=Service.handle(svc,'dry_run',{})
    check(dry.ok and args_seen==1,'the dry-run callback receives exactly one argument (never svc)')
    -- The stored records are private: no string-keyed field of the service's
    -- store is the live record, so a callback cannot swap one (the leak the
    -- `svc.store.draft` alias allowed).
    check(svc.store.draft==nil and svc.store.approved==nil and svc.store.running==nil,
        'the stored records are not reachable through string-keyed store fields')
end

-- ===========================================================================
-- XDP-REV-02: the live host factory receives only a detached decode; a
-- mutating factory that installs a root __index cannot change low-HP
-- behaviour while the hash stays the approved hash.
-- ===========================================================================
do
    local function liveService(mutating)
        return Service.new{host_factory=function(policy)
            if mutating then
                setmetatable(policy,{__index=function(_,key)
                    if key=='mode' then return {on_low_hp='evaluate_rules'} end
                end})
            end
            return {snapshot=function() return {hp_pct=10,enemy_count=1,bound_target='e1',binding_selector='nearest_hostile'} end,
                request=function() return {status='ok',energy_spent=true} end}
        end}
    end
    local function runLive(svc)
        local d=assert(Service.handle(svc,'set_draft',{policy=policy()}))
        local a=assert(Service.handle(svc,'approve',{expected_hash=d.draft_hash}))
        assert(Service.handle(svc,'activate',{expected_hash=a.approved_hash}).ok)
        local started=Service.handle(svc,'start',{})
        local step=Service.step(svc)
        return d,started,step
    end
    local d,normalStart,normal=runLive(liveService(false))
    check(normalStart.ok and normal.ok and normal.step.action=='paused'
        and normal.step.reason=='flee_below_hp_pct',
        'the live run pauses below flee_below_hp_pct with the intact policy')
    local d2,mutStart,mut=runLive(liveService(true))
    check(mutStart.ok and mut.ok,'the mutating live factory cannot refuse the run')
    check(mut.step.action=='paused' and mut.step.reason=='flee_below_hp_pct',
        'a root-__index factory cannot turn a low-HP pause into an action')
    check(d2.draft_hash==d.draft_hash,'the mutating factory cannot change the approved hash')
end

-- ===========================================================================
-- Row 4: every sink and restore
-- ===========================================================================
do
    -- Schemas: the public hash/canonical wrappers validate or refuse.
    local okHash=pcall(Schema.hash,MALFORMED())
    check(okHash==false,'Schema.hash refuses a malformed policy instead of hashing it')
    local okCanon=pcall(Schema.canonical,MALFORMED())
    check(okCanon==false,'Schema.canonical refuses a malformed policy')
    check(Schema.project(MALFORMED())==nil,
        'the structured hash entry point refuses a malformed policy')
    -- Direct PolicyStore: malformed set/approve/activate.
    local store=Store.new()
    check(Store.setDraft(store,{schema='x'},nil)==nil,'Store.setDraft refuses a malformed policy')
    check(Store.approve(store,nil)==nil,'Store.approve refuses without a draft')
    check(Store.activate(store,nil)==nil,'Store.activate refuses without an approved policy')
    -- Preset sink: a drifted built-in source is refused.
    local original=Presets.PRESETS.anorithil_p1a.rules[1].when
    Presets.PRESETS.anorithil_p1a.rules[1].when={all={hidden={always={}}}}
    local svc=Service.new()
    local p=Service.handle(svc,'preset',{name='anorithil_p1a'})
    check(not p.ok and p.error.code=='invalid_policy','a drifted preset is refused at the preset sink')
    Presets.PRESETS.anorithil_p1a.rules[1].when=original
    check(Service.handle(Service.new(),'preset',{name='anorithil_p1a'}).ok,
        'the intact preset still prepares')
    -- Export sink: malformed bytes cannot be hashed/exported. XDP-REV-01: a
    -- hand-installed record must be normalised on restore, so malformed bytes
    -- never enter the vault in the first place.
    local store2=Store.new()
    check(Store.restore(store2,'draft',{bytes='xdp1\no0:',hash='deadbeef',version=1})==nil,
        'a malformed snapshot record is refused on restore (normalised, never stored by alias)')
    local svc2=Service.new()
    svc2.store=store2
    check(not Service.handle(svc2,'export',{}).ok,'a tampered snapshot is refused at export')
    -- saveState / loadState: load never resumes control and never trusts data.
    local svc3=Service.new{host_factory=function() return {snapshot=function() return {} end} end}
    Service.handle(svc3,'set_draft',{policy=policy()})
    Service.handle(svc3,'approve',{})
    Service.handle(svc3,'activate',{})
    local state=Service.saveState(svc3)
    check(state.format==2 and state.draft~=nil and state.approved~=nil,
        'saveState writes detached decoded versions under the new format')
    local restored=Service.new()
    check(Service.loadState(restored,state)==true,'the saved state loads')
    check(Store.has(restored.store,'approved') and not Store.has(restored.store,'running')
        and restored.arbiter.owner=='manual',
        'loading policy data never restores the running state or control')
    check(Service.loadState(restored,{approved={schema='bad'}})==true
        and Store.has(restored.store,'approved'),'a malformed restored policy is ignored, not promoted')
    check(Service.loadState(Service.new(),{draft=MALFORMED(),approved=MALFORMED()})==true,
        'loading malformed data is a no-op')
    local fresh2=Service.new()
    check(Service.loadState(fresh2,{draft=MALFORMED(),approved=MALFORMED()})
        and not Store.has(fresh2.store,'draft') and not Store.has(fresh2.store,'approved'),
        'malformed restored policy data is never promoted')
end

-- ===========================================================================
-- Row 3 (continued) + row 4: the controller consumes its transaction snapshot
-- ===========================================================================
do
    -- A controller whose working tree is mutated after start stops with
    -- `policy_mutated` instead of evaluating the mutated value.
    local svc=Service.new{host_factory=function()
        return {snapshot=function() return {hp_pct=80,enemy_count=1} end,
            request=function() return {status='ok',energy_spent=true} end}
    end}
    local d=Service.handle(svc,'set_draft',{policy=policy()})
    local a=Service.handle(svc,'approve',{expected_hash=d.draft_hash})
    Service.handle(svc,'activate',{expected_hash=a.approved_hash})
    Service.handle(svc,'start',{})
    -- Mutate the controller's working tree directly (rawset, the documented
    -- residual): the transaction boundary refuses it on the next opportunity.
    rawset(svc.controller.policy.rules[1],'when',{always={}})
    local step=Service.step(svc)
    check(step.ok and step.step.action=='stopped' and step.step.reason=='policy_mutated',
        'the controller refuses a mutated working tree at the transaction boundary')
    -- Lifecycle/status/log/replay report the running SNAPSHOT hash.
    local svc2=Service.new{host_factory=function() return {snapshot=function()
        return {hp_pct=80,enemy_count=1} end,request=function() return {status='ok',energy_spent=true} end} end}
    local d2=Service.handle(svc2,'set_draft',{policy=policy()})
    local a2=Service.handle(svc2,'approve',{expected_hash=d2.draft_hash})
    Service.handle(svc2,'activate',{expected_hash=a2.approved_hash})
    Service.handle(svc2,'start',{})
    local running=Service.status(svc2).running_hash
    Service.step(svc2)
    local log=Service.handle(svc2,'log',{limit=8})
    check(log.ok and log.events[1].policy_hash==running,
        'the action log carries the running snapshot hash')
    local replay=Service.handle(svc2,'replay',{})
    check(replay.ok and replay.header.policy_hash==running,
        'the replay header carries the running snapshot hash')
end

-- ===========================================================================
-- Row 5: whole-import atomicity on malformed elements/conditions
-- ===========================================================================
do
    local function refused(config,input,cause)
        local calls=0
        local real=Schema.hash
        Schema.hash=function(...) calls=calls+1; return real(...) end
        local result=Adapter.translate(config)
        Schema.hash=real
        check(result.ok==false,'the import is refused: '..tostring(input))
        check(result.draft==nil,'no draft is produced')
        check(result.snapshot==nil,'no snapshot is produced')
        check(result.error and result.error.code=='invalid_document','a typed invalid_document fault')
        check(result.error.input==input,'the fault names '..tostring(input)
            ..' (got '..tostring(result.error.input)..')')
        if cause then
            check(result.error.cause==cause,'the fault names the cause '..tostring(cause)
                ..' (got '..tostring(result.error.cause)..')')
        end
        check(calls==0,'zero hash projections for a refused import')
        return result.error
    end
    -- First / middle / last malformed talent element.
    local c=fresh(); c.talents[1]='MALFORMED'
    check(refused(c,'talents','invalid_element').key==1,'the first malformed element is named')
    c=fresh(); c.talents[2]=Json.null
    check(refused(c,'talents','invalid_element').key==2,'a middle json.null element is named')
    c=fresh(); c.talents[#c.talents]='MALFORMED'
    check(refused(c,'talents','invalid_element').key==#c.talents,'the last malformed element is named')
    -- Malformed sustain element.
    c=fresh(); c.sustains[1]='MALFORMED'
    refused(c,'sustains','invalid_element')
    -- Malformed nested condition (including an invalid disabled entry's shape).
    c=fresh(); c.talents[1].when={all={[1]={hp_pct={lt=70}},[3]={hp_pct={lt=50}}}}
    check(refused(c,'talents[1].when.all','key_beyond_dense_end').key==3,
        'a malformed nested condition names the offending index')
    -- A table-valued key is a typed fault, NEVER silently dropped (XPS1-R2-03).
    -- The complete constructor's structural audit catches it in the ORIGINAL.
    c=fresh(); c.talents[1].when[{}]={nested={}}
    refused(c,'talents[1].when','invalid_key')
    c=fresh(); c[{}]='x'
    check(refused(c,'config','invalid_key')~=nil,'a table-valued top-level key is a fault')
    -- Cycle and excessive depth.
    c=fresh(); c.self=c
    check(refused(c,'self','cycle')~=nil,'a cycle is refused')
    local deep={always={}}
    for _=1,70 do deep={all={deep}} end
    c=fresh(); c.talents[1].when=deep
    local derr=Adapter.translate(c)
    check(derr.ok==false and derr.error.code=='invalid_document',
        'an over-depth condition is refused')
    -- Service path: no draft/hash/store/revision movement for any of these.
    local svc=Service.new()
    c=fresh(); c.talents[1]='MALFORMED'
    local calls=0
    local real=Schema.hash
    Schema.hash=function(...) calls=calls+1; return real(...) end
    local result=Service.handle(svc,'import_assistant',{config=c,store=true})
    Schema.hash=real
    check(result.ok==false and result.error.details.cause=='invalid_element',
        'the service refuses a malformed element atomically')
    check(calls==0 and svc.store.draft==nil and svc.store.approved==nil
        and svc.store.running==nil and svc.revision==0,
        'a malformed element performs zero hash projections and freezes the store')
end

-- ===========================================================================
-- Row 6 (continued): no lossy copy before validation
-- ===========================================================================
do
    -- A malformed ORIGINAL that a lossy copy would have "repaired" is refused.
    -- (An unknown predicate NAME is an unsupported-capability report; a
    -- table-valued KEY in the original is a structural fault.)
    local c=fresh()
    c.talents[1].when[{}]='x'
    local result=Adapter.translate(c)
    check(result.ok==false and result.error.code=='invalid_document'
        and result.error.cause=='invalid_key',
        'a table-valued key in the ORIGINAL is a typed fault, not a silent drop')
    -- The complete constructor refuses before any encode/project (counters).
    local before=Codec.stats()
    local s,err=Codec.prepare(MALFORMED(),'sink')
    local after=Codec.stats()
    check(s==nil and err.code=='invalid_policy','a malformed policy is refused by prepare')
    check(after.encodes==before.encodes and after.projections==before.projections,
        'validation precedes any encode/hash projection (no lossy copy first)')
    check(after.validations>before.validations,'the transaction did run the complete validator')
end

-- ===========================================================================
-- Row 2 (continued): metatable tampering cannot change authoritative state
-- ===========================================================================
do
    local store=Store.new()
    local raw=policy()
    Store.setDraft(store,raw,nil)
    local hash=Store.hashes(store).draft
    -- Tamper with every returned copy's metatable and rawset fields.
    local copy=assert(Store.getVersion(store,'draft'))
    pcall(setmetatable,copy,{__index=function() return 'HACKED' end})
    rawset(copy,'id','HACKED')
    check(Store.hashes(store).draft==hash,'metatable tampering cannot change the stored hash')
    -- XDP-REV-01: getSnapshot returns a fresh COPY of the private record, so a
    -- caller editing its fields edits only the copy and can never change the
    -- store's bytes/hash/meaning (nor promote malformed bytes via approve).
    local record=Store.getSnapshot(store,'draft')
    local originalBytes=record.bytes
    record.bytes='xdp1\no0:'
    record.hash='deadbeef'
    check(Store.getSnapshot(store,'draft').bytes==originalBytes,
        'mutating a returned snapshot cannot reach the store record')
    check(Store.hashes(store).draft==hash,'mutating a returned snapshot cannot change the derived hash')
    check(Store.getSnapshot(store,'draft')~=Store.getSnapshot(store,'draft'),
        'getSnapshot returns a fresh copy every call (never a shared alias)')
    -- Promotion re-opens and re-derives: approve/activate build fresh records
    -- from the exact bytes, so approving after the tamper attempt still
    -- certifies the ORIGINAL bytes with the derived hash.
    local approved=assert(Store.approve(store,hash))
    check(approved.approved_hash==hash,'approve certifies the derived hash of the exact bytes')
    check(Store.getSnapshot(store,'approved').bytes==originalBytes,
        'the approved record holds the original canonical bytes')
    check(Store.getSnapshot(store,'approved')~=Store.getSnapshot(store,'draft'),
        'promotion builds a fresh record, never a shared reference')
    -- And the restored-locater class is closed: a wire-shaped {bytes,hash} dict
    -- with a forged hash is normalised on restore (hash re-derived).
    local restored=assert(Store.restore(store,'approved',
        {bytes=originalBytes,hash='restore-forged',schema=raw.schema,id=raw.id,version=1}))
    check(restored.hash==hash,'restore re-derives the hash from the exact bytes (forged hash discarded)')
    check(Store.getSnapshot(store,'approved').hash==hash,
        'the stored approved hash is the derived hash, not the supplied one')
end

-- ===========================================================================
-- XDP-REV-03: public hash wrappers run the COMPLETE audit; a wire-shaped
-- {bytes,hash} dict is never trusted for its supplied hash.
-- ===========================================================================
do
    -- A metatable-bearing policy is refused by prepare AND by every public
    -- hash wrapper (previously the raw hash branch skipped the audit).
    local mtPolicy=policy()
    setmetatable(mtPolicy,{})
    check(Codec.prepare(mtPolicy,'prepare')==nil,'prepare refuses a metatable-bearing policy')
    check(Codec.hash(mtPolicy)==nil,'Codec.hash refuses a metatable-bearing policy (same audit)')
    check(not pcall(Schema.hash,mtPolicy),'Schema.hash refuses a metatable-bearing policy')
    check(Schema.project(mtPolicy)==nil,'Schema.project refuses a metatable-bearing policy')
    -- A table-valued KEY under the dropped `updated` metadata is refused by
    -- the complete audit, and by the hash wrappers too.
    local lossy=policy()
    lossy.updated={[{}]='silently dropped from projection'}
    check(Codec.prepare(lossy,'prepare')==nil,'prepare refuses a table-valued key in updated')
    check(Codec.hash(lossy)==nil,'Codec.hash refuses a table-valued key in updated')
    check(not pcall(Schema.hash,lossy),'Schema.hash refuses a table-valued key in updated')
    -- A wire dict {bytes=<real bytes>,hash='attacker-hash'} that survived a
    -- JSON round-trip is normalised: every sink reports the DERIVED hash.
    local good=assert(Codec.prepare(policy(),'good'))
    local fake={bytes=good.bytes,hash='attacker-hash',schema=good.schema,id=good.id,version=good.version}
    local wireFake=Json.decode(Json.encode(fake))
    local validated=Service.handle(Service.new(),'validate',{policy=wireFake})
    check(validated.ok and validated.hash==good.hash,
        'validate reports the derived hash of the bytes, never the supplied one')
    check(Adapter.hashPolicy(wireFake)==good.hash,'hashPolicy re-derives the hash from the bytes')
    check(Codec.hash(wireFake)==good.hash,'Codec.hash re-derives the hash from the bytes')
    local exported=assert(PolicyIO.export(wireFake))
    check(Json.decode(exported).hash==good.hash,'export reports the derived hash')
    -- A wire dict with CORRUPTED bytes is refused (never auto-promoted).
    local corrupted={bytes=good.bytes:gsub('T_MOONLIGHT_RAY','T_BOGUS_TALENT'),hash='attacker-hash'}
    check(Service.handle(Service.new(),'validate',{policy=corrupted}).ok==false,
        'a wire dict whose bytes do not validate is refused')
    -- And a raw policy table that is also valid: hash equals prepare's hash.
    check(Codec.hash(policy())==good.hash,'Codec.hash(raw table) runs the same complete transaction')
end

-- ===========================================================================
-- XDP-REV-04: noncanonical byte encodings are refused and never stored.
-- ===========================================================================
do
    local good=assert(Codec.prepare(policy(),'good'))
    -- A leading zero in the root object count decodes to the same tree but is
    -- NOT the canonical byte form; it must be refused, never kept.
    local noncanonical=good.bytes:gsub('^(xdp1\no)(%d+):',function(prefix,count)
        return prefix..'0'..count..':'
    end,1)
    check(noncanonical~=good.bytes,'the probe fixture is genuinely noncanonical')
    local opened,err=Codec.open(noncanonical)
    check(opened==nil and err.cause=='noncanonical_bytes','a noncanonical snapshot is refused by open')
    local store=Store.new()
    local stored,storeErr=Store.setDraft(store,{bytes=noncanonical,hash=good.hash,version=1},nil)
    check(stored==nil and storeErr.code=='invalid_snapshot' and storeErr.cause=='noncanonical_bytes'
        and not Store.has(store,'draft'),
        'the store refuses noncanonical bytes (nothing published)')
    -- A noncanonical NUMBER spelling is refused the same way.
    local ncNum=good.bytes:gsub('#i(%-?%d+);','#d%1;',1)
    if ncNum~=good.bytes then
        check(select(1,Codec.open(ncNum))==nil,'a noncanonical number spelling is refused')
    end
    -- Canonical bytes still open and hash to the derived hash.
    check(select(1,Codec.open(good.bytes))~=nil and Codec.hash(good.bytes)==good.hash,
        'canonical bytes still open and hash normally')
end

-- ===========================================================================
-- XDP-REV-05: invalid UTF-8 is a typed constructor fault BEFORE encode.
-- ===========================================================================
do
    local bad=policy()
    bad.name=string.char(255)
    local before=Codec.stats()
    local ok,snap,err=pcall(Codec.prepare,bad,'utf8')
    check(ok==true and snap==nil and err.code=='invalid_document' and err.cause=='invalid_utf8',
        'invalid UTF-8 in a value is a typed audit fault, not an untyped throw')
    local after=Codec.stats()
    check(after.encodes==before.encodes,'invalid UTF-8 is refused before any encode')
    local store=Store.new()
    local okStore,stored,storeErr=pcall(Store.setDraft,store,bad,nil)
    check(okStore==true and stored==nil and storeErr.code=='invalid_document'
        and storeErr.cause=='invalid_utf8' and not Store.has(store,'draft'),
        'invalid UTF-8 becomes a typed store fault with no draft published')
    -- An invalid-UTF-8 KEY is refused too (the hash projection JSON-encodes keys).
    local badKey=policy()
    badKey[string.char(254)]='x'
    local okKey,keySnap,keyErr=pcall(Codec.prepare,badKey,'utf8key')
    check(okKey==true and keySnap==nil and keyErr.cause=='invalid_utf8_key',
        'invalid UTF-8 in a KEY is a typed audit fault')
    -- Hostile BYTES carrying an invalid-UTF-8 string value are refused by open.
    local good2=assert(Codec.prepare(policy(),'good2'))
    local hostile=good2.bytes:gsub('s2:p1','s2:'..string.char(255)..string.char(255),1)
    check(hostile~=good2.bytes,'the hostile-bytes probe fixture is genuinely altered')
    local openedB,openErrB=Codec.open(hostile)
    check(openedB==nil and openErrB.code=='invalid_document' and openErrB.cause=='invalid_utf8',
        'a hostile byte string carrying invalid UTF-8 is refused by open')
end

-- ===========================================================================
-- Row 7 (in-process): the private exact-bytes/version hash cache is sound
-- ===========================================================================
do
    Codec.cacheClear()
    local snapshot=assert(Codec.prepare(Adapter.translate(fresh()).draft,'test'))
    -- `prepare` already validated and cached these bytes; clear so the first
    -- `open` demonstrably re-runs the full transaction.
    Codec.cacheClear()
    local beforeOpen=Codec.stats()
    local tree1=assert(Codec.open(snapshot))
    local afterFirstOpen=Codec.stats()
    local tree2=assert(Codec.open(snapshot))
    local afterSecondOpen=Codec.stats()
    check(tree1~=tree2,'each open returns a fresh private working tree (never leaked)')
    check(afterFirstOpen.validations>beforeOpen.validations,
        'the first open of a byte string runs the full schema/catalog validation')
    check(afterSecondOpen.validations==afterFirstOpen.validations,
        'the second open of the SAME exact bytes is served from the cache')
    check(Codec.hash(snapshot)==PINNED_HASH,'the cached hash equals the derived hash')
    -- A malformed document is never cached (its validation fails first), and a
    -- tampered record whose bytes were never validated still fails.
    check(not pcall(Schema.hash,MALFORMED()),'a malformed policy is never cached/hashed')
    local record=assert(Codec.prepare(Adapter.translate(fresh()).draft,'test'))
    record.bytes=record.bytes:gsub('T_HEALING_LIGHT','T_BOGUS_TALENT')
    local tampered,err=Codec.hash(record)
    check(tampered==nil,'a tampered snapshot record is refused (bytes re-validated)')
end

print('Policy bytes (X-doubleprime): '..checks..' checks passed')
