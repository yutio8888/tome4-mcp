-- GPL-3.0-or-later. Compatibility concerns native entrypoints, never talent IDs.
local M={}
local entries={}
local function audited(fn,path,digest)
    local info=type(fn)=='function' and debug.getinfo(fn,'S')
    local ok=info and info.source=='@'..path
    if ok then
        local read_ok,data=pcall(function() return fs.readAll(path) end)
        local hash_ok,hash=pcall(function() return require('md5').sumhexa(data or '') end)
        ok=read_ok and hash_ok and hash==digest
    end
    return ok==true
end

function M.register(name,fn,previous,path,digest,wrapper)
    -- The released companion's Game wrapper stops its controller and then
    -- delegates to a captured native method. Audit both complete files and
    -- the captured function; unknown wrappers still fail closed.
    if wrapper and audited(previous,wrapper.path,wrapper.digest) then
        for index=1,32 do
            local key,value=debug.getupvalue(previous,index)
            if not key then break end
            if key==wrapper.upvalue then previous=value;break end
        end
    end
    local ok=audited(previous,path,digest)
    entries[name]={fn=fn,ok=ok,reason=ok and nil or 'native_entrypoint_modified'}
end

function M.matches(name,fn)
    local entry=entries[name]
    return entry and entry.ok and entry.fn==fn or false
end

function M.check(g)
    if not g or not g.player or not M.matches('useTalent',g.player.useTalent) then
        return nil,'talent_lifecycle_unavailable'
    end
    if not M.matches('targetGetForPlayer',g.targetGetForPlayer)
        or not M.matches('targetMode',g.targetMode) then return nil,'target_provider_unavailable' end
    if not M.matches('playerGetTarget',g.player.getTarget) then return nil,'player_target_rules_modified' end
    if not M.matches('playerUseEnergy',g.player.useEnergy) then return nil,'native_energy_tracking_unavailable' end
    if not M.available('turnBasedTick') then return nil,'native_scheduler_unavailable' end
    if g.target and g.target.forced then return nil,'native_target_forced' end
    return true
end

function M.available(name) return entries[name] and entries[name].ok or false end

-- Read-only dependency registry (spec QRY-02). Query helpers such as a cost
-- factor or an attribute getter are registered once with their intended
-- provider id and source. A later replacement of the same key fails closed:
-- the query field becomes unknown and the replacement is never called.
-- File-digest unification with the entrypoint audit above is M4 (CMP-01/03).
local dependencies={}
-- A line of a source text, 1-indexed; nil when out of range.
local function lineAt(text, line)
    if type(line)~='number' or line<1 then return nil end
    local n=0
    for value in (text..'\n'):gmatch('([^\n]*)\n') do
        n=n+1
        if n==line then return value end
    end
end
-- A read-only dependency must come from the audited file (source path + full
-- file digest) and, when a declaration is given, be defined on the expected
-- line of that file. A runtime function that merely reuses the source tag is
-- rejected, so a first-seen override is never trusted (spec QRY-02, F1).
local function auditedMethod(fn,path,digest,declaration)
    local info=type(fn)=='function' and debug.getinfo(fn,'S')
    if not info or info.source~='@'..path then return false,'dependency_source_unverified' end
    local read_ok,data=pcall(function() return fs.readAll(path) end)
    if not read_ok or type(data)~='string' then return false,'dependency_source_unreadable' end
    local hash_ok,hash=pcall(function() return require('md5').sumhexa(data) end)
    if not hash_ok or hash~=digest then return false,'dependency_source_modified' end
    if declaration then
        local source_line=lineAt(data,info.linedefined)
        if not source_line or not source_line:find(declaration,1,true) then
            return false,'dependency_body_unverified'
        end
    end
    return true
end
function M.registerDependency(id,domain,fn,path,purpose,digest,declaration)
    if type(fn)~='function' then
        dependencies[id]={ok=false,reason='dependency_missing',domain=domain,path=path}
        return false
    end
    local existing=dependencies[id]
    if existing and existing.fn and existing.fn~=fn then
        dependencies[id]={fn=fn,ok=false,reason='dependency_replaced',domain=domain,path=path}
        return false
    end
    -- No digest means the dependency was not audited: fail closed instead of
    -- marking an arbitrary current function as trusted.
    local ok,reason=false,'dependency_not_audited'
    if type(digest)=='string' and #digest>0 then
        ok,reason=auditedMethod(fn,path,digest,declaration)
    end
    dependencies[id]={fn=fn,ok=ok,reason=ok and nil or reason,domain=domain,path=path,purpose=purpose}
    return ok
end
function M.dependency(id,fn)
    if type(fn)~='function' then return nil,'dependency_not_registered' end
    local entry=dependencies[id]
    if not entry or not entry.ok then return nil,entry and entry.reason or 'dependency_not_registered' end
    if fn~=entry.fn then
        entry.ok=false;entry.reason='dependency_replaced'
        return nil,'dependency_replaced'
    end
    return fn,entry.reason
end
function M.hasDependency(id) return dependencies[id]~=nil end
function M.resetDependencies() dependencies={} end
function M.dependencySummary()
    local out={}
    for id,entry in pairs(dependencies) do
        out[id]={ok=entry.ok==true,reason=entry.reason,domain=entry.domain,
            path=entry.path,purpose=entry.purpose}
    end
    return out
end
function M.alias(name,fn,parent,previous)
    local entry=entries[parent]
    entries[name]={fn=fn,ok=entry and entry.ok and previous==entry.fn or false}
end
function M.providerSummary()
    local out={}
    for name,entry in pairs(entries) do
        out[#out+1]={provider_id=name,state=entry.ok and 'verified' or 'unverified',reason=entry.reason}
    end
    table.sort(out,function(a,b) return a.provider_id<b.provider_id end)
    return out,true
end
return M
