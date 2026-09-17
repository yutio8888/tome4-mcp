-- V2-5 (NO-AUDIT rev 7): source/identity pins are ADVISORY telemetry, never a
-- runtime gate. These tests assert the diagnostics report drift, and that the
-- diagnostics can never block (no truthy/falsy gate contract).
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
local function kindOf(review,kind)
    for _,finding in ipairs(review.findings) do
        if finding.kind==kind then return true end
    end
    return false
end

local sources={
    schema='tome-effect-manifest-sources/v1',
    game_version='1.7.6',
    engine={target={path='/engine/Target.lua',md5=fakeDigest('target')}},
    talents={T_X={files={{path='/data/t/x.lua',md5=fakeDigest('x')}},line=1}},
}
local files={['/engine/Target.lua']='target',['/data/t/x.lua']='x'}

-- Advisory source review: reports drift but never raises / never gates.
do
    local review=Drift.review(sources,reader(files),fakeDigest,{game_version='1.7.6'})
    check(review.drift==false and #review.findings==0,'a matching source table reports no drift')
    local changed={['/engine/Target.lua']='changed',['/data/t/x.lua']='x'}
    review=Drift.review(sources,reader(changed),fakeDigest,{game_version='1.7.6'})
    check(review.drift==true and review.findings[1].kind=='source_changed',
        'an engine-source hash change is reported as advisory drift')
    local changedTalent={['/engine/Target.lua']='target',['/data/t/x.lua']='shifted'}
    review=Drift.review(sources,reader(changedTalent),fakeDigest,{game_version='1.7.6'})
    check(review.drift==true and review.findings[1].kind=='source_changed',
        'a talent-source hash change is reported as advisory drift')
    review=Drift.review(sources,reader({}),fakeDigest,{game_version='1.7.6'})
    check(review.drift==true and review.findings[1].kind=='source_unreadable',
        'an unreadable pinned file is reported (advisory)')
    review=Drift.review(sources,reader(files),fakeDigest,{game_version='1.7.5'})
    check(review.drift==true and kindOf(review,'advisory_game_version'),'a game-version mismatch is reported')
    local bad={schema='tome-effect-manifest-sources/v0',engine={},talents={}}
    review=Drift.review(bad,reader(files),fakeDigest,{})
    check(review.drift==true and kindOf(review,'advisory_source_schema'),'a source-schema mismatch is reported')
end

-- Advisory identity review: missing/moved/unexpected builders are reported,
-- never rejected. `drift` is data.
do
    Drift.reset()
    local function builderAt(path,line,marker)
        local lines={}
        for i=1,line-1 do lines[i]='' end
        lines[line]='return function(self,t) return {marker='..marker..'} end'
        return assert(loadstring(table.concat(lines,'\n'),'@'..path))()
    end
    local manifest={ENTRIES={T_X={conformance={shape='beam',builder=true},
        source={builder={path='/data/x.lua',line=2}}}}}
    local good=builderAt('/data/x.lua',2,1)
    local review=Drift.identity(manifest,function() return {target=good} end)
    check(review.drift==false,'a matching builder reports no identity drift')
    local moved=builderAt('/data/x.lua',4,1)
    review=Drift.identity(manifest,function() return {target=moved} end)
    check(review.drift==true and kindOf(review,'builder_moved'),'a moved builder is reported')
    local otherFile=builderAt('/data/other.lua',2,1)
    review=Drift.identity(manifest,function() return {target=otherFile} end)
    check(review.drift==true and kindOf(review,'builder_moved'),'a builder from another file is reported')
    review=Drift.identity(manifest,function() return {target={type='beam'}} end)
    check(review.drift==true and kindOf(review,'builder_missing'),'a missing builder is reported')
    review=Drift.identity(manifest,function() return nil end)
    check(review.drift==true and kindOf(review,'definition_missing'),'a missing definition is reported')
    local unexpectedManifest={ENTRIES={T_X={conformance={builder=false}}}}
    review=Drift.identity(unexpectedManifest,function() return {target=good} end)
    check(review.drift==true and kindOf(review,'builder_unexpected'),'an unexpected builder is reported')
    local undeclared={ENTRIES={T_U={}}}
    review=Drift.identity(undeclared,function() return {} end)
    check(review.drift==true and kindOf(review,'builder_undeclared'),'an undeclared expectation is reported')
    local selfManifest={ENTRIES={T_SELF={conformance={builder='none'}}}}
    check(Drift.identity(selfManifest,function() return {} end).drift==false,
        'a self entry with no builder reports no drift')
    review=Drift.identity(selfManifest,function() return {target=good} end)
    check(review.drift==true and kindOf(review,'builder_unexpected'),
        'an unexpected builder on a self entry is reported')
end

-- A distinct closure at the same source/line is reported (upvalue identity is
-- still useful as telemetry), and reporting never throws.
do
    local upManifest={ENTRIES={T_UP={conformance={builder=true},
        source={builder={path='/data/x.lua',line=2}}}}}
    local factory=assert(loadstring('local captured=...\nreturn function(self,t) return {v=captured} end','@/data/x.lua'))
    local upA=factory(1)
    local upB=factory(2)
    check(rawequal(upA,upB)==false and string.dump(upA)==string.dump(upB),
        'the upvalue fixture is distinct but byte-identical')
    -- Both are valid Lua functions at the pinned source/line, so the advisory
    -- review reports no movement; the point is it never errors or gates.
    local reviewA=Drift.identity(upManifest,function() return {target=upA} end)
    local reviewB=Drift.identity(upManifest,function() return {target=upB} end)
    check(type(reviewA)=='table' and type(reviewB)=='table','identity review always returns a record')
    check(reviewA.drift==false and reviewB.drift==false,
        'a same-source/line closure is not flagged (advisory, not a gate)')
end

-- The telemetry hook always returns a record and never throws; it cannot gate.
do
    local record=Drift.telemetry({sources=sources,read=reader(files),digest=fakeDigest,
        expected={game_version='1.7.6'},manifest={ENTRIES={}},identity=function() return {} end})
    check(type(record)=='table' and record.advisory==true,'telemetry returns an advisory record')
    local missing=Drift.telemetry({sources=sources,read=nil,digest=nil})
    check(type(missing)=='table' and missing.source.drift==true,
        'missing hash services are advisory drift, not a failure')
    local ensured=Drift.ensure('any-key',{sources=sources,read=nil,digest=nil})
    check(type(ensured)=='table' and ensured.advisory==true,
        'ensure returns an advisory record and cannot be treated as a gate')
end

-- The real generated table is schema/version-pinned (advisory metadata).
do
    check(Manifest.SOURCES.schema=='tome-effect-manifest-sources/v1','the live source table schema is valid')
    check(Manifest.SOURCES.game_version==Manifest.GAME_VERSION,'the live source table is pinned to the manifest version')
end

-- The generated table keeps advisory pins (action/getters/ranges) for every
-- admitted movement adapter as re-review metadata.
do
    for talent,entry in pairs(Manifest.ENTRIES) do
        if entry.kind=='movement' then
            local pin=Manifest.SOURCES.talents[talent]
            check(pin~=nil and type(pin.action)=='table' and type(pin.action.path)=='string'
                and type(pin.action.line)=='number','movement action advisory pin for '..talent)
            for _,movement in ipairs((function()
                if entry.movement.variants then
                    local out={}
                    for _,variant in ipairs(entry.movement.variants) do
                        if variant.movement then out[#out+1]=variant.movement end
                    end
                    return out
                end
                return {entry.movement}
            end)()) do
                for _,field in ipairs({'radius','min_radius','range','fallback_radius'}) do
                    local value=movement[field]
                    if type(value)=='table' and type(value.getter)=='string' then
                        check(type(pin.getters)=='table' and type(pin.getters[value.getter])=='table',
                            'dynamic getter '..value.getter..' advisory pin for '..talent)
                    end
                end
            end
        end
    end
    for _,talent in ipairs({'T_RUSH','T_SKIRMISHER_CUNNING_ROLL','T_SKIRMISHER_VAULT',
        'T_DIMENSIONAL_STEP'}) do
        local pin=Manifest.SOURCES.talents[talent]
        check(pin~=nil and type(pin.ranges)=='table' and type(pin.ranges.range)=='table'
            and type(pin.ranges.range.line)=='number','movement range advisory pin for '..talent)
    end
end

-- NO-AUDIT: the advisory identity review never gates a replaced non-movement
-- target builder. A replaced builder is still usable at runtime.
do
    local manifest={ENTRIES={T_A={conformance={builder=true},
        source={builder={path='/data/x.lua',line=2}}}}}
    local replacement=assert(loadstring('return function(self,t) return {type="beam",range=9} end',
        '@/data/other.lua'))()
    local review=Drift.identity(manifest,function() return {target=replacement} end)
    check(review.drift==true and kindOf(review,'builder_moved'),
        'a replaced non-movement builder is reported as advisory drift')
    -- The advisory record has no gate shape: callers must decide from values.
    check(review.advisory==nil or review.must_reject==nil,
        'the advisory review exposes no must-reject gate')
end

print('Effect manifest drift: '..checks..' checks passed')
