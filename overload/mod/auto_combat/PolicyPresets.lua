-- GPL-3.0-or-later. Built-in policy presets for the frozen P1a pilot build.
--
-- Presets are ordinary policy documents: they must pass PolicySchema and the
-- AutoCombatCatalog semantic check, so a preset can never describe an action the
-- executor does not support.
local M={}
M.PRESETS={
    anorithil_p1a={
        schema='tome-auto-combat/v1',id='anorithil-p1a',name='Anorithil (P1a pilot)',
        limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=true,
            pause_on_unknown_safety=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        sustains={
            {talent='T_CHANT_OF_FORTRESS',priority=20,min_resource_pct=20},
            {talent='T_HYMN_OF_SHADOWS',priority=10,min_resource_pct=20},
        },
        rules={
            {id='heal',priority=100,emergency=true,
                when={all={{hp_pct={lt=50}},{talent_known={talent='T_HEALING_LIGHT'}}}},
                ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
            {id='barrier',priority=90,
                when={all={{hp_pct={lt=70}},{talent_known={talent='T_BARRIER'}},
                    {cooldown_ready={talent='T_BARRIER'}}}},
                ['then']={action='use_talent',talent='T_BARRIER',target='self'}},
            {id='finish',priority=60,
                when={all={{enemy_hp_pct={lt=30}},{talent_known={talent='T_SEARING_LIGHT'}},
                    {cooldown_ready={talent='T_SEARING_LIGHT'}}}},
                ['then']={action='use_talent',talent='T_SEARING_LIGHT',target='lowest_hp_hostile'}},
            {id='melee',priority=50,when={enemy_in_melee={}},
                ['then']={action='attack',target='nearest_hostile'}},
            {id='ray',priority=40,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=10}},
                    {talent_known={talent='T_MOONLIGHT_RAY'}},
                    {cooldown_ready={talent='T_MOONLIGHT_RAY'}},
                    -- Do not select a ray the native pool cannot pay for: an
                    -- unaffordable cast is a reject-only denial, and falling
                    -- through to `hold` would end the run at
                    -- `no_available_action` without spending a turn (so the
                    -- resource never regenerates). The resource-gated recover
                    -- rule below spends the turn instead.
                    {resource_value={resource='negative',ge=10}}}}, 
                ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}},
            -- Explicit, lowest-priority recovery: an enemy is in range but the
            -- main ray is cooling down or its negative-energy pool cannot pay
            -- the 10-point cost, so spend one turn (which advances the cooldown
            -- and regenerates resources) instead of stopping every opportunity.
            -- This is a declared data rule, not an implicit executor fallback.
            {id='recover',priority=1,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=10}},
                    {['any']={{['not']={cooldown_ready={talent='T_MOONLIGHT_RAY'}}},
                        {resource_value={resource='negative',lt=10}}}}}},
                ['then']={action='wait'}},
        },
    },
    -- P2 second pilot build. Sun Paladin shares the celestial/positive energy
    -- pool with the Anorithil but uses the ranged single-target Sun Ray and the
    -- Weapon of Light sustain. The boss rule exercises the P2 rank predicate and
    -- `most_dangerous_hostile` selector.
    sun_paladin_p2={
        schema='tome-auto-combat/v1',id='sun-paladin-p2',name='Sun Paladin (P2 pilot)',
        class='celestial/sun-paladin',
        limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=true,
            pause_on_unknown_safety=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        sustains={
            {talent='T_CHANT_OF_FORTRESS',priority=20,min_resource_pct=20},
            {talent='T_WEAPON_OF_LIGHT',priority=15,min_resource_pct=20},
        },
        rules={
            {id='heal',priority=100,emergency=true,
                when={all={{hp_pct={lt=50}},{talent_known={talent='T_HEALING_LIGHT'}}}},
                ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
            {id='barrier',priority=90,
                when={all={{hp_pct={lt=70}},{talent_known={talent='T_BARRIER'}},
                    {cooldown_ready={talent='T_BARRIER'}}}},
                ['then']={action='use_talent',talent='T_BARRIER',target='self'}},
            {id='smite-boss',priority=80,
                when={all={{enemy_is_boss={}},{talent_known={talent='T_SUN_BEAM'}},
                    {cooldown_ready={talent='T_SUN_BEAM'}}}},
                ['then']={action='use_talent',talent='T_SUN_BEAM',target='most_dangerous_hostile'}},
            {id='sun-beam',priority=60,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=7}},
                    {talent_known={talent='T_SUN_BEAM'}},
                    {cooldown_ready={talent='T_SUN_BEAM'}}}},
                ['then']={action='use_talent',talent='T_SUN_BEAM',target='nearest_hostile'}},
            {id='melee',priority=50,when={enemy_in_melee={}},
                ['then']={action='attack',target='nearest_hostile'}},
            {id='recover',priority=1,
                when={all={{enemy_count={ge=1}},{['not']={cooldown_ready={talent='T_SUN_BEAM'}}}}},
                ['then']={action='wait'}},
        },
    },
    -- P2 class pilots (round 4). Source-verified talent metadata; data-only.
    archmage_arcane_p2={
        schema='tome-auto-combat/v1',id='archmage-arcane-p2',name='Archmage (Arcane/Fire)',
        class='mage/archmage',
        limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=true,
            pause_on_unknown_safety=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        sustains={
            {talent='T_ARCANE_POWER',priority=20,min_resource_pct=20},
            {talent='T_SHIELDING',priority=10,min_resource_pct=20},
        },
        rules={
            {id='heal',priority=100,emergency=true,
                when={all={{hp_pct={lt=50}},{talent_known={talent='T_HEAL'}}}},
                ['then']={action='use_talent',talent='T_HEAL',target='self'}},
            {id='melee',priority=50,when={enemy_in_melee={}},
                ['then']={action='attack',target='nearest_hostile'}},
            {id='flame',priority=40,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=10}},
                    {talent_known={talent='T_FLAME'}},
                    {cooldown_ready={talent='T_FLAME'}},
                    {resource_value={resource='mana',ge=12}}}},
                ['then']={action='use_talent',talent='T_FLAME',target='nearest_hostile'}},
            {id='recover',priority=1,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=10}},
                    {['any']={{['not']={cooldown_ready={talent='T_FLAME'}}},
                        {resource_value={resource='mana',lt=12}}}}}},
                ['then']={action='wait'}},
        },
    },
    corruptor_blight_p2={
        schema='tome-auto-combat/v1',id='corruptor-blight-p2',name='Corruptor (Blight/Sanguisuge)',
        class='corrupted/corruptor',
        limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=true,
            pause_on_unknown_safety=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        sustains={
            {talent='T_DARK_RITUAL',priority=20,min_resource_pct=20},
        },
        rules={
            -- Blood Grasp damages and heals the caster; it is the emergency
            -- self-preservation action when a hostile is available.
            {id='grasp',priority=100,emergency=true,
                when={all={{hp_pct={lt=50}},{enemy_count={ge=1}},
                    {talent_known={talent='T_BLOOD_GRASP'}},
                    {cooldown_ready={talent='T_BLOOD_GRASP'}},
                    {resource_value={resource='vim',ge=20}}}},
                ['then']={action='use_talent',talent='T_BLOOD_GRASP',target='nearest_hostile'}},
            {id='melee',priority=50,when={enemy_in_melee={}},
                ['then']={action='attack',target='nearest_hostile'}},
            {id='rot',priority=40,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=10}},
                    {talent_known={talent='T_SOUL_ROT'}},
                    {cooldown_ready={talent='T_SOUL_ROT'}},
                    {resource_value={resource='vim',ge=10}}}},
                ['then']={action='use_talent',talent='T_SOUL_ROT',target='nearest_hostile'}},
            {id='recover',priority=1,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=10}},
                    {['any']={{['not']={cooldown_ready={talent='T_SOUL_ROT'}}},
                        {resource_value={resource='vim',lt=10}}}}}},
                ['then']={action='wait'}},
        },
    },
    berserker_p2={
        schema='tome-auto-combat/v1',id='berserker-p2',name='Berserker (Technique)',
        class='warrior/berserker',
        limits={max_actions_per_tick=2},
        safety={min_hp_pct=35,flee_below_hp_pct=25,pause_on_new_enemy=true,
            pause_on_unknown_safety=true,max_selffire_risk=0},
        targeting={default='nearest_hostile'},
        sustains={
            {talent='T_BERSERKER_RAGE',priority=20,min_resource_pct=20},
            {talent='T_DAUNTING_PRESENCE',priority=10,min_resource_pct=20},
        },
        rules={
            -- No heal in the tree; the emergency layer uses the instant
            -- self-buff, which is a valid self-preservation shape and is
            -- covered by the self-target adapter guard.
            {id='adrenaline',priority=100,emergency=true,
                when={all={{hp_pct={lt=50}},{talent_known={talent='T_ADRENALINE_SURGE'}},
                    {cooldown_ready={talent='T_ADRENALINE_SURGE'}}}},
                ['then']={action='use_talent',talent='T_ADRENALINE_SURGE',target='self'}},
            {id='shatter',priority=60,
                when={all={{enemy_in_melee={}},{talent_known={talent='T_SHATTERING_BLOW'}},
                    {cooldown_ready={talent='T_SHATTERING_BLOW'}},
                    {resource_value={resource='stamina',ge=12}}}},
                ['then']={action='use_talent',talent='T_SHATTERING_BLOW',target='nearest_hostile'}},
            {id='melee',priority=50,when={enemy_in_melee={}},
                ['then']={action='attack',target='nearest_hostile'}},
            -- A visible but not-yet-adjacent foe: wait for it to close instead
            -- of ending the run (the policy action set has no move rule).
            {id='close',priority=1,
                when={all={{enemy_count={ge=1}},{['not']={enemy_in_melee={}}}}},
                ['then']={action='wait'}},
        },
    },
}

function M.get(name) return M.PRESETS[name] end

function M.summaries()
    local out={}
    for _,name in ipairs(M.names()) do
        local preset=M.PRESETS[name]
        out[#out+1]={name=name,id=preset.id,title=preset.name,rules=#preset.rules}
    end
    return out
end

function M.names()
    local names={}
    for name in pairs(M.PRESETS) do names[#names+1]=name end
    table.sort(names)
    return names
end

-- Deep copy so a caller can edit a preset without mutating the built-in.
function M.copy(name)
    local preset=M.PRESETS[name]
    if not preset then return nil end
    local function clone(value)
        if type(value)~='table' then return value end
        local out={}
        for key,item in pairs(value) do out[key]=clone(item) end
        return out
    end
    return clone(preset)
end
return M
