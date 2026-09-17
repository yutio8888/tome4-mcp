-- P2 class pilots (round 4): Archmage, Corruptor, Berserker.
--
-- Validates the new talent whitelist/catalogue entries, that every new preset
-- passes the schema and the semantic catalogue, and that the evaluator picks
-- the intended rule for crafted snapshots (emergency / damage / recover).
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Presets=require 'mod.auto_combat.PolicyPresets'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local Evaluator=require 'mod.auto_combat.PolicyEvaluator'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local NEW_TALENTS={'T_FLAME','T_HEAL','T_ARCANE_POWER','T_SHIELDING',
    'T_SOUL_ROT','T_BLOOD_GRASP','T_DARK_RITUAL',
    'T_SHATTERING_BLOW','T_BERSERKER_RAGE','T_DAUNTING_PRESENCE','T_ADRENALINE_SURGE'}
local NEW_SUSTAINS={'T_ARCANE_POWER','T_SHIELDING','T_DARK_RITUAL','T_BERSERKER_RAGE',
    'T_DAUNTING_PRESENCE'}
for _,talent in ipairs(NEW_TALENTS) do
    check(Schema.TALENTS[talent]==true,'schema whitelists '..talent)
    check(Catalog.entry(talent)~=nil,'catalogue describes '..talent)
end
for _,talent in ipairs(NEW_SUSTAINS) do
    check(Schema.SUSTAINS[talent]==true,'schema lists the sustain '..talent)
    check(Catalog.isSustain(talent),'catalogue marks '..talent..' as a sustain')
end
-- The hostile damage adapters declare a line/area risk and a range.
check(Catalog.entry('T_FLAME').shape=='beam' and Catalog.entry('T_FLAME').friendlyfire_risk=='line',
    'Flame is a beam with a line friendly-fire risk')
check(Catalog.entry('T_SOUL_ROT').shape=='beam' and Catalog.entry('T_SOUL_ROT').friendlyfire_risk=='line',
    'Soul Rot is a beam with a line friendly-fire risk')
check(Catalog.entry('T_BLOOD_GRASP').friendlyfire_risk=='none'
    and Catalog.entry('T_BLOOD_GRASP').range==10,'Blood Grasp is a self-safe bolt')
check(Catalog.entry('T_HEAL').kind=='heal'
    and Catalog.entry('T_HEAL').target=='self','Arcane Reconstruction is a self heal')
check(Catalog.entry('T_ADRENALINE_SURGE').kind=='buff'
    and Catalog.entry('T_ADRENALINE_SURGE').target=='self','Adrenaline Surge is a self buff')

-- Presets validate and are semantically compatible.
local PILOTS={'archmage_arcane_p2','corruptor_blight_p2','berserker_p2'}
for _,name in ipairs(PILOTS) do
    local preset=Presets.get(name)
    check(preset~=nil,'preset '..name..' exists')
    check(Schema.validate(preset)==true,'preset '..name..' passes the schema')
    check(Catalog.verify(preset)==true,'preset '..name..' is catalogue-compatible')
end

-- Crafted-context evaluator coverage ----------------------------------------
local function ctx(overrides)
    local c={attempts=0,hp_pct=80,enemy_count=1,nearest_enemy_distance=5,enemy_in_melee=false,
        talent_known=function() return true end,
        cooldown_ready=function() return true end,
        resource_value=function() return 100 end,
        resource_pct=function() return 100 end}
    for k,v in pairs(overrides or {}) do c[k]=v end
    return c
end
local function decide(name,c)
    return Evaluator.evaluate(Presets.get(name),c)
end

-- Archmage: emergency heal / flame damage / cooldown+resource recover.
do
    local d=decide('archmage_arcane_p2',ctx({hp_pct=20}))
    check(d.decision=='act' and d.rule=='heal' and d.emergency==true,
        'Archmage low HP picks the emergency heal')
    local inrange=decide('archmage_arcane_p2',ctx({hp_pct=80}))
    check(inrange.decision=='act' and inrange.rule=='flame' and inrange.talent=='T_FLAME',
        'Archmage in range casts Flame')
    local cold=decide('archmage_arcane_p2',ctx({hp_pct=80,
        cooldown_ready=function(id) return id~='T_FLAME' end}))
    check(cold.decision=='act' and cold.rule=='recover' and cold.action=='wait',
        'Archmage waits while Flame cools down')
    local dry=decide('archmage_arcane_p2',ctx({hp_pct=80,nearest_enemy_distance=9,
        resource_value=function(name) return name=='mana' and 4 or 100 end}))
    check(dry.decision=='act' and dry.rule=='recover' and dry.action=='wait',
        'Archmage waits when mana cannot pay for Flame')
end

-- Corruptor: emergency Blood Grasp / Soul Rot damage / recover.
do
    local d=decide('corruptor_blight_p2',ctx({hp_pct=20}))
    check(d.decision=='act' and d.rule=='grasp' and d.talent=='T_BLOOD_GRASP' and d.emergency==true,
        'Corruptor low HP picks the emergency Blood Grasp')
    local inrange=decide('corruptor_blight_p2',ctx({hp_pct=80}))
    check(inrange.decision=='act' and inrange.rule=='rot' and inrange.talent=='T_SOUL_ROT',
        'Corruptor in range casts Soul Rot')
    local cold=decide('corruptor_blight_p2',ctx({hp_pct=80,
        cooldown_ready=function(id) return id~='T_SOUL_ROT' end}))
    check(cold.decision=='act' and cold.rule=='recover' and cold.action=='wait',
        'Corruptor waits while Soul Rot cools down')
end

-- Berserker: emergency Adrenaline Surge / Shattering Blow / melee / close wait.
do
    local d=decide('berserker_p2',ctx({hp_pct=20}))
    check(d.decision=='act' and d.rule=='adrenaline' and d.talent=='T_ADRENALINE_SURGE',
        'Berserker low HP picks the emergency self-buff')
    local inmelee=decide('berserker_p2',ctx({hp_pct=80,enemy_in_melee=true}))
    check(inmelee.decision=='act' and inmelee.rule=='shatter' and inmelee.talent=='T_SHATTERING_BLOW',
        'Berserker in melee opens with Shattering Blow')
    local basic=decide('berserker_p2',ctx({hp_pct=80,enemy_in_melee=true,
        cooldown_ready=function(id) return id~='T_SHATTERING_BLOW' end}))
    check(basic.decision=='act' and basic.rule=='melee' and basic.action=='attack',
        'Berserker falls back to the native attack while Shattering Blow cools down')
    local far=decide('berserker_p2',ctx({hp_pct=80,enemy_in_melee=false}))
    check(far.decision=='act' and far.rule=='close' and far.action=='wait',
        'Berserker waits for a visible foe to close')
end

print('Auto-combat pilots: '..checks..' checks passed')
