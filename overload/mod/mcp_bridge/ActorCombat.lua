-- GPL-3.0-or-later. Bounded computed actor combat read (player-sheet values).
--
-- The player UI shows these values, so reads may call the getters. Each getter
-- is called only when it is a native function from the audited file; an
-- overridden, missing or erroring getter is reported as "unknown" instead of
-- being trusted. No RNG, no attack rolls, no target-specific resolution.
local Json=require 'mod.mcp_bridge.Json'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Manifest=require 'mod.mcp_bridge.NativeManifest'
local M={}

local COMBAT='/mod/class/interface/Combat.lua'
local STATS='/engine/interface/ActorStats.lua'
-- The finite audited computed-getter set (SAFE-01/D11). Registered through
-- NativeCompatibility so resolution requires the source digest, the exact
-- function identity and a declaration match, not only a source-label suffix.
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
    Compat.registerDependency('computed.getStat','computed',actor.getStat,STATS,'effective stat',
        Manifest.stats_md5,'function _M:getStat',{})
    for _,name in ipairs(COMBAT_METHODS) do
        Compat.registerDependency('computed.'..name,'computed',actor[name],COMBAT,'computed panel getter',
            Manifest.combat_md5,'function _M:'..name,{})
    end
    return true
end
local STAT_NAMES={'str','dex','con','mag','wil','cun','lck'}
-- ToME damage-type keys as used by resists/inc_damage/resists_pen.
local DAMAGE_TYPES={'PHYSICAL','FIRE','COLD','LIGHTNING','ACID','NATURE','BLIGHT','LIGHT','DARKNESS','MIND','TEMPORAL','ARCANE'}

local function finite(v) return type(v)=='number' and v==v and v>-math.huge and v<math.huge end
local function native(fn,suffix)
    if type(fn)~='function' then return false end
    local info=debug.getinfo(fn,'S')
    return info~=nil and type(info.source)=='string' and info.source:sub(1,1)=='@'
        and info.source:sub(-#suffix)==suffix
end

function M.computed(actor)
    if type(actor)~='table' then return nil,'actor_unavailable' end
    M.register(actor)
    local unknown=Json.array()
    -- Call an audited native getter; nil (and a note in `unknown`) otherwise.
    local function value(name,suffix,...)
        local fn=actor[name]
        if not native(fn,suffix) then unknown[#unknown+1]=name; return nil end
        -- SAFE-01: the Compatibility registry enforces the source digest and the
        -- exact function identity; a same-label spoof or a modified file fails.
        local admitted=Compat.dependency('computed.'..name,fn)
        if not admitted then unknown[#unknown+1]=name; return nil end
        local ok,v=pcall(fn,actor,...)
        if not ok or not finite(v) then unknown[#unknown+1]=name; return nil end
        return v
    end
    local stats={}
    for _,stat in ipairs(STAT_NAMES) do stats[stat]=value('getStat',STATS,stat) end
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
            movement=value('combatMovementSpeed',COMBAT),
            attack=value('combatSpeed',COMBAT,actor.combat),
            spell=value('combatSpellSpeed',COMBAT),
            mind=value('combatMindSpeed',COMBAT),
        },
        crit={
            physical=value('combatCrit',COMBAT,actor.combat),
            spell=value('combatSpellCrit',COMBAT),
            mind=value('combatMindCrit',COMBAT),
            power_pct=crit_power,
            multiplier=crit_power and (1.5+crit_power/100) or nil,
        },
        power={
            physical=value('combatPhysicalpower',COMBAT),
            spell=value('combatSpellpower',COMBAT),
            mind=value('combatMindpower',COMBAT),
        },
        offense={
            accuracy=value('combatAttack',COMBAT,actor.combat),
            apr=value('combatAPR',COMBAT,actor.combat),
            damage=value('combatDamage',COMBAT,actor.combat),
            damage_range=value('combatDamageRange',COMBAT,actor.combat),
            damage_increase={},
            resistance_penetration={},
            damage_affinity={},
        },
        defense={
            defense=value('combatDefense',COMBAT),
            defense_ranged=value('combatDefenseRanged',COMBAT),
            armor=value('combatArmor',COMBAT),
            armor_hardiness=value('combatArmorHardiness',COMBAT),
            fatigue=value('combatFatigue',COMBAT),
        },
        saves={
            physical=value('combatPhysicalResist',COMBAT),
            spell=value('combatSpellResist',COMBAT),
            mental=value('combatMentalResist',COMBAT),
        },
        resists={},
        utility={
            see_stealth=value('combatSeeStealth',COMBAT),
            see_invisible=value('combatSeeInvisible',COMBAT),
            crit_reduction=value('combatCritReduction',COMBAT),
        },
    }
    for _,t in ipairs(DAMAGE_TYPES) do
        result.offense.damage_increase[t]=value('combatGetDamageIncrease',COMBAT,t)
        result.offense.resistance_penetration[t]=value('combatGetResistPen',COMBAT,t)
        result.offense.damage_affinity[t]=value('combatGetAffinity',COMBAT,t)
        result.resists[t]=value('combatGetResist',COMBAT,t)
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
