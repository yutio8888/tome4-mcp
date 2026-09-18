-- GPL-3.0-or-later. Native-entrypoint compatibility: DIAGNOSTIC ONLY.
--
-- NO-AUDIT principle (AGENTS.md, design §8.3, factory design §1/§3.1): Lua is
-- dynamic, so any addon may replace any function at runtime. The project neither
-- guarantees nor needs to guarantee that a runtime entry is the pristine native
-- implementation, and is not responsible for other plugins' broken
-- implementations. Callers therefore use the game's actual functions as normal
-- entrypoints.
--
-- This module keeps two independent concerns:
--   * STRUCTURAL availability (`matches`, `available`, `check`): does the
--     entrypoint exist / is it callable / is the bridge's own instrumentation in
--     the expected shape? This is what callers may branch on.
--   * ADVISORY provenance (`identity`, `diagnostic`, `dependencySummary`,
--     `closureSummary`, `providerSummary`, `summary`): the recorded source path,
--     whole-file digest, declaration line, captured-native wrapper chain and
--     dependency closure. These are reported for offline review/telemetry and
--     NEVER gate a decision: a digest/identity mismatch does not make a function
--     unavailable, and a replaced-but-usable function is still returned for use.
local M={}
local entries={}

-- Advisory provenance computation only: never raises, never blocks.
local function provenance(fn,path,digest)
    local info=type(fn)=='function' and debug.getinfo(fn,'S') or nil
    local source_ok=info~=nil and info.source=='@'..path
    local digest_ok=false
    if source_ok then
        local read_ok,data=pcall(function() return fs.readAll(path) end)
        if read_ok and type(data)=='string' then
            local hash_ok,hash=pcall(function() return require('md5').sumhexa(data) end)
            digest_ok=hash_ok and hash==digest
        end
    end
    return {source_ok=source_ok==true,digest_ok=digest_ok==true,
        advisory=(source_ok and digest_ok)~=true}
end

function M.register(name,fn,previous,path,digest,wrapper)
    local record={fn=fn,path=path,name=name}
    -- The released companion's Game wrapper delegates to a captured native
    -- method. Resolving that chain is advisory only.
    local resolved=previous
    local wrapper_ok=nil
    if wrapper then
        local wp=provenance(previous,wrapper.path,wrapper.digest)
        wrapper_ok=wp.advisory==false
        if wrapper_ok then
            for index=1,32 do
                local key,value=debug.getupvalue(previous,index)
                if not key then break end
                if key==wrapper.upvalue then resolved=value;break end
            end
        end
    end
    record.previous=resolved
    record.wrapper_ok=wrapper_ok
    local p=provenance(resolved,path,digest)
    record.source_ok=p.source_ok
    record.digest_ok=p.digest_ok
    if type(fn)~='function' then
        record.structural_ok=false
        record.reason='entrypoint_missing'
    else
        record.structural_ok=true
    end
    entries[name]=record
    return record.structural_ok
end

-- Structural availability: the entrypoint exists and is a function. This is what
-- callers branch on; identity/digest are advisory telemetry.
function M.matches(name,fn)
    return type(fn)=='function'
end

function M.available(name)
    local entry=entries[name]
    return entry~=nil and type(entry.fn)=='function'
end

-- Advisory identity: is `fn` the exact object originally registered under
-- `name`? Reported, never a gate.
function M.identity(name,fn)
    local entry=entries[name]
    local same=entry~=nil and entry.fn==fn
    return {advisory=true,name=name,same_object=same==true,
        registered=entry~=nil,source_ok=entry and entry.source_ok,
        digest_ok=entry and entry.digest_ok,path=entry and entry.path}
end

-- Structural readiness for a native action: the execution seams must be present
-- and callable, and the target must not be force-locked. Identity/digest are not
-- consulted.
function M.check(g)
    if not g or not g.player or type(g.player.useTalent)~='function' then
        return nil,'talent_lifecycle_unavailable'
    end
    if type(g.targetGetForPlayer)~='function' or type(g.targetMode)~='function' then
        return nil,'target_provider_unavailable'
    end
    if type(g.player.getTarget)~='function' then return nil,'player_target_rules_modified' end
    if type(g.player.useEnergy)~='function' then return nil,'native_energy_tracking_unavailable' end
    if not M.available('turnBasedTick') then return nil,'native_scheduler_unavailable' end
    if g.target and g.target.forced then return nil,'native_target_forced' end
    return true
end

-- Read-only helper registry (spec QRY-02), DIAGNOSTIC provenance only. A helper
-- is recorded once with its intended provider id and source, but the live
-- function is always returned for use; a replaced-but-usable helper is used and
-- only an unusable/missing one is unavailable.
local dependencies={}
local function lineAt(text, line)
    if type(line)~='number' or line<1 then return nil end
    local n=0
    for value in (text..'\n'):gmatch('([^\n]*)\n') do
        n=n+1
        if n==line then return value end
    end
end
-- Advisory method provenance: source path + full-file digest + declaration line.
-- Never blocks. A nil/absent path means the caller supplied no provenance, so the
-- record is simply marked advisory.
local function methodProvenance(fn,path,digest,declaration)
    local info=type(fn)=='function' and debug.getinfo(fn,'S') or nil
    local source_ok=info~=nil and type(path)=='string' and info.source=='@'..path
    local digest_ok,declaration_ok=false,false
    if source_ok and type(digest)=='string' and #digest>0 then
        local read_ok,data=pcall(function() return fs.readAll(path) end)
        if read_ok and type(data)=='string' then
            local hash_ok,hash=pcall(function() return require('md5').sumhexa(data) end)
            digest_ok=hash_ok and hash==digest
            if declaration then
                local source_line=lineAt(data,info.linedefined)
                declaration_ok=source_line~=nil and source_line:find(declaration,1,true)~=nil
            end
        end
    end
    local advisory=type(path)~='string' or source_ok~=true or digest_ok~=true
        or (declaration~=nil and declaration_ok~=true)
    return {source_ok=source_ok==true,digest_ok=digest_ok==true,
        declaration_ok=declaration_ok,advisory=advisory}
