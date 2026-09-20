-- OwnedImport + AssistantAdapter import-refusal (X-prime slice 1).
--
-- Pins the vertical slice: a malformed required array refuses the WHOLE import
-- with a typed fault (input/cause/key), produces NO draft/hash/store, and a
-- valid import round-trips to the pinned policy hash.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
package.path=root..'/overload/?.lua;'..package.path
local Owned=require 'mod.auto_combat.OwnedImport'
local Adapter=require 'mod.auto_combat.AssistantAdapter'
local Schema=require 'mod.auto_combat.PolicySchema'
local Service=require 'mod.auto_combat.AutoCombatService'
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

-- Pinned before/after hash. The hash was captured on the pre-change tree
-- (`main@ded8e1a` AssistantAdapter) and must not move: the ownership slice is
-- behaviour-preserving for a valid import.
local PINNED_HASH='2836a530'

-- Constructor primitive ------------------------------------------------------
do
    local owned,fault=Owned.construct(fresh())
    check(owned~=nil and fault==nil,'a valid export constructs an owned snapshot')
    check(Owned.isOwned(owned),'the constructed value is the owned type')
    -- XPS1-REV-02: the metatable is protected. `getmetatable` hands out only
    -- the sentinel string, so `__newindex` cannot be stripped through the
    -- value, and `setmetatable` refuses a replacement.
    check(type(getmetatable(owned))=='string','getmetatable returns only the protected sentinel')
    check(not pcall(setmetatable,owned,{}),'setmetatable on an owned snapshot is refused')
    check(not pcall(setmetatable,owned.talents,{}),'setmetatable on a nested snapshot table is refused')
    -- The owned copy is a private deep snapshot: adding a NEW key is blocked,
    -- and it never aliases caller storage.
    local ok=pcall(function() owned.added_key=1 end)
    check(ok==false,'the owned snapshot refuses a new key')
    check(Owned.isOwned(owned),'the owned type survives ordinary reads')
    -- The owned copy is independent of later caller mutation.
    local raw=fresh()
    local snap=assert(Owned.construct(raw))
    raw.talents[1].talent='T_MUTATED'
    check(snap.talents[1].talent~=nil and snap.talents[1].talent:find('^T_')~=nil,
        'the owned snapshot does not alias caller storage')
    -- A raw table cannot be viewed as owned.
    local view,err=Owned.view(fresh())
    check(view==nil and err.code=='import_not_owned','view refuses a raw table')
    check(Owned.view(owned)==owned,'view returns the owned snapshot')
end

-- XPS1-REV-02 residual + the actual guarantee --------------------------------
-- What Lua 5.1 CANNOT prevent (documented, not tested away): `rawset` on an
-- existing/nested key (and `debug.*` metatable access) mutates an owned value.
-- The guarantee the implementation makes is therefore NOT immutability: every
-- hash/evaluate/store sink RE-VALIDATES, so a mutated owned value is refused
-- typed at the sink instead of being trusted on identity.
do
    local raw=fresh()
    local snap=assert(Owned.construct(raw))
    local ok=pcall(function() rawset(snap.talents[1],'when',{all={hidden={always={}}}}) end)
    check(ok==true,'Lua cannot prevent an existing-key rawset (the documented residual)')
    -- The mutated owned snapshot is refused at the consuming sink
    -- (translate re-dense-checks every array it reads).
    local result=Adapter.translate(snap)
    check(result.ok==false and result.error.code=='invalid_document',
        'a mutated owned snapshot is refused typed at the sink')
    check(result.error.input=='talents[1].when.all' and result.error.cause=='non_integer_key',
        'the sink refusal names the mutated input (got '
        ..tostring(result.error and result.error.input)..')')
    -- A forged lookalike cannot even attach a metatable that claims ownership:
    -- the protected metatable is unreachable (only the sentinel string is
    -- exposed), and identity — not any data marker — is the owned type.
    local forge_ok=pcall(setmetatable,{},getmetatable(assert(Owned.construct(fresh()))))
    check(not forge_ok,'the exposed sentinel cannot be attached as a real metatable')
    check(not Owned.isOwned({}),'a plain table is not the owned type')
end

