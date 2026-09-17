-- V2-5: source-drift detection for the effect manifest.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Drift=require 'mod.auto_combat.EffectManifestDrift'
local Manifest=require 'mod.auto_combat.EffectManifest'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- A deterministic stand-in for md5: length-prefixed content, so any change to
-- a file changes the digest.
local function fakeDigest(text) return string.format('%032x',#text*2654435761 % (2^32)) end
local function reader(files)
    return function(path) return files[path] end
end

local sources={
    schema='tome-effect-manifest-sources/v1',
    game_version='1.7.6',
    engine={target={path='/engine/Target.lua',md5=fakeDigest('target')}},
    talents={T_X={files={{path='/data/t/x.lua',md5=fakeDigest('x')}},line=1}},
}
local files={['/engine/Target.lua']='target',['/data/t/x.lua']='x'}

do
    local ok,reason=Drift.verify(sources,reader(files),fakeDigest,{game_version='1.7.6'})
    check(ok==true,'a matching source table verifies')
    check(reason==nil,'no reason on success')
end
do
    local changed={['/engine/Target.lua']='changed',['/data/t/x.lua']='x'}
    local ok,reason,detail=Drift.verify(sources,reader(changed),fakeDigest,{game_version='1.7.6'})
    check(ok==nil and reason==Drift.REASON,'an engine-source hash change is adapter_source_drift')
    check(type(detail)=='string' and detail:find('Target',1,true)~=nil,'the changed file is identified')
end
do
    local changed={['/engine/Target.lua']='target',['/data/t/x.lua']='shifted'}
    local ok,reason=Drift.verify(sources,reader(changed),fakeDigest,{game_version='1.7.6'})
    check(ok==nil and reason==Drift.REASON,'a talent-source hash change is adapter_source_drift')
end
do
    local ok,reason=Drift.verify(sources,reader({}),fakeDigest,{game_version='1.7.6'})
    check(ok==nil and reason==Drift.REASON,'an unreadable pinned file fails closed')
end
do
    local ok,reason=Drift.verify(sources,reader(files),fakeDigest,{game_version='1.7.5'})
    check(ok==nil and reason==Drift.REASON,'a game-version mismatch is adapter_source_drift')
end
do
    local bad={schema='tome-effect-manifest-sources/v0',engine={},talents={}}
    local ok,reason=Drift.verify(bad,reader(files),fakeDigest,{})
    check(ok==nil and reason==Drift.REASON,'a source-schema mismatch is adapter_source_drift')
end

-- Identity/closure: every entry requires a live definition and a declared
-- target-builder expectation. A missing/unexpected builder (including on a
-- self entry), a distinct closure at the same source/line, and a definition
-- mutation after a cached success all fail closed.
do
    Drift.reset()
    local function builderAt(path,line,marker)
        local lines={}
        for i=1,line-1 do lines[i]='' end
        lines[line]='return function(self,t) return {marker='..marker..'} end'
        local chunk=assert(loadstring(table.concat(lines,'\n'),'@'..path))
        return chunk()
    end
    local manifest={ENTRIES={T_X={conformance={shape='beam',builder=true},
        source={builder={path='/data/x.lua',line=2}}}}}
    local good=builderAt('/data/x.lua',2,1)
    check(Drift.identity(manifest,function() return {target=good} end)==true,
        'the pinned builder satisfies the identity check')
    local replaced=builderAt('/data/x.lua',4,1)
    local bad,reason=Drift.identity(manifest,function() return {target=replaced} end)
    check(bad==nil and reason==Drift.REASON,'a same-type replacement on another line is rejected')
    local otherFile=builderAt('/data/other.lua',2,1)
    local bad2,reason2=Drift.identity(manifest,function() return {target=otherFile} end)
    check(bad2==nil and reason2==Drift.REASON,'a same-type replacement from another file is rejected')
    local sameLine=builderAt('/data/x.lua',2,2)
    local bad3,reason3=Drift.identity(manifest,function() return {target=sameLine} end)
    check(bad3==nil and reason3==Drift.REASON,
        'a distinct closure at the same source/line is rejected')
    local missing,reason4=Drift.identity(manifest,function() return {target={type='beam'}} end)
    check(missing==nil and reason4==Drift.REASON,'a missing builder disables the adapter')
    local noDef,reason5=Drift.identity(manifest,function() return nil end)
    check(noDef==nil and reason5==Drift.REASON,'a missing definition disables the adapter')
    local unexpectedManifest={ENTRIES={T_X={conformance={builder=false}}}}
    local unexpected,reason6=Drift.identity(unexpectedManifest,function() return {target=good} end)
    check(unexpected==nil and reason6==Drift.REASON,'an unexpected builder disables the adapter')
    local undeclared={ENTRIES={T_U={}}}
    local und,reason7=Drift.identity(undeclared,function() return {} end)
    check(und==nil and reason7==Drift.REASON,'an entry without a declared builder expectation is rejected')
    -- A self/no-target entry is inspected too.
    local selfManifest={ENTRIES={T_SELF={conformance={builder='none'}}}}
    Drift.reset()
    check(Drift.identity(selfManifest,function() return {} end)==true,
        'a self entry with no target builder satisfies the identity check')
    local selfMissing,reason8=Drift.identity(selfManifest,function() return nil end)
    check(selfMissing==nil and reason8==Drift.REASON,'a missing self definition is rejected')
    Drift.reset()
    local selfBuilder,reason9=Drift.identity(selfManifest,function() return {target=good} end)
    check(selfBuilder==nil and reason9==Drift.REASON,'an unexpected builder on a self entry is rejected')
end

-- V2-REV-02(3): only immutable hashes are cached; the live identity check runs
-- again on every call, so a mutation after a cached success is caught.
do
    Drift.reset()
    local function builderAt(path,line)
        local lines={}
        for i=1,line-1 do lines[i]='' end
        lines[line]='return function(self,t) return {} end'
        return assert(loadstring(table.concat(lines,'\n'),'@'..path))()
    end
    local manifest={ENTRIES={T_X={conformance={builder=true},
        source={builder={path='/data/x.lua',line=2}}}}}
    local live={T_X={target=builderAt('/data/x.lua',2)}}
    local function getDef(talent) return live[talent] end
    local opts={sources=sources,read=reader(files),digest=fakeDigest,
        expected={game_version='1.7.6'},manifest=manifest,identity=getDef}
    check(Drift.ensure('mutation',opts)==true,'the first live identity check passes')
    live.T_X=nil
    local second,secondReason=Drift.ensure('mutation',opts)
    check(second==false and secondReason==Drift.REASON,
        'a definition mutation after a cached hash success fails closed')
    Drift.reset()
end

-- Missing live hash services are a failure, not a pass.
do
    local ok,reason=Drift.verify(sources,nil,nil,{game_version='1.7.6'})
    check(ok==nil and reason==Drift.REASON,'a missing reader/digest fails closed')
    local ensured,ensured_reason=Drift.ensure('missing-services',{sources=sources,read=nil,digest=nil,
        expected={game_version='1.7.6'}})
    check(ensured==false and ensured_reason==Drift.REASON,
        'ensure reports failure, not success, without hash services')
    Drift.reset()
end

-- The real generated table verifies against the real manifest identity shape.
do
    check(Manifest.SOURCES.schema=='tome-effect-manifest-sources/v1','the live source table schema is valid')
    check(Manifest.SOURCES.game_version==Manifest.GAME_VERSION,'the live source table is pinned to the manifest version')
end

print('Effect manifest drift: '..checks..' checks passed')
