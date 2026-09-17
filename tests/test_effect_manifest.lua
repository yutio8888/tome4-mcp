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
    check(entry.source==pin,'the entry carries its source identity')
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
    local bolt,ground
    for _,component in ipairs(flame.components) do
        if component.id=='flame_bolt' then bolt=component end
        if component.phase=='ground' then ground=component end
    end
    check(bolt and bolt.delivery=='projectile','Flame\'s below-TL5 bolt is a projectile branch')
    check(ground and ground.when and ground.when.kind=='attr' and ground.when.id=='burning_wake',
        'Flame Burning Wake is a conditional ground component')
    check(ground.duration==4 and ground.per_grid==true,
        'Burning Wake is a duration-4 zone on every projected grid')
    check(ground.selffire=='unknown' and ground.friendlyfire==100,'Flame ground keeps its dynamic SF and default FF')
end
do
    local rot=Manifest.entry('T_SOUL_ROT')
    local instant
    for _,component in ipairs(rot.components) do if component.phase=='projectile' then instant=component end end
    check(instant and instant.delivery=='projectile' and instant.shape=='bolt',
        'Soul Rot is a projectile bolt')
    check(instant.player_selffire==nil,'Soul Rot leaves the per-projectile opt-in absent, not false')
    local grasp=Manifest.entry('T_BLOOD_GRASP')
    for _,component in ipairs(grasp.components) do if component.phase=='projectile' then instant=component end end
    check(instant.selffire==0 and instant.friendlyfire==0,'Blood Grasp is a self/friendly-safe bolt')
end

-- Derived compatibility view can never disagree with the canonical components.
for talent,entry in pairs(Manifest.ENTRIES) do
    local compat=Manifest.compat(entry)
    check(compat~=nil,'compat view for '..talent)
    if entry.kind~='movement' and entry.target=='hostile' and not entry.melee then
        check(compat.delivery~=nil,'compat delivery for '..talent)
        check(compat.shape~=nil,'compat shape for '..talent)
    end
end
-- Movement entries declare their exact native request/landing classification
-- and carry no damage components (the guard skips them by source-pinned kind).
for _,talent in ipairs{'T_RUSH','T_SKIRMISHER_CUNNING_ROLL','T_PHASE_DOOR'} do
    local entry=Manifest.entry(talent)
    check(entry~=nil and entry.kind=='movement','movement entry for '..talent)
    check(type(entry.movement)=='table' and type(entry.movement.target_requests)=='table',
        'movement adapter declares its target requests for '..talent)
end
check(Manifest.entry('T_PHASE_DOOR').movement.landing=='random','Phase Door is a random teleport')
check(Manifest.entry('T_SKIRMISHER_CUNNING_ROLL').movement.landing=='exact','Tumble is an exact grid move')
check(Manifest.entry('T_RUSH').movement.landing=='bounded_alternatives','Rush is an actor-anchored line move')
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

-- The four dynamic talents are re-admitted with source-verified components; the
-- structured unsupported list is about movement gaps only (MFT-REV-08).
local function unsupportedFor(talent)
    for _,entry in ipairs(Manifest.UNSUPPORTED) do if entry.talent==talent then return entry end end
    return nil
end
check(unsupportedFor('T_FLAMESHOCK')==nil and unsupportedFor('T_FIREFLASH')==nil
    and unsupportedFor('T_SHADOW_BLAST')==nil and unsupportedFor('T_STARFALL')==nil,
    'the dynamic talents are no longer unsupported')
-- MFT-REV-08: every documented movement/effect gap has a structured unsupported
-- entry (talent, scope, missing capability, reason).
do
    local function unsupportedEntry(talent)
        for _,entry in ipairs(Manifest.UNSUPPORTED) do
            if entry.talent==talent then return entry end
        end
        return nil
    end
    for _,talent in ipairs({'T_PHASE_DOOR','T_BLINK_RUNE','T_SKIRMISHER_VAULT',
        'T_DIMENSIONAL_STEP','T_SHADOWSTEP','T_GIANT_LEAP','T_DISPLACEMENT_SHIELD'}) do
        local entry=unsupportedEntry(talent)
        check(entry~=nil and entry.missing and entry.reason and entry.scope,
            talent..' has a structured unsupported entry')
    end
    local shield=unsupportedEntry('T_DISPLACEMENT_SHIELD')
    check(shield~=nil and shield.missing=='source_reviewed_effect_adapter',
        'Displacement Shield is listed as an unreviewed effect adapter')
end
for _,talent in ipairs({'T_FLAMESHOCK','T_FIREFLASH','T_SHADOW_BLAST','T_STARFALL'}) do
    local entry=Manifest.entry(talent)
    check(entry~=nil,talent..' is re-admitted')
    check(entry.conformance and entry.conformance.builder==true,talent..' declares a native builder')
    check(unsupportedFor(talent)==nil,talent..' is no longer unsupported')
    check(Manifest.SOURCES.talents[talent].builder~=nil,talent..' pins its builder line')
    local instant
    for _,component in ipairs(entry.components) do
        if component.phase=='instant' then instant=component end
    end
    check(instant~=nil,talent..' has an instant component')
    if talent=='T_FLAMESHOCK' then
        -- The instant cone is explicitly self-safe; its dynamic input is the
        -- Burning Wake ground component checked below.
        check(instant.selffire==0,talent..' instant cone is explicitly self-safe')
    else
        check(type(instant.selffire)=='table' and instant.selffire.dynamic=='spellFriendlyFire',
            talent..' pins its instant selffire to the audited spellFriendlyFire input')
    end
end
-- Ground/secondary honesty for the re-admitted talents.
do
    local fireflash=Manifest.entry('T_FIREFLASH')
    local ground
    for _,component in ipairs(fireflash.components) do if component.phase=='ground' then ground=component end end
    check(ground and ground.duration==4 and ground.when and ground.when.id=='burning_wake',
        'Fireflash Burning Wake is a duration-4 impact ball')
    check(ground.radius and ground.radius.from=='target','Fireflash ground radius comes from the live builder')
    check(ground.friendlyfire==100,'Fireflash ground FF defaults to true')
    check(fireflash.components[2].player_selffire==true,'Fireflash is a player projectile with the self opt-in')
    local flameshock=Manifest.entry('T_FLAMESHOCK')
    local flameshock_ground, flameshock_instant
    for _,component in ipairs(flameshock.components) do
        if component.phase=='ground' then flameshock_ground=component end
        if component.phase=='instant' then flameshock_instant=component end
    end
    check(flameshock_ground and flameshock_ground.center=='self' and flameshock_ground.shape=='cone'
        and flameshock_ground.direction=='target' and flameshock_ground.duration==4,
        'Flameshock Burning Wake is a source-centred duration-4 cone aimed at the target')
    check(flameshock_instant.selffire==0,'Flameshock instant cone is explicitly self-safe')
    local shadow=Manifest.entry('T_SHADOW_BLAST')
    local shadow_ground
    for _,component in ipairs(shadow.components) do if component.phase=='ground' then shadow_ground=component end end
    check(shadow_ground and shadow_ground.shape=='ball' and shadow_ground.radius==3,
        'Shadow Blast has a persistent radius-3 ball')
    local starfall=Manifest.entry('T_STARFALL')
    local starfall_ground=false
    for _,component in ipairs(starfall.components) do if component.phase=='ground' then starfall_ground=true end end
    check(not starfall_ground,'Starfall has no persistent ground component')
end

print('Effect manifest: '..checks..' checks passed')
