-- GPL-3.0-or-later. Capability catalogue for the frozen P1a talent whitelist.
--
-- The schema already restricts names to the whitelist; the catalogue adds the
-- semantic compatibility a policy validator must also check (a self-only talent
-- cannot target a hostile, a sustain is not a rule action, ...). Static data
-- only: nothing here calls the engine or the talent itself.
local M={}
-- Version-pinned adapter catalogue. The executor guard re-checks these entries
-- immediately before native execution; the version is reported in capabilities.
M.VERSION='tome-auto-combat-adapters/v1'
M.ENTRIES={
    T_CHANT_OF_FORTRESS={kind='sustain',target='self',resource='positive'},
    T_HYMN_OF_SHADOWS={kind='sustain',target='self',resource='negative'},
    T_HEALING_LIGHT={kind='heal',target='self',resource='positive'},
    T_BARRIER={kind='buff',target='self',resource='positive'},
    T_TWILIGHT={kind='buff',target='self',resource='negative'},
    T_MOONLIGHT_RAY={kind='attack',target='hostile',shape='beam',range=10,resource='negative',
        friendlyfire_risk='line'},
    -- Design §5.7: Searing Light's damage is a single `hit` plus a ground light
    -- field with selffire/friendlyfire false; the ball cursor is aiming only.
    T_SEARING_LIGHT={kind='attack',target='hostile',shape='hit',range=10,resource='positive',
        direct_hit=true,friendlyfire_risk='none'},
    T_ATTACK={kind='attack',target='hostile',shape='hit',range=1},
    -- P2 second pilot: Sun Paladin (celestial/sun + celestial/light).
    T_SUN_BEAM={kind='attack',target='hostile',shape='hit',range=7,resource='positive'},
    T_WEAPON_OF_LIGHT={kind='sustain',target='self',resource='positive'},
    -- P2 third/seventh pilots (round 4). Source-verified from the game talent data.
    -- Archmage (spell/arcane + spell/fire + spell/aegis).
    -- Flame is a bolt below talent level 5 and a beam at/above it; the beam
    -- descriptor is the conservative superset (the guard checks the line).
    T_FLAME={kind='attack',target='hostile',shape='beam',range=10,resource='mana',
        friendlyfire_risk='line'},
    T_HEAL={kind='heal',target='self',resource='mana'},
    T_ARCANE_POWER={kind='sustain',target='self',resource='mana'},
    T_SHIELDING={kind='sustain',target='self',resource='mana'},
    -- Corruptor (corruption/sanguisuge + corruption/vim + corruption/blight +
    -- corruption/blood).
    T_SOUL_ROT={kind='attack',target='hostile',shape='beam',range=10,resource='vim',
        friendlyfire_risk='line'},
    -- Blood Grasp is a bolt with `friendlyfire=false`: it heals the caster for a
    -- share of the damage dealt, so it is the Corruptor's self-preservation.
    T_BLOOD_GRASP={kind='attack',target='hostile',shape='hit',range=10,resource='vim',
        friendlyfire_risk='none'},
    T_DARK_RITUAL={kind='sustain',target='self',resource='vim'},
    -- Berserker (technique/strength-of-the-berserker + technique/conditioning).
    T_SHATTERING_BLOW={kind='attack',target='hostile',shape='hit',range=1,resource='stamina',
        friendlyfire_risk='none'},
    T_BERSERKER_RAGE={kind='sustain',target='self',resource='stamina'},
    T_DAUNTING_PRESENCE={kind='sustain',target='self',resource='stamina'},
    T_ADRENALINE_SURGE={kind='buff',target='self'},
}
M.HOSTILE_SELECTORS={nearest_hostile=true,lowest_hp_hostile=true,
    highest_rank_hostile=true,most_dangerous_hostile=true}
M.SELF_SELECTORS={self=true}

-- Action-level adapters. P1a actions plus the P1b native activities.
M.ACTIONS={
    use_talent={kind='talent'},
    attack={kind='attack'},
    wait={kind='utility'},
    rest={kind='native_activity',activity='rest',default_max_turns=1000},
    auto_explore={kind='native_activity',activity='auto_explore'},
}
function M.actionSupported(action) return action~=nil and M.ACTIONS[action]~=nil end

function M.supported(talent) return M.ENTRIES[talent]~=nil end
function M.entry(talent) return M.ENTRIES[talent] end
function M.isSustain(talent)
    local entry=M.ENTRIES[talent]; return entry~=nil and entry.kind=='sustain'
end

-- Compatibility check beyond the schema: selector fits the talent's target mode.
function M.verify(policy)
    local errors={}
    for index,rule in ipairs((policy and policy.rules) or {}) do
        local action=rule['then'] and rule['then'].action
        local path='rules['..index..']'
        if action~=nil and not M.ACTIONS[action] then
            errors[#errors+1]={path=path..'.then.action',code='unsupported_action'}
        end
        local entry=rule['then'] and rule['then'].talent and M.ENTRIES[rule['then'].talent] or nil
        if entry then
            local selector=rule['then'].target or (policy.targeting and policy.targeting.default)
            if entry.target=='self' and selector~=nil and not M.SELF_SELECTORS[selector] then
                errors[#errors+1]={path=path,code='selector_not_self_only',talent=rule['then'].talent}
            end
            if entry.target=='hostile' and selector~=nil and not M.HOSTILE_SELECTORS[selector] then
                errors[#errors+1]={path=path,code='selector_not_hostile',talent=rule['then'].talent}
            end
        elseif rule['then'] and rule['then'].action=='use_talent' then
            errors[#errors+1]={path=path,code='unsupported_talent',talent=rule['then'].talent}
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
    local actions={}
    for action,entry in pairs(M.ACTIONS) do
        actions[#actions+1]={action=action,kind=entry.kind,activity=entry.activity,
            default_max_turns=entry.default_max_turns,default_enabled=entry.default_enabled}
    end
    table.sort(actions,function(a,b) return a.action<b.action end)
    return {schema='tome-auto-combat/v1',adapter_version=M.VERSION,
        talents=talents,actions=actions}
end
return M