end
function M.registerDependency(id,domain,fn,path,purpose,digest,declaration,depends_on)
    if type(fn)~='function' then
        dependencies[id]={ok=false,structural_ok=false,reason='dependency_missing',
            domain=domain,path=path,depends_on=depends_on or {}}
        return false
    end
    local existing=dependencies[id]
    local p=methodProvenance(fn,path,digest,declaration)
    dependencies[id]={fn=fn,ok=true,structural_ok=true,domain=domain,path=path,purpose=purpose,
        depends_on=depends_on or {},source_ok=p.source_ok,digest_ok=p.digest_ok,
        declaration_ok=p.declaration_ok,advisory=p.advisory,
        replaced=existing~=nil and existing.fn~=nil and existing.fn~=fn or nil}
    -- Return the live function: provenance is advisory, never a gate.
    return fn
end
-- Return the live function for use. Provenance is advisory; only a non-function
-- (or an unknown id) is unavailable.
function M.dependency(id,fn)
    if type(fn)~='function' then return nil,'dependency_not_registered' end
    local entry=dependencies[id]
    if entry then
        entry.fn=fn
        entry.ok=true
        entry.structural_ok=true
    end
    return fn
end
function M.hasDependency(id) return dependencies[id]~=nil end
function M.resetDependencies() dependencies={} end
local function closureOf(id,seen)
    if seen[id] then return seen[id] end
    local entry=dependencies[id]
    local node={ok=entry~=nil and entry.ok==true or false,reason=entry and entry.reason,domain=entry and entry.domain,
        path=entry and entry.path,purpose=entry and entry.purpose,depends_on={}}
    seen[id]=node
    if entry then
        for _,dep in ipairs(entry.depends_on or {}) do node.depends_on[#node.depends_on+1]=closureOf(dep,seen) end
    end
    return node
end
function M.closureSummary()
    local out={}
    for id,_ in pairs(dependencies) do out[id]=closureOf(id,{}) end
    return out
end
function M.dependencySummary()
    local out={}
    for id,entry in pairs(dependencies) do
        out[id]={ok=entry.ok==true,reason=entry.reason,domain=entry.domain,
            path=entry.path,purpose=entry.purpose,
            source_ok=entry.source_ok,digest_ok=entry.digest_ok,
            declaration_ok=entry.declaration_ok,advisory=entry.advisory==true}
    end
    return out
end
function M.alias(name,fn,parent,previous)
    local entry=entries[parent]
    entries[name]={fn=fn,structural_ok=type(fn)=='function',
        parent=parent,path=entry and entry.path}
end
local domainFor
function M.providerSummary()
    local out={}
    for name,entry in pairs(entries) do
        local state=type(entry.fn)=='function' and 'present'
            or 'unavailable'
        out[#out+1]={provider_id=name,domain=domainFor(name),state=state,
            reason=entry.reason,source=entry.path,
            source_ok=entry.source_ok,digest_ok=entry.digest_ok,
            advisory=entry.advisory==true,
            effect=type(entry.fn)=='function' and nil or (name..' capability unavailable')}
    end
    for name,entry in pairs(dependencies) do
        out[#out+1]={provider_id=name,domain=entry.domain or domainFor(name),
            state=type(entry.fn)=='function' and 'present' or 'unavailable',
            reason=entry.reason,source=entry.path,
            source_ok=entry.source_ok,digest_ok=entry.digest_ok,
            advisory=entry.advisory==true,
            effect=type(entry.fn)=='function' and nil or (name..' query field becomes unknown')}
    end
    table.sort(out,function(a,b) return a.provider_id<b.provider_id end)
    return out,true
end
-- Domain classification for diagnostics (CMP-01/02). Not a security boundary.
local DOMAINS = {
    useTalent='talent_execution', targetGetForPlayer='interactions', targetMode='interactions',
    playerGetTarget='talent_execution', playerUseEnergy='scheduler', turnBasedTick='scheduler',
    playerFOV='observation', computeFOV='observation', restInit='native_tasks', restStop='native_tasks',
    restStopAlias='native_tasks', yesnoPopup='interactions', yesnoLongPopup='interactions',
    listPopup='interactions', ['TomeChat.init']='interactions', ['TomeChat.makeUI']='interactions',
    changeLevelReal='scheduler',
}
function domainFor(name)
    if DOMAINS[name] then return DOMAINS[name] end
    if name:match('^map%.') then return 'observation' end
    if name:match('^object%.') or name:match('^ShowInventory%.') or name:match('^ShowEquipInven%.') then return 'items' end
    if name:match('Popup%.') or name:match('Lore') or name:match('Quest') then return 'interactions' end
    if name:match('^actor%.') or name:match('^resource%.') or name:match('^query%.') then return 'talent_query' end
    return 'native'
end
function M.summary()
    local providers=select(1,M.providerSummary())
    return {scope='diagnostic-only compatibility record: structural availability plus advisory source/digest/declaration/wrapper provenance and dependency closure; nothing here gates a decision',
        capture_complete=true,providers=providers,dependencies=M.dependencySummary(),closures=M.closureSummary()}
end
return M