-- Every required array refuses the whole import with a typed fault -----------
local function refused(config,input,cause)
    local calls=0
    local real=Schema.hash
    Schema.hash=function(...) calls=calls+1; return real(...) end
    local result=Adapter.translate(config)
    Schema.hash=real
    check(result.ok==false,'import refused: '..tostring(input))
    check(result.draft==nil,'no draft is produced')
    check(result.error and result.error.code=='invalid_document','a typed invalid_document fault')
    check(result.error.input==input,'the fault names the input '..tostring(input)
        ..' (got '..tostring(result.error.input)..')')
    check(result.error.cause==cause,'the fault names the cause '..tostring(cause)
        ..' (got '..tostring(result.error.cause)..')')
    check(calls==0,'zero hash calls for a refused import')
    return result.error
end

-- The scalar-version defect: a scalar (or nil) tuple is cause=not_array.
do
    local c=fresh(); c.assistant.addon_version='2.3.9'
    refused(c,'assistant.addon_version','not_array')
    c=fresh(); c.assistant.tome_version='1.7.4'
    refused(c,'assistant.tome_version','not_array')
    c=fresh(); c.assistant.addon_version=nil
    refused(c,'assistant.addon_version','not_array')
    -- A hole beyond the dense end carries the offending key.
    c=fresh(); c.assistant.addon_version={[1]=2,[2]=3,[4]=9}
    local err=refused(c,'assistant.addon_version','key_beyond_dense_end')
    check(err.key==4,'the sparse version fault names the offending key')
    c=fresh(); c.assistant.addon_version={[1]=2,[2]=3,[3]=9,extra=true}
    refused(c,'assistant.addon_version','non_integer_key')
end

-- cond.all / cond.any before any #/ipairs ------------------------------------
do
    local c=fresh(); c.talents[1].when={all={[1]={hp_pct={lt=70}},[3]={hp_pct={lt=50}}}}
    local err=refused(c,'talents[1].when.all','key_beyond_dense_end')
    check(err.key==3,'the sparse condition fault names the offending key')
    c=fresh(); c.talents[1].when={all='x'}
    refused(c,'talents[1].when.all','not_array')
    c=fresh(); c.talents[1].when={any={[1]={hp_pct={lt=70}},[1.5]={hp_pct={lt=50}}}}
    refused(c,'talents[1].when.any','non_integer_key')
    -- Nested: a malformed array deeper in the tree still terminates the import.
    c=fresh(); c.talents[1].when={all={{all={[1]={hp_pct={lt=70}},[4]={hp_pct={lt=50}}}},{always={}}}}
    refused(c,'talents[1].when.all[1].all','key_beyond_dense_end')
end

-- config.sustains / config.talents before any #/ipairs -----------------------
do
    local c=fresh(); c.sustains={[1]={talent='T_CHANT_OF_FORTRESS'},[3]={talent='T_CHANT_OF_FORTRESS'}}
    refused(c,'sustains','key_beyond_dense_end')
    c=fresh(); c.talents={[1]=c.talents[1],[3]=c.talents[2]}
    refused(c,'talents','key_beyond_dense_end')
    c=fresh(); c.talents='nope'
    refused(c,'talents','not_array')
    c=fresh(); c.sustains={1,2,[5]=3}
    refused(c,'sustains','key_beyond_dense_end')
end

-- The whole import is refused: no draft, no hash, no store -------------------
do
    local svc=Service.new()
    local c=fresh(); c.assistant.addon_version='2.3.9'
    local result=Service.handle(svc,'import_assistant',{config=c,store=true})
    check(result.ok==false and result.error.code=='invalid_document',
        'the service refuses a malformed import with the typed fault')
    check(svc.store.draft==nil and svc.store.approved==nil and svc.store.running==nil,
        'a refused import stores nothing')
    check(svc.revision==0,'a refused import does not advance the revision')
    -- A valid import still works and stores on request.
    local good=Service.handle(svc,'import_assistant',{config=fresh(),store=true})
    check(good.ok==true and good.imported==true,'a valid import still succeeds')
    check(svc.store.draft~=nil,'a valid import stores on explicit request')
    check(result.error.details and result.error.details.input=='assistant.addon_version',
        'the service refusal still names the offending input')
end

-- Raw-path unreachability: the hash choke point rejects an unowned policy ----
do
    local good=Adapter.translate(fresh())
    check(good.ok==true,'the valid export translates')
    check(Adapter.hashPolicy(good.draft)==PINNED_HASH,
        'an imported draft hashes to the pinned content hash')
    check(Adapter.isOwnedPolicy(good.draft),'the imported draft is registered as owned')
    -- A raw policy table cannot be hashed by the choke point.
    local raw={schema=Schema.SCHEMA,id='x',name='x',
        limits={max_actions_per_tick=1},safety={},targeting={default='nearest_hostile'},
        sustains={},rules={{id='r',priority=1,when={always={}},
            ['then']={action='attack'}}}}
    local ok=pcall(Adapter.hashPolicy,raw)
    check(ok==false,'a raw table is not hashable through the choke point')
