-- GPL-3.0-or-later. Bounded computed actor combat read (player-sheet values).
--
-- The player UI shows these values, so reads may call the getters. Under the
-- no-strict-audit principle each getter is called directly as a normal
-- entrypoint: a replaced-but-usable getter IS used, and only a missing, erroring
-- or non-finite result is reported as "unknown". No RNG, no attack rolls, no
-- target-specific resolution.
local Json=require 'mod.mcp_bridge.Json'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local M={}

-- The finite curated computed-getter set (SAFE-01/D11). Provenance is recorded
-- through NativeCompatibility for diagnostics only; it never gates a read.
local COMBAT_METHODS={'combatMovementSpeed','combatSpeed','combatSpellSpeed','combatMindSpeed',
    'combatCrit','combatSpellCrit','combatMindCrit','combatPhysicalpower','combatSpellpower',
    'combatMindpower','combatAttack','combatAPR','combatDamage','combatDamageRange','combatDefense',
    'combatDefenseRanged','combatArmor','combatArmorHardiness','combatFatigue','combatPhysicalResist',
    'combatSpellResist','combatMentalResist','combatSeeStealth','combatSeeInvisible',
    'combatCritReduction','combatGetDamageIncrease','combatGetResistPen','combatGetAffinity',
    'combatGetResist'}
local registered={}
function M.register(actor)
    if type(actor)~='table' or registered[actor] then return registered[actor]==true end
    registered[actor]=true
    -- Diagnostic provenance only (no digest/declaration supplied): these calls
    -- cannot fail a read.
    for _,name in ipairs(COMBAT_METHODS) do
        if type(actor[name])=='function' then
            Compat.registerDependency('computed.'..name,'computed',actor[name],nil,'computed panel getter')
        end
    end
    return true
end
local STAT_NAMES={'str','dex','con','mag','wil','cun','lck'}
-- ToME damage-type keys as used by resists/inc_damage/resists_pen.
local DAMAGE_TYPES={'PHYSICAL','FIRE','COLD','LIGHTNING','ACID','NATURE','BLIGHT','LIGHT','DARKNESS','MIND','TEMPORAL','ARCANE'}

local function finite(v) return type(v)=='number' and v==v and v>-math.huge and v<math.huge end

function M.computed(actor)
    if type(actor)~='table' then return nil,'actor_unavailable' end
    M.register(actor)
    local unknown=Json.array()
    -- Call the live getter directly; a missing/erroring/non-finite value is
    -- unknown. A replaced-but-usable getter is used (no identity/digest gate).
    local function value(name,suffix,...)
        local fn=actor[name]
        if type(fn)~='function' then unknown[#unknown+1]=name; return nil end
        local ok,v=pcall(fn,actor,...)
        if not ok or not finite(v) then unknown[#unknown+1]=name; return nil end
        return v
    end
    local stats={}
    for _,stat in ipairs(STAT_NAMES) do stats[stat]=value('getStat',nil,stat) end
    local crit_power=Details.number(actor.combat_critical_power)
    local result={
        computed=true,
        computed_scope='native computed getters (the values the player character sheet shows); '
            ..'read-only, no RNG and no target-specific resolution. "unknown" lists getters that were '
            ..'overridden, missing or errored.',
        unknown=unknown,
        stats=stats,
        speeds={
            global=Details.number(actor.global_speed),
            movement=value('combatMovementSpeed',nil),
            attack=value('combatSpeed',nil,actor.combat),
            spell=value('combatSpellSpeed',nil),
            mind=value('combatMindSpeed',nil),
        },
        crit={
            physical=value('combatCrit',nil,actor.combat),
            spell=value('combatSpellCrit',nil),
            mind=value('combatMindCrit',nil),
            power_pct=crit_power,
            multiplier=crit_power and (1.5+crit_power/100) or nil,
        },
        power={
            physical=value('combatPhysicalpower',nil),
            spell=value('combatSpellpower',nil),
            mind=value('combatMindpower',nil),
        },
        offense={
            accuracy=value('combatAttack',nil,actor.combat),
            apr=value('combatAPR',nil,actor.combat),
            damage=value('combatDamage',nil,actor.combat),
            damage_range=value('combatDamageRange',nil,actor.combat),
            damage_increase={},
            resistance_penetration={},
            damage_affinity={},
        },
        defense={
            defense=value('combatDefense',nil),
            defense_ranged=value('combatDefenseRanged',nil),
            armor=value('combatArmor',nil),
            armor_hardiness=value('combatArmorHardiness',nil),
            fatigue=value('combatFatigue',nil),
        },
        saves={
            physical=value('combatPhysicalResist',nil),
            spell=value('combatSpellResist',nil),
            mental=value('combatMentalResist',nil),
        },
        resists={},
        utility={
            see_stealth=value('combatSeeStealth',nil),
            see_invisible=value('combatSeeInvisible',nil),
            crit_reduction=value('combatCritReduction',nil),
        },
    }
    for _,t in ipairs(DAMAGE_TYPES) do
        result.offense.damage_increase[t]=value('combatGetDamageIncrease',nil,t)
        result.offense.resistance_penetration[t]=value('combatGetResistPen',nil,t)
        result.offense.damage_affinity[t]=value('combatGetAffinity',nil,t)
        result.resists[t]=value('combatGetResist',nil,t)
    end
    return result
end

-- Resolve a finite-enum field id (e.g. `crit.spell`, `resists.FIRE`) from a
-- `computed` result. Pure traversal; nil for a missing/unknown value so the
-- caller fail-closes to `unknown`.
function M.field(values,field)
    if type(values)~='table' or type(field)~='string' then return nil end
    local current=values
    for part in field:gmatch('[^.]+') do
        if type(current)~='table' then return nil end
        current=current[part]
    end
    if finite(current) then return current end
    return nil
end
return M
