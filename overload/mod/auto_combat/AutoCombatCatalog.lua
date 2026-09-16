-- GPL-3.0-or-later. Capability catalogue for the frozen P1a talent whitelist.
--
-- The schema already restricts names to the whitelist; the catalogue adds the
-- semantic compatibility a policy validator must also check (a self-only talent
-- cannot target a hostile, a sustain is not a rule action, ...). Static data
-- only: nothing here calls the engine or the talent itself.
local M={}
M.ENTRIES={
    T_CHANT_OF_FORTRESS={kind='sustain',target='self',resource='positive'},
    T_HYMN_OF_SHADOWS={kind='sustain',target='self',resource='negative'},
    T_HEALING_LIGHT={kind='heal',target='self',resource='positive'},
    T_BARRIER={kind='buff',target='self',resource='positive'},
    T_TWILIGHT={kind='buff',target='self',resource='negative'},
    T_MOONLIGHT_RAY={kind='attack',target='hostile',shape='beam',resource='negative',
        friendlyfire_risk='line'},
    T_SEARING_LIGHT={kind='attack',target='hostile',shape='ball',resource='positive',
        friendlyfire_risk='area'},
    T_ATTACK={kind='attack',target='hostile',shape='hit'},
}
M.HOSTILE_SELECTORS={nearest_hostile=true,lowest_hp_hostile=true}
M.SELF_SELECTORS={self=true}

function M.supported(talent) return M.ENTRIES[talent]~=nil end
function M.entry(talent) return M.ENTRIES[talent] end
function M.isSustain(talent)
    local entry=M.ENTRIES[talent]; return entry~=nil and entry.kind=='sustain'
end

-- Compatibility check beyond the schema: selector fits the talent's target mode.
function M.verify(policy)
    local errors={}
    for index,rule in ipairs((policy and policy.rules) or {}) do
        local entry=rule['then'] and rule['then'].talent and M.ENTRIES[rule['then'].talent] or nil
        if entry then
            local selector=rule['then'].target or (policy.targeting and policy.targeting.default)
            local path='rules['..index..']'
            if entry.target=='self' and selector~=nil and not M.SELF_SELECTORS[selector] then
                errors[#errors+1]={path=path,code='selector_not_self_only',talent=rule['then'].talent}
            end
            if entry.target=='hostile' and selector~=nil and not M.HOSTILE_SELECTORS[selector] then
                errors[#errors+1]={path=path,code='selector_not_hostile',talent=rule['then'].talent}
            end
        elseif rule['then'] and rule['then'].action=='use_talent' then
            errors[#errors+1]={path='rules['..index..']',code='unsupported_talent',
                talent=rule['then'].talent}
        end
    end
    for index,sustain in ipairs((policy and policy.sustains) or {}) do
        if not M.isSustain(sustain.talent) then
            errors[#errors+1]={path='sustains['..index..']',code='not_a_sustain',talent=sustain.talent}
        end
    end
    if #errors==0 then return true end
    return nil,errors
end

function M.summary()
    local talents={}
    for talent,entry in pairs(M.ENTRIES) do
        talents[#talents+1]={talent=talent,kind=entry.kind,target=entry.target,
            shape=entry.shape,resource=entry.resource,friendlyfire_risk=entry.friendlyfire_risk}
    end
    table.sort(talents,function(a,b) return a.talent<b.talent end)
    return {schema='tome-auto-combat/v1',talents=talents}
end
return M
