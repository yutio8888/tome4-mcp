-- S3 canonical REAL raised-spec fixtures (Designer plan §7.1; binding).
--
-- Every S3 test names one of these four fixtures; NO test may hand-author a
-- different shape/flag table. The headless layer uses curated exact copies of
-- the action-local/target-builder tables (there is no callable builder for an
-- action-local spec), each labelled with the source lines it is copied from.
--
-- The raw presence map is asserted SEPARATELY from the normalized defaults so
-- an omitted projection flag can never be mistaken for an explicit false
-- (D4/G-U6/X-N1). `presence[key]~=nil` means the raw raised spec carries the
-- key with that exact value; `presence[key]==nil` means the key is ABSENT in
-- the real source (its normalized value comes from Target:getType defaults).
local M={}
M.SCHEMA='s3-real-spec-fixtures/v1'

local D3_FLAGS={'friendlyblock','friendlyfire','selffire','pass_terrain',
    'no_restrict','actorblock','stop_block'}

-- REAL_SHADOWSTEP_TG — cunning/shadow-magic.lua:123:
--   `target = function(self, t) return {type="hit", range=self:getTalentRange(t), talent=t} end`
-- Raw `friendlyblock`/`friendlyfire`/`selffire` are ABSENT; Target:getType
-- normalizes selffire/friendlyfire to true (engine/Target.lua:676-695).
M.REAL_SHADOWSTEP_TG={
    source='cunning/shadow-magic.lua:123',
    fields={type='hit',range=6},
    -- `talent=t` is the live definition table in the source; the curated
    -- headless copy keeps the KEY present with the definition placeholder so
    -- the raw key set matches the real raised spec.
    raw_presence={},
    normalized={selffire=true,friendlyfire=true},
    build=function()
        return {type='hit',range=6,talent='T_SHADOWSTEP'}
    end,
}

-- REAL_GIANT_LEAP_TG — uber/str.lua:38-40:
--   `target = function(self, t)
--        return {type="ball", range=self:getTalentRange(t), selffire=false, radius=self:getTalentRadius(t)}`
-- The same tg is reused for canProject AND the post-move projection
-- (uber/str.lua:42-45,63-71). `friendlyfire` and `friendlyblock` are ABSENT.
M.REAL_GIANT_LEAP_TG={
    source='uber/str.lua:38-40',
    fields={type='ball',range=10,selffire=false,radius=1},
    raw_presence={selffire=false},
    normalized={selffire=false,friendlyfire=true},
    build=function()
        return {type='ball',range=10,selffire=false,radius=1}
    end,
}

-- REAL_VAULT_ACTOR_TG — techniques/agility.lua:92-93 (prompt one, the attacked
-- actor): raw shape {type='hit',range=1}; no SF/FF/friendlyblock keys.
M.REAL_VAULT_ACTOR_TG={
    source='techniques/agility.lua:92-93',
    fields={type='hit',range=1},
    raw_presence={},
    normalized={selffire=true,friendlyfire=true},
    build=function()
        return {type='hit',range=1}
    end,
}

-- REAL_VAULT_LANDING_TG — the ACTION-LOCAL table at techniques/agility.lua:117-121:
--   `local tg = {type="hit", nolock=true, range=t.getDist(self,t)}`
-- There is no callable builder for it; the curated exact copy IS the real test
-- shape in every layer (D4/plan §11.4), and the live observed prompt is
-- compared against it.
M.REAL_VAULT_LANDING_TG={
    source='techniques/agility.lua:117-121',
    fields={type='hit',nolock=true,range=3},
    raw_presence={nolock=true},
    normalized={selffire=true,friendlyfire=true},
    build=function()
        return {type='hit',nolock=true,range=3}
    end,
}

M.FIXTURES={REAL_SHADOWSTEP_TG=M.REAL_SHADOWSTEP_TG,
    REAL_GIANT_LEAP_TG=M.REAL_GIANT_LEAP_TG,
    REAL_VAULT_ACTOR_TG=M.REAL_VAULT_ACTOR_TG,
    REAL_VAULT_LANDING_TG=M.REAL_VAULT_LANDING_TG}

-- Assert the RAW presence map of a spec copy against the fixture: a fixture
-- key with a non-nil expected value must be PRESENT and EQUAL; a fixture key
-- that is nil must be ABSENT (presence-explicit, never conflated with false).
function M.assertRawPresence(fixture,spec,message)
    assert(type(fixture)=='table' and type(spec)=='table','assertRawPresence: bad fixture/spec')
    for _,flag in ipairs(D3_FLAGS) do
        local expected=fixture.raw_presence and fixture.raw_presence[flag]
        if expected~=nil then
            assert(spec[flag]==expected,(message or fixture.source)
                ..': raw flag '..flag..' must be present and equal')
        else
            assert(spec[flag]==nil,(message or fixture.source)
                ..': raw flag '..flag..' must be ABSENT, not explicit false')
        end
    end
    return true
end

-- Every value in `fields` must be present and equal in the spec copy; the
-- normalized Target:getType defaults are checked separately from raw presence.
function M.assertFields(fixture,spec,message)
    for key,value in pairs(fixture.fields) do
        assert(spec[key]==value,(message or fixture.source)..': field '..key..' must match')
    end
    return true
end

return M
