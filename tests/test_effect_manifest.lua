-- V2-1: version-pinned, componentised effect manifest.
-- P3-b (TODO #63): derive the addon root from this test's own path so a bare
-- relative invocation fails loudly instead of silently testing the canonical
-- `game/addons/tome-mcp-bridge` tree from another checkout.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
package.path=root..'/overload/?.lua;'..package.path
local Manifest=require 'mod.auto_combat.EffectManifest'
local Schema=require 'mod.auto_combat.PolicySchema'
local Factory=require 'mod.auto_combat.MovementAdapterFactory'
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
-- (or a closed state-variant matrix) and carry no damage components (the guard
-- skips them by source-pinned kind).
for _,talent in ipairs{'T_RUSH','T_SKIRMISHER_CUNNING_ROLL','T_SKIRMISHER_VAULT','T_DIMENSIONAL_STEP','T_PHASE_DOOR'} do
    local entry=Manifest.entry(talent)
    check(entry~=nil and entry.kind=='movement','movement entry for '..talent)
    check(type(entry.movement)=='table','movement adapter declared for '..talent)
    check(#Manifest.requestSequences(entry)>0,'movement adapter declares its target requests for '..talent)
    check(Manifest.SOURCES.talents[talent].action~=nil,'movement action pinned for '..talent)
end
check(Manifest.entry('T_SKIRMISHER_CUNNING_ROLL').movement.landing=='exact','Tumble is an exact grid move')
check(Manifest.entry('T_SKIRMISHER_VAULT').movement.landing=='exact','Vault is an exact grid move')
check(Manifest.entry('T_RUSH').movement.landing=='bounded_alternatives','Rush is an actor-anchored line move')
-- Phase Door is a closed matrix: the no-prompt, precise-grid, TL4 actor and
-- TL4/TL5 actor-then-grid branches are all executable S2 ordered programs.
local phaseDoorSequences=Manifest.requestSequences(Manifest.entry('T_PHASE_DOOR'))
check(#phaseDoorSequences==5 and phaseDoorSequences[1][1]=='none' and phaseDoorSequences[2][1]=='grid',
    'Phase Door declares the no-prompt, precise-grid, TL4 actor and actor+grid request sequences')
local phaseDoorSeen={}
for _,sequence in ipairs(phaseDoorSequences) do phaseDoorSeen[table.concat(sequence,',')]=true end
check(phaseDoorSeen['actor'] and phaseDoorSeen['actor,grid'],
    'Phase Door declares both the TL4 actor-only and the actor+grid ordered programs')
check(Manifest.entry('T_PHASE_DOOR').movement.variants~=nil,'Phase Door declares a state-variant matrix')
check(Manifest.SOURCES.talents['T_PHASE_DOOR'].getters~=nil,'Phase Door pins its dynamic getters')
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
    for _,talent in ipairs({'T_BLINK_RUNE',
        'T_DIMENSIONAL_STEP','T_DISPLACEMENT_SHIELD'}) do
        local entry=unsupportedEntry(talent)
        check(entry~=nil and entry.missing and entry.reason and entry.scope,
            talent..' has a structured unsupported entry')
    end
    -- S2: Phase Door's TL4+ ordered prompt-response queue is implemented, so its
    -- capability gap is gone (only the generic multi-actor swap gap remains).
    check(unsupportedEntry('T_PHASE_DOOR')==nil,
        'Phase Door TL4+ is admitted after the S2 ordered queue')
    check(Manifest.entry('T_PHASE_DOOR').movement.variants~=nil,
        'Phase Door still declares its state-variant matrix')
check(unsupportedEntry('T_SKIRMISHER_VAULT')==nil,'Vault is admitted, not unsupported')
    -- S2-R3-01 rev5: the officially-decided multi-prompt unsupported set, each
    -- with its own typed reason.
    for _,talent in ipairs({'T_MERGE','T_STONE','T_CURSED_BOLT','T_WORMHOLE'}) do
        local u=unsupportedEntry(talent)
        check(u~=nil and u.missing and u.reason and u.scope,
            talent..' has a structured unsupported entry')
    end
    -- Loop 38 audit: the dispositions stand but the typed reasons were
    -- corrected to the honest ones (the signature/postcondition claims were
    -- factually wrong — see unsupported-audit.md §2.3-2.5).
    check(unsupportedEntry('T_MERGE').missing=='moving_or_swapping_another_actor'
        and unsupportedEntry('T_STONE').missing=='moving_or_swapping_another_actor',
        'Merge and Stone are the moving-or-swapping-another-actor typed reason')
    check(unsupportedEntry('T_MERGE').reason:find('target.die(target)',1,true)
        and unsupportedEntry('T_STONE').reason:find('target:move(sx,sy,true)',1,true)
        and unsupportedEntry('T_STONE').reason:find('pass_terrain=true and friendlyblock=false',1,true),
        'Merge/Stone reasons cite the multi-actor engine lines and the corrected signature fact')
    check(unsupportedEntry('T_CURSED_BOLT').missing=='nondeterministic_prompt_subject',
        'Cursed Bolt is the nondeterministic-prompt-subject typed reason')
    check(unsupportedEntry('T_CURSED_BOLT').reason:find('rng.table(shadows)',1,true)
        and unsupportedEntry('T_CURSED_BOLT').reason:find('advanced-shadowmancy.lua:242',1,true)
        and unsupportedEntry('T_CURSED_BOLT').reason:find('player-known',1,true),
        'Cursed Bolt reason cites the random per-iteration subject at the correct engine line (:242) and withdraws the bounded-count claim')
    check(unsupportedEntry('T_WORMHOLE').missing=='effect_is_a_later_triggered_trap_pair',
        'Wormhole is the later-triggered-trap-pair typed reason')
    check(unsupportedEntry('T_WORMHOLE').reason:find('164-207',1,true)
        and unsupportedEntry('T_WORMHOLE').reason:find('teleportRandom at :183',1,true)
        and not unsupportedEntry('T_WORMHOLE').reason:find('simple_dir_request',1,true)
        and not unsupportedEntry('T_WORMHOLE').reason:find('cross_prompt_postcondition',1,true),
        'Wormhole reason cites the trap pair (correct ranges) and withdraws the simple_dir_request/cross-prompt claims')
    -- A' (revised proposal, §6.1-§6.7): the two Earthen Missiles variants ARE
    -- admitted, as STATIONARY multi-projectile programs with a mechanically
    -- validated declared group. The R2-REV-03 withdrawal is SUPERSEDED: the
    -- per-missile crit roll is an ANNOTATION, not a refusal, because the executor
    -- is arrival-ordered by construction (`Actions.lua`: the k-th OBSERVED prompt
    -- is answered with `plan[k]`). What remains unobservable is SOURCE-SLOT
    -- identity inside a same-signature group, which is published as a limitation.
    for _,talent in ipairs{'T_EARTHEN_MISSILES','T_DWARVEN_HALF_EARTHEN_MISSILES'} do
        check(Manifest.entry(talent)~=nil,talent..' is admitted (A-prime)')
        check(unsupportedEntry(talent)==nil,talent..' has no typed unsupported row')
        check(Manifest.SOURCES.talents[talent]~=nil,talent..' keeps its advisory source pin')
        local entry=Manifest.entry(talent)
        check(entry.kind=='movement' and entry.target=='grid',talent..' is a grid movement entry')
        check(entry.movement.variants~=nil,' A-prime '..talent..' declares its talent_level variant matrix')
        check(entry.movement.variants[1].movement.delivery=='stationary'
            and entry.movement.variants[2].movement.delivery=='stationary',
            talent..' resolves to the stationary delivery (guard routing consequence)')
        check(entry.movement.variants[1].movement.group_members~=nil
            and #entry.movement.variants[1].movement.group_members==1
            and #entry.movement.variants[1].movement.group_members[1].indexes==2,
            talent..' below TL5 declares exactly one 2-member group')
        check(#entry.movement.variants[2].movement.group_members[1].indexes==3,
            talent..' at TL5+ declares one 3-member group (existing talent_level matrix)')
        check(#entry.movement.variants[1].movement.target_requests==2
            and #entry.movement.variants[2].movement.target_requests==3,
            talent..' target_requests follow the declared program length')
        -- Every stationary entry is a grid prompt answered from the plan.
        for _,variant in ipairs(entry.movement.variants) do
            for _,seqEntry in ipairs(variant.movement.request_sequence) do
                check(seqEntry.request=='grid' and seqEntry.value_source=='target_plan',
                    talent..' stationary entries are grid/target_plan')
            end
        end
    end
    -- UNION: the A′ relaxation surface EXISTS and is mechanically validated
    -- (kept from A′); the dwarven specs carry friendlyfire=false AND
    -- friendlyblock=false at every position (gifts/dwarven-nature.lua:34,41,49):
    -- the signature records the allowlisted `friendlyblock=false` and the
    -- component declares the explicit friendly filter. The regular variant has
    -- neither field in its local spec, so its signature declares only
    -- `cursor_type` and it carries engine defaults.
    do
        local dwarf=Manifest.entry('T_DWARVEN_HALF_EARTHEN_MISSILES')
        check(dwarf.movement.variants[1].movement.request_sequence[1].observed.friendlyblock==false
            and dwarf.movement.variants[1].movement.request_sequence[2].observed.friendlyblock==false,
            'the dwarven signature declares friendlyblock=false at every prompt')
        check(dwarf.components[1].friendlyfire==0,'the dwarven friendly filter is explicitly 0')
        local reg=Manifest.entry('T_EARTHEN_MISSILES')
        check(reg.movement.variants[1].movement.request_sequence[1].observed.friendlyblock==nil,
            'the regular signature declares no friendlyblock (the local spec has none)')
        check(reg.components[1].friendlyfire==100 and reg.components[1].selffire==100,
            'the regular variant keeps the engine default filters (true)')
    end
    check(Factory.TEMPLATES.stationary_sequence~=nil
        and Factory.TEMPLATES.stationary_sequence.stationary==true,
        'the closed stationary_sequence template exists and is flagged stationary')
    check(type(Factory.validGroupKey)=='function' and type(Factory.groupMembership)=='function'
        and type(Factory.groupOf)=='function' and type(Factory.signatureEquals)=='function',
        'the mechanically validated group vocabulary exists')
    check(Factory.DELIVERIES.stationary==true and Factory.LANDINGS.none==true
        and Factory.CENTERS.none==true,
        'the stationary delivery/landing/center enum members exist')
    -- A′ §6.6: the capability summary publishes the stationary delivery and the
    -- per-projectile random-crit uncertainty (never a refusal, never prose-only).
    do
        local summary=Manifest.summary()
        local byTalent={}
        for _,item in ipairs(summary.talents) do byTalent[item.talent]=item end
        for _,talent in ipairs{'T_EARTHEN_MISSILES','T_DWARVEN_HALF_EARTHEN_MISSILES'} do
            local item=byTalent[talent]
            check(item and item.outcome_uncertainty=='per_projectile_random_crit',
                talent..' publishes outcome_uncertainty=per_projectile_random_crit')
            check(item and item.stationary==true,'A-prime '..talent..' is published as stationary')
            check(item and type(item.limitations)=='table' and #item.limitations>=3,
                talent..' publishes its residual limitations')
        end
        check(byTalent['T_PHASE_DOOR'] and byTalent['T_PHASE_DOOR'].outcome_uncertainty==nil,
            'a mover descriptor publishes no stationary uncertainty')
    end
    -- The relaxation is MATCHING ONLY and only for declared groups: the strict
    -- EXACTLY-ONE rule still holds for every ungrouped descriptor.
    check(Manifest.entry('T_PHASE_DOOR').movement.variants[4].movement.group_members~=nil
        and #Manifest.entry('T_PHASE_DOOR').movement.variants[4].movement.group_members==0,
        'Phase Door declares no group (its ungrouped prompts keep the exactly-one rule)')
    -- UNION (arm2 supersedes A′'s older "Vault reserved for S3" state): the
    -- agility Vault (techniques/agility.lua) is ADMITTED through the mixed
    -- movement/effect composition (V-U6): a mixed entry with two
    -- distinguishable prompts and two direct components, and its UNSUPPORTED
    -- row is gone. The acrobatics T_SKIRMISHER_VAULT below stays
    -- component-free and unchanged (V-U6).
    local agilityVault=Manifest.entry('T_VAULT')
    check(agilityVault~=nil and agilityVault.kind=='movement','the agility Vault is admitted (V-U6)')
    check(#Manifest.requestSequences(agilityVault)>0
        and Manifest.requestSequences(agilityVault)[1][1]=='actor'
        and Manifest.requestSequences(agilityVault)[1][2]=='grid',
        'the agility Vault declares the ordered actor-then-grid request sequence (V-U1)')
    check(Schema.TALENTS['T_VAULT']==true,'the agility Vault is a schema talent (V-U6)')
    check(Manifest.SOURCES.talents['T_VAULT']~=nil,'the admitted agility Vault carries its source pin')
    -- T_SKIRMISHER_VAULT (acrobatics) is a DIFFERENT, single-prompt pure-movement
    -- talent and stays admitted unchanged.
    local skirmisherVault=Manifest.entry('T_SKIRMISHER_VAULT')
    check(skirmisherVault~=nil and skirmisherVault.kind=='movement'
        and skirmisherVault.movement.landing=='exact'
        and skirmisherVault.movement.traverses==false,
        'T_SKIRMISHER_VAULT stays a single-prompt exact pure-movement descriptor')
    check(unsupportedEntry('T_SKIRMISHER_VAULT')==nil,
        'T_SKIRMISHER_VAULT is still admitted, not unsupported')
    local step=unsupportedEntry('T_DIMENSIONAL_STEP')
    check(step~=nil and step.missing=='moving_or_swapping_another_actor',
        'Dimensional Step TL5 is the swap capability gap')
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
