-- V2-1: version-pinned, componentised effect manifest.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Manifest=require 'mod.auto_combat.EffectManifest'
local Schema=require 'mod.auto_combat.PolicySchema'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

check(Manifest.VERSION=='tome-auto-combat-adapters/v2','the manifest is v2')
check(Manifest.SCHEMA=='tome-auto-combat/v1','the policy schema stays v1')
check(Manifest.GAME_VERSION=='1.7.6','the manifest is pinned to ToME 1.7.6')
check(Manifest.SOURCES.schema=='tome-effect-manifest-sources/v1','the generated source table is present')

-- Every whitelisted hostile/self talent has a canonical entry and vice versa.
for talent in pairs(Schema.TALENTS) do
    check(Manifest.supported(talent),'whitelisted talent '..talent..' has a manifest entry')
end
for talent in pairs(Schema.SUSTAINS) do
    check(Manifest.isSustain(talent),'sustain '..talent..' is a manifest sustain')
end

-- Provenance: every entry pins a source file + hash + definition line.
for talent,entry in pairs(Manifest.ENTRIES) do
    local pin=Manifest.SOURCES.talents[talent]
    check(pin~=nil,'source pin exists for '..talent)
    check(pin.line and pin.line>0,'source definition line pinned for '..talent)
    check(type(pin.files)=='table' and #pin.files>=1,'source files pinned for '..talent)
    for _,file in ipairs(pin.files) do
        check(type(file.path)=='string' and #file.path>0,'source path for '..talent)
        check(type(file.md5)=='string' and #file.md5==32,'source md5 for '..talent)
    end
    check(entry.components~=nil,'components declared for '..talent)
end

-- Cursor geometry is kept separate from the damaging components.
do
    local searing=Manifest.entry('T_SEARING_LIGHT')
    local phases={}
    for _,component in ipairs(searing.components) do phases[component.phase]=component end
    check(phases.cursor and phases.cursor.shape=='ball' and phases.cursor.radius==1,
        'Searing Light keeps a ball cursor')
    check(phases.instant and phases.instant.shape=='hit','Searing Light instant is a single hit')
    check(phases.ground and phases.ground.duration==4 and phases.ground.selffire==0
        and phases.ground.friendlyfire==0,'Searing Light ground is a safe persistent zone')
    check(searing.conformance.shape=='ball' and searing.conformance.range==7,
        'Searing Light conformance pins the real builder cursor')
end
do
    local sun=Manifest.entry('T_SUN_BEAM')
    local secondary
    for _,component in ipairs(sun.components) do if component.phase=='secondary' then secondary=component end end
    check(secondary and secondary.radius==2 and secondary.selffire==0 and secondary.friendlyfire==100,
        'Sun Ray secondary is a self-safe radius-2 ball')
    check(secondary.when and secondary.when.kind=='talent_level' and secondary.when.at_least==3,
        'Sun Ray secondary is gated on effective talent level 3')
end
do
    local flame=Manifest.entry('T_FLAME')
    check(#flame.union==3,'Flame declares the conservative bolt/beam/widebeam union')
    local ground
    for _,component in ipairs(flame.components) do if component.phase=='ground' then ground=component end end
    check(ground and ground.when and ground.when.kind=='attr' and ground.when.id=='burning_wake',
        'Flame Burning Wake is a conditional ground component')
    check(ground.selffire=='unknown' and ground.friendlyfire==100,'Flame ground keeps its dynamic SF and default FF')
end
do
    local rot=Manifest.entry('T_SOUL_ROT')
    local instant
    for _,component in ipairs(rot.components) do if component.phase=='projectile' then instant=component end end
    check(instant and instant.delivery=='projectile' and instant.shape=='bolt',
        'Soul Rot is a projectile bolt')
    check(instant.player_selffire==false,'Soul Rot models the absent player self opt-in')
    local grasp=Manifest.entry('T_BLOOD_GRASP')
    for _,component in ipairs(grasp.components) do if component.phase=='projectile' then instant=component end end
    check(instant.selffire==0 and instant.friendlyfire==0,'Blood Grasp is a self/friendly-safe bolt')
end

-- Derived compatibility view can never disagree with the canonical components.
for talent,entry in pairs(Manifest.ENTRIES) do
    local compat=Manifest.compat(entry)
    check(compat~=nil,'compat view for '..talent)
    if entry.target=='hostile' and not entry.melee then
        check(compat.delivery~=nil,'compat delivery for '..talent)
        check(compat.shape~=nil,'compat shape for '..talent)
    end
end
check(Manifest.compat(Manifest.entry('T_FLAME')).shape=='widebeam','Flame compat reports the widest union member')
check(Manifest.compat(Manifest.entry('T_SOUL_ROT')).delivery=='projectile','Soul Rot compat keeps the projectile delivery')
check(Manifest.compat(Manifest.entry('T_BLOOD_GRASP')).friendlyfire_risk=='none','a safe bolt has no derived line risk')

-- Declarative variants group by condition; no Lua functions in metadata.
do
    local variants=Manifest.variants(Manifest.entry('T_FLAME'))
    local keys={}
    for _,group in ipairs(variants) do
        keys[group.when.kind..':'..tostring(group.when.id or group.when.at_least or group.when.below)]=true
        check(type(group.when)=='table','a variant declares a data condition')
    end
    check(keys['talent_level:5'] and keys['attr:burning_wake'] and keys['attr:archmage_widebeam'],
        'Flame variants cover the level and attribute branches')
end

-- Unsupported dynamic talents are recorded, never silently re-admitted.
for talent,_ in pairs(Manifest.UNSUPPORTED) do
    check(not Manifest.supported(talent),talent..' is not re-admitted')
end
check(Manifest.UNSUPPORTED.T_FIREFLASH and Manifest.UNSUPPORTED.T_STARFALL,'the deferred dynamics are documented')

print('Effect manifest: '..checks..' checks passed')