end

-- Round-trip: the valid import keeps the pre-change hash ---------------------
do
    local result=Adapter.translate(fresh())
    check(result.ok==true,'the pinned export imports')
    check(result.draft.__mcp_owned_policy==nil,'ownership is not stored on the policy bytes')
    check(Schema.hash(result.draft)==PINNED_HASH,
        'the raw schema hash matches the pinned content hash (before == after)')
    check(result.hash==PINNED_HASH,
        'the importer still reports the pinned content hash')
    -- Determinism.
    check(Adapter.translate(fresh()).hash==PINNED_HASH,'translation stays deterministic')
end

-- XPS1-REV-01: the agent-facing policy sinks require the owned form -----------
-- Chosen mechanism (stated): RE-CONSTRUCT at the sink. The reviewer's
-- reproductions (raw_validate/raw_set_draft/raw_dry_run) succeed only AFTER
-- validation+ownership transfer; a malformed-but-JSON-encodable policy is
-- never hashed/evaluated/stored.
do
    local svc=Service.new()
    -- The reviewer's malformed condition container: JSON-encodable, passes the
    -- old weak array test, used to hash/store/evaluate as an EMPTY `all`.
    local bad={schema=Schema.SCHEMA,id='bad',name='bad',
        limits={max_actions_per_tick=1},safety={},targeting={default='nearest_hostile'},
        sustains={},rules={{id='r',priority=1,when={all={hidden={always={}}}},
            ['then']={action='attack'}}}}
    local function noHash()
        local calls=0
        local real=Schema.hash
        Schema.hash=function(...) calls=calls+1; return real(...) end
        return function() Schema.hash=real; return calls end
    end
    local done=noHash()
    local v=Service.handle(svc,'validate',{policy=bad})
    check(v.ok==false and v.error.code=='invalid_policy',
        'a malformed-JSON policy is refused at validate')
    check(done()==0,'a refused validate performs zero hash calls')
    local sd=Service.handle(svc,'set_draft',{policy=bad})
    check(sd.ok==false,'a malformed-JSON policy is refused at set_draft')
    local dr=Service.handle(svc,'dry_run',{policy=bad})
    check(dr.ok==false,'a malformed-JSON policy is refused at dry_run')
    check(svc.store.draft==nil and svc.revision==0,
        'a malformed-JSON policy is never stored and never advances the revision')
    -- A round-tripped VALID policy keeps working through the chosen path:
    -- serialize the imported draft, decode it fresh (ownership is gone), and
    -- the sinks re-construct (validate+copy) it instead of refusing it.
    local imported=Service.handle(svc,'import_assistant',{config=fresh()})
    check(imported.ok==true,'the valid import succeeds')
    local encoded=Json.encode(imported.draft)
    local decoded=Json.decode(encoded)
    check(decoded~=imported.draft and not Adapter.isOwnedPolicy(decoded),
        'a round-tripped policy is a fresh unregistered table (the reviewer scenario)')
    local rv=Service.handle(Service.new(),'validate',{policy=decoded})
    check(rv.ok==true and rv.hash==PINNED_HASH,
        'a round-tripped valid policy validates after re-ownership')
    local rsd=Service.handle(svc,'set_draft',{policy=decoded})
    check(rsd.ok==true and rsd.draft_hash==PINNED_HASH,
        'a round-tripped valid policy still stores')
    -- The stored draft is a private copy: a later mutation of the caller's
    -- decoded table cannot change what was stored (hash unchanged).
    decoded.name='RENAMED AFTER STORE'
    check(Service.handle(svc,'get').draft_hash==PINNED_HASH,
        'mutating the caller table after set_draft cannot change the stored draft')
    -- The re-constructed dry_run path evaluates the owned copy (a fresh
    -- round-trip decode, since the earlier mutation above is on the caller's
    -- table and must not reach the store).
    local rdr=Service.handle(Service.new{dry_run_host_factory=function()
        return {snapshot=function() return {} end} end},
        'dry_run',{policy=Json.decode(encoded)})
    check(rdr.ok==true and rdr.policy_hash==PINNED_HASH,
        'a round-tripped valid policy dry-runs after re-ownership')
