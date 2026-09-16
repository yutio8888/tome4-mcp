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
            {id='heal',priority=100,emergency=true,when={hp_pct={lt=50}},
                ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='self'}},
            {id='barrier',priority=90,
                when={all={{hp_pct={lt=70}},{cooldown_ready={talent='T_BARRIER'}}}},
                ['then']={action='use_talent',talent='T_BARRIER',target='self'}},
            {id='finish',priority=60,
                when={all={{enemy_hp_pct={lt=30}},{cooldown_ready={talent='T_SEARING_LIGHT'}}}},
                ['then']={action='use_talent',talent='T_SEARING_LIGHT',target='lowest_hp_hostile'}},
            {id='melee',priority=50,when={enemy_in_melee={}},
                ['then']={action='attack',target='nearest_hostile'}},
            {id='ray',priority=40,
                when={all={{enemy_count={ge=1}},{nearest_enemy_distance={le=10}},
                    {cooldown_ready={talent='T_MOONLIGHT_RAY'}}}},
                ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}},
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
