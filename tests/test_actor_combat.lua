-- Bounded computed actor combat read (ActorCombat).
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local ActorCombat=require 'mod.mcp_bridge.ActorCombat'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
-- SAFE-01 unit isolation: the registry digest/identity audit is covered by
-- tests/test_native_compatibility.lua; here the mock getters are not real
-- files, so admit them and keep testing the value extraction.
Compat.registerDependency=function() return true end
Compat.dependency=function(id,fn) return fn end
local count=0
local function check(v,m) count=count+1;assert(v,m) end
local COMBAT='/mod/class/interface/Combat.lua'
local STATS='/engine/interface/ActorStats.lua'
local function fnFrom(suffix,body) return assert(loadstring('return '..body,'@'..suffix))() end

local actor={combat={},combat_critical_power=25,global_speed=1.2}
actor.getStat=fnFrom(STATS,'function(self,stat) return ({str=40,dex=20,con=30,mag=50,wil=25,cun=35,lck=45})[stat] end')
local values={combatMovementSpeed=1.05,combatSpeed=0.9,combatSpellSpeed=1.1,combatMindSpeed=1.0,
    combatCrit=22,combatSpellCrit=15,combatMindCrit=10,
    combatPhysicalpower=60,combatSpellpower=70,combatMindpower=55,
    combatAttack=48,combatAPR=12,combatDamage=88,combatDamageRange=1.3,
    combatDefense=33,combatDefenseRanged=20,combatArmor=17,combatArmorHardiness=40,combatFatigue=0.3,
    combatPhysicalResist=41,combatSpellResist=29,combatMentalResist=24,
    combatSeeStealth=9,combatSeeInvisible=4,combatCritReduction=7,
    combatGetDamageIncrease=11,combatGetResistPen=6,combatGetAffinity=3,combatGetResist=18}
for name,value in pairs(values) do
    actor[name]=fnFrom(COMBAT,('function(self) return %s end'):format(value))
end

local c=ActorCombat.computed(actor)
check(c and c.computed==true,'computed block present and labelled')
check(c.stats.str==40 and c.stats.mag==50 and c.stats.lck==45,'effective stats from the audited getStat')
check(c.speeds.global==1.2 and c.speeds.movement==1.05 and c.speeds.attack==0.9
    and c.speeds.spell==1.1 and c.speeds.mind==1.0,'global/movement/attack/spell/mind speeds')
check(c.crit.physical==22 and c.crit.spell==15 and c.crit.mind==10,'physical/spell/mind crit chance')
check(c.crit.power_pct==25 and math.abs(c.crit.multiplier-1.75)<1e-9,'crit damage bonus and multiplier')
check(c.power.physical==60 and c.power.spell==70 and c.power.mind==55,'combat powers')
check(c.offense.accuracy==48 and c.offense.apr==12 and c.offense.damage==88
    and c.offense.damage_range==1.3,'weapon accuracy/APR/damage/range')
check(c.offense.damage_increase.FIRE==11 and c.offense.resistance_penetration.FIRE==6
    and c.offense.damage_affinity.FIRE==3 and c.resists.FIRE==18,'per-type increase/penetration/affinity/resist')
check(c.defense.defense==33 and c.defense.armor==17 and c.defense.fatigue==0.3,'defense/armor/fatigue')
check(c.saves.physical==41 and c.saves.spell==29 and c.saves.mental==24,'physical/spell/mental saves')
check(c.utility.see_stealth==9 and c.utility.crit_reduction==7,'vision and crit reduction')
check(#c.unknown==0,'an all-native actor has no unknown getters')

-- P2.5: finite-enum traversal must agree with the computed table.
local Schema=require 'mod.auto_combat.PolicySchema'
check(ActorCombat.field(c,'crit.spell')==15,'field resolves a nested computed path')
check(ActorCombat.field(c,'resists.FIRE')==18,'field resolves a per-damage-type path')
check(ActorCombat.field(c,'offense.resistance_penetration.FIRE')==6,'field resolves a deep enum path')
check(ActorCombat.field(c,'stats.str')==40,'field resolves a stats path')
check(ActorCombat.field(c,'nonsense.path')==nil,'an unknown field path resolves to nil')
check(ActorCombat.field(nil,'crit.spell')==nil,'a missing computed table resolves to nil')
local unresolved=0
for field in pairs(Schema.COMPUTED_FIELDS) do
    if ActorCombat.field(c,field)==nil then unresolved=unresolved+1 end
end
check(unresolved==0,'every computed enum id resolves on an all-native actor')

-- Fail closed: an overridden getter is neither trusted nor called into the block.
actor.combatArmor=function() return 999 end
local c2=ActorCombat.computed(actor)
check(c2.defense.armor==nil,'an overridden getter is not trusted')
local listed=false
for _,name in ipairs(c2.unknown) do if name=='combatArmor' then listed=true end end
check(listed,'an overridden getter is listed in unknown')

-- Fail closed: a getter that errors is unknown, not fatal.
actor.combatDamage=fnFrom(COMBAT,'function(self) error("boom") end')
local c3=ActorCombat.computed(actor)
check(c3.offense.damage==nil,'an erroring getter yields unknown instead of aborting the read')

print('Actor combat: '..count..' checks passed')