end

-- XPS1-REV-02: identity proves history, not the current value -----------------
do
    local draft=assert(Adapter.translate(fresh()).draft)
    check(Adapter.isOwnedPolicy(draft) and Adapter.hashPolicy(draft)==PINNED_HASH,
        'a freshly adopted draft is owned and hashes to the pinned hash')
    -- A schema-VALID but content-changing mutation changes the accepted hash no
    -- longer: the recorded content hash refuses it (the reviewer measured
    -- 2836a530 -> ffffffffa376ac6c while keeping owned identity).
    local original=draft.name
    draft.name=original..' MUTATED'
    local owned,err=Adapter.ownPolicy(draft,'set_draft')
    check(owned==nil and err.code=='policy_mutated',
        'a mutated owned policy is refused typed at the sink')
    check(err.input=='set_draft' and err.cause=='owned_policy_changed',
        'the mutation refusal names the sink and the cause')
    check(err.expected==PINNED_HASH,'the mutation refusal names the recorded hash')
    local okHash=pcall(Adapter.hashPolicy,draft)
    check(okHash==false,'the hash choke point also refuses a mutated owned policy')
    -- Restoring the exact value restores the hash: the registry then certifies
    -- the CURRENT value again (this is the re-validation contract).
    draft.name=original
    check(Adapter.ownPolicy(draft,'set_draft')==draft,
        'an owned policy whose value matches the recorded hash still passes')
    -- The A/B guarantee: mutating the CALLER's own table after set_draft cannot
    -- change the stored draft (the sink stored its own private copy).
    local svc=Service.new()
    local decoded=Json.decode(Json.encode(assert(Adapter.translate(fresh()).draft)))
    local sd=Service.handle(svc,'set_draft',{policy=decoded})
    check(sd.ok==true,'the raw policy stores through the re-construct gate')
    rawset(decoded.rules[1],'priority',9999)
    check(Service.handle(svc,'get').draft_hash==PINNED_HASH,
        'a post-store caller mutation cannot change the stored draft')
end

-- XPS1-REV-03: malformed ELEMENTS refuse the whole import ---------------------
do
    local c=fresh(); c.talents[1]='MALFORMED'
    local err=refused(c,'talents','invalid_element')
    check(err.key==1,'the malformed talent element fault names the offending index')
    c=fresh(); c.sustains[1]='MALFORMED'
    refused(c,'sustains','invalid_element')
    c=fresh(); c.sustains[2]=Json.null
    err=refused(c,'sustains','invalid_element')
    check(err.key==2,'a json.null element is also a malformed element')
    -- The service refuses the same way: no hash, no draft, no store, no
    -- revision advance.
    local svc=Service.new()
    c=fresh(); c.talents[1]='MALFORMED'
    local calls=0
    local real=Schema.hash
    Schema.hash=function(...) calls=calls+1; return real(...) end
    local result=Service.handle(svc,'import_assistant',{config=c,store=true})
    Schema.hash=real
    check(result.ok==false and result.error.code=='invalid_document',
        'the service refuses a malformed element with the typed fault')
    check(result.error.details and result.error.details.cause=='invalid_element'
        and result.error.details.key==1,'the service refusal names the element and index')
    check(calls==0 and svc.store.draft==nil and svc.revision==0,
        'a malformed element performs zero hash calls and stores nothing')
    -- A condition nested beyond the hard depth refuses with the TYPED fault
    -- (code+input+cause+key) instead of degrading to nil/empty string.
    local deep={always={}}
    for _=1,10 do deep={all={deep}} end
    c=fresh(); c.talents[1].when=deep
    local expected='talents[1].when'
    for _=1,9 do expected=expected..'.all[1]' end
    local done=refused(c,expected,'condition_too_deep')
    check(done.key==9,'the depth fault carries the offending depth as its key')
    local svc2=Service.new()
    local deep_result=Service.handle(svc2,'import_assistant',{config=c,store=true})
    check(deep_result.ok==false and deep_result.error.code=='invalid_document'
        and deep_result.error.details and deep_result.error.details.cause=='condition_too_deep',
        'the service deep-condition refusal carries the typed cause')
    check(svc2.store.draft==nil and svc2.revision==0,
        'the deep-condition refusal stores nothing')
end

print('Owned import (X-prime slice 1): '..checks..' checks passed')
