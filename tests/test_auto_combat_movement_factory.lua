-- S1: closed movement-adapter factory + Phase Door variant matrix + source pins.
--
-- These are pure unit tests over the factory and the planner's variant/bounds
-- resolution. They are non-tautological: each asserts the exact expanded
-- descriptor (a wrong default/field fails) and every indeterminate condition
-- produces the typed fail-closed reason. No engine or RNG is touched.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Factory=require 'mod.auto_combat.MovementAdapterFactory'
local Planner=require 'mod.auto_combat.MovementPlanner'
local Manifest=require 'mod.auto_combat.EffectManifest'
local Drift=require 'mod.auto_combat.EffectManifestDrift'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function requestList(movement)
    if movement.variants then
        local out={}
        for _,variant in ipairs(movement.variants) do
            if variant.movement then out[#out+1]=variant.movement.target_requests end
        end
        return out
    end
    return {movement.target_requests}
end

-- 1. Template expansion: exact mechanical defaults + per-talent params --------
do
    local rush=assert(Factory.expand('actor_charge',{landing_proof='line proof'}))
    check(rush.target_requests[1]=='actor' and #rush.target_requests==1,
        'actor_charge defaults to a single actor request')
    check(rush.delivery=='line_move' and rush.landing=='bounded_alternatives'
        and rush.center=='actor' and rush.traverses==true and rush.relocates_other==false,
        'actor_charge defaults match the reviewed Rush shape')
    check(rush.landing_proof=='line proof','the per-talent landing proof is retained')

    local tumble=assert(Factory.expand('grid_move_exact',{delivery='line_move',traverses=true,
        landing_proof='exact'}))
    check(tumble.target_requests[1]=='grid' and tumble.landing=='exact'
        and tumble.center=='requested_grid' and tumble.relocates_other==false,
        'grid_move_exact defaults to the requested-grid exact landing')
    check(tumble.delivery=='line_move' and tumble.traverses==true,
        'grid_move_exact keeps the per-talent delivery/traverses')

    local vault=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        landing_proof='exact'}))
    check(vault.delivery=='leap' and vault.traverses==false,
        'Vault differs from Tumble only in the reviewed delivery/traverses')

    local blink=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=5,landing_proof='findFreeGrid radius 5'}))
    check(blink.landing=='bounded_alternatives' and blink.radius==5 and blink.min_radius==0,
        'grid_move_bounded declares a finite bounded envelope with a zero minimum')
    check(blink.center=='requested_grid' and blink.traverses==false,
        'grid_move_bounded keeps the requested centre and no traversal')

    local door=assert(Factory.expand('self_random_teleport',{radius={getter='getRange'},
        min_radius=0,landing_proof='no prompt'}))
    check(door.target_requests[1]=='none' and door.landing=='random' and door.center=='self',
        'self_random_teleport defaults to the no-prompt random self landing')
    check(type(door.radius)=='table' and door.radius.getter=='getRange',
        'self_random_teleport keeps the audited dynamic radius declaration')

    local shadow=assert(Factory.expand('actor_anchor_teleport',{radius={getter='getRadius'},
        landing_proof='actor anchor'}))
    check(shadow.target_requests[1]=='actor' and shadow.center=='actor'
        and shadow.traverses==false and shadow.landing=='bounded_alternatives',
        'actor_anchor_teleport defaults to the actor-anchored bounded landing')
end

-- 2. Expansion is canonical (order-independent) and closed -------------------
do
    local function expandBoth()
        local a=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
            radius=5,landing_proof='p'}))
        local b=assert(Factory.expand('grid_move_bounded',{landing_proof='p',radius=5,
            traverses=false,delivery='teleport'}))
        return a,b
    end
    local a,b=expandBoth()
    check(a.delivery==b.delivery and a.landing==b.landing and a.radius==b.radius
        and a.traverses==b.traverses and a.min_radius==b.min_radius,
        'two expansions with different insertion order are field-equivalent')

    local bad,err=Factory.expand('no_such_template',{})
    check(bad==nil and err.reason=='movement_adapter_invalid' and err.detail=='unknown_template',
        'an unknown template is movement_adapter_invalid')
    bad,err=Factory.expand('actor_charge',{})
    check(bad==nil and err.reason=='movement_adapter_invalid' and err.key=='landing_proof',
        'a missing required parameter is movement_adapter_invalid')
    bad,err=Factory.expand('actor_charge',{landing_proof='x',not_a_field=true})
    check(bad==nil and err.reason=='movement_adapter_invalid' and err.key=='not_a_field',
        'an unknown parameter key is rejected (closed key set)')
    bad,err=Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=-1,landing_proof='x'})
    check(bad==nil and err.detail=='bad_radius','a negative envelope is rejected')
    bad,err=Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=0/0,landing_proof='x'})
    check(bad==nil and err.detail=='bad_radius','a non-finite envelope is rejected')
    bad,err=Factory.expand('grid_move_exact',{delivery='teleport',traverses='yes'})
    check(bad==nil and err.detail=='bad_traverses','a non-boolean traverses is rejected')
end

-- 3. Phase Door variant matrix: every (level, precise) cell ------------------
do
    local function read(level,precise)
        return {talentLevel=function() return level end,
            attr=function(id)
                if id~='phase_door_force_precise' then return nil,false end
                return precise,true
            end}
    end
    local function resolve(level,precise)
        return Factory.resolveVariant(Manifest.entry('T_PHASE_DOOR').movement,'T_PHASE_DOOR',
            read(level,precise))
    end
    local none=assert(resolve(1,false))
    check(none.target_requests[1]=='none' and none.landing=='random',
        'TL<4 without the precise attribute resolves to the no-prompt random leaf')
    local precise=assert(resolve(1,true))
    check(precise.target_requests[1]=='grid' and precise.landing=='bounded_alternatives',
        'TL<4 with the precise attribute resolves to the precise grid leaf')
    check(precise.fallback_center=='self' and precise.fallback_radius~=nil,
        'the precise grid leaf carries its LOS fallback envelope')

    -- Known TL4+ is the ordered-queue capability gap, not a silent no-prompt.
    local gap,gapErr=resolve(4,false)
    check(gap==nil and gapErr.reason=='unsupported_movement_variant'
        and gapErr.missing=='actor_then_grid_target_plan',
        'TL4+ resolves to the ordered-queue capability gap')
    local gap5,gap5Err=resolve(5,true)
    check(gap5==nil and gap5Err.reason=='unsupported_movement_variant'
        and gap5Err.missing=='actor_then_grid_target_plan',
        'TL5 resolves to the ordered-queue capability gap')

    -- Unknown level or attribute must never submit the no-prompt leaf.
    local unknownLevel,levelErr=resolve('unknown',false)
    check(unknownLevel==nil and levelErr.reason=='movement_variant_unknown',
        'an unknown effective level is movement_variant_unknown')
    local unknownAttr,attrErr=Factory.resolveVariant(Manifest.entry('T_PHASE_DOOR').movement,
        'T_PHASE_DOOR',{talentLevel=function() return 1 end,
            attr=function() return nil,false end})
    check(unknownAttr==nil and attrErr.reason=='movement_variant_unknown',
        'an unknown phase_door_force_precise read is movement_variant_unknown')

    -- Overlap and no-match are both non-determinability, never an ordering pick.
    local overlapping=Factory.matrix({
        {when={kind='talent_level',below=5},template='self_random_teleport',
            params={radius=1,landing_proof='a'}},
        {when={kind='talent_level',below=6},template='self_random_teleport',
            params={radius=1,landing_proof='b'}},
    })
    local multi,multiErr=Factory.resolveVariant(overlapping,'T_PHASE_DOOR',read(1,false))
    check(multi==nil and multiErr.reason=='movement_variant_unknown'
        and multiErr.detail=='multiple_matches',
        'overlapping variant matches are movement_variant_unknown')
    local unmatched=Factory.matrix({
        {when={kind='talent_level',at_least=9},template='self_random_teleport',
            params={radius=1,landing_proof='a'}},
    })
    local zero,zeroErr=Factory.resolveVariant(unmatched,'T_PHASE_DOOR',read(1,false))
    check(zero==nil and zeroErr.reason=='movement_variant_unknown'
        and zeroErr.detail=='no_match',
        'zero variant matches are movement_variant_unknown')
end

-- 3b. The S2 ordered Phase Door plan is a declared capability, not a schema
-- error: static verification accepts it and plan time returns the typed gap.
do
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local ok=Manifest.verify({sustains={},rules={
        {id='door',priority=1,when={always={}},['then']={action='use_talent',
            talent='T_PHASE_DOOR',target='self',
            target_plan={{request='actor',selector='self'},
                {request='grid',destination={selector='relative',dx=1,dy=0,accept=accept}}}}}}})
    check(ok==true,'the Phase Door TL4+ ordered plan validates statically as a declared capability')
    local bad,errors=Manifest.verify({sustains={},rules={
        {id='door',priority=1,when={always={}},['then']={action='use_talent',
            talent='T_PHASE_DOOR',target='self',
            target_plan={{request='grid',destination={selector='relative',dx=1,dy=0,accept=accept}},
                {request='actor',selector='self'}}}}}})
    check(bad==nil and errors and errors[1].code=='target_plan_mismatch',
        'a reordered request plan is rejected against the declared sequences')
end

-- 4. Dynamic envelope bounds: audited getter only ----------------------------
do
    local movement=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius={getter='getRadius'},min_radius=0,landing_proof='p'}))
    local bounds,err=Factory.resolveBounds(movement,'T_PHASE_DOOR',{})
    check(bounds==nil and err.reason=='movement_derivation_unknown'
        and err.dependency=='getRadius',
        'a missing getter reader is movement_derivation_unknown')
    bounds,err=Factory.resolveBounds(movement,'T_PHASE_DOOR',{talentGetter=function() return 1/0 end})
    check(bounds==nil and err.reason=='movement_derivation_unknown',
        'a non-finite getter value is movement_derivation_unknown')
    bounds,err=Factory.resolveBounds(movement,'T_PHASE_DOOR',{talentGetter=function() return 5 end})
    check(err==nil and bounds.radius==5,'a finite getter value resolves the envelope')
    -- min/max clamping is a mechanical bound, not a fabricated default.
    local clamped=assert(Factory.resolveBounds(
        assert(Factory.expand('self_random_teleport',{radius={getter='r',min=1,max=4},
            landing_proof='p'})),'T_X',{talentGetter=function() return 9 end}))
    check(clamped.radius==4,'an audited getter value is clamped to the declared maximum')

    -- The planner surfaces the derivation unknown before commit.
    local planned,planErr=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',
            accept={visibility='any',passability='native',hazard='any',landing='allow_random'}}},
        {origin=function() return {x=2,y=2} end,talentLevel=function() return 1 end,
            attr=function() return nil,true end},
        Manifest.entry('T_PHASE_DOOR').movement)
    check(planned==nil and planErr.reason=='movement_derivation_unknown',
        'the planner fails closed when a dynamic bound cannot be resolved')
end

-- 5. Grid requests with a bounded/random adapter are annotated as such -------
do
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local provider={origin=function() return {x=2,y=2} end,
        knowledge=function() return {in_bounds=true} end}
    local blink=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=5,landing_proof='p'}))
    local plan=assert(Planner.planTalent({selector='position',x=5,y=5,accept=accept},
        provider,nil,blink))
    check(plan.annotation.landing.kind=='bounded' and plan.annotation.landing.radius==5,
        'a bounded grid adapter annotates the landing as bounded, not deterministic')
    local strict=Planner.planTalent({selector='position',x=5,y=5,
        accept={visibility='any',passability='native',hazard='any',landing='deterministic'}},
        provider,nil,blink)
    check(strict==nil,'landing=deterministic rejects the bounded grid landing')
    local exact=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        landing_proof='p'}))
    local ex=assert(Planner.planTalent({selector='position',x=5,y=5,accept=accept},
        provider,nil,exact))
    check(ex.annotation.landing.kind=='deterministic',
        'an exact grid adapter keeps the deterministic landing annotation')
end

-- 6. Drift: action + getter identity pins fail closed ------------------------
do
    local function fnAt(path,line,marker)
        local lines={}
        for i=1,line-1 do lines[i]='' end
        lines[line]='return function(self,t) return {marker='..marker..'} end'
        return assert(loadstring(table.concat(lines,'\n'),'@'..path))()
    end
    local path='/data/t/move.lua'
    local manifest={ENTRIES={T_MOVE={kind='movement',conformance={builder=false},
        source={action={path=path,line=2},
            getters={getRange={path=path,line=3}}}}}}
    local live={T_MOVE={action=fnAt(path,2,1),getRange=fnAt(path,3,1)}}
    Drift.reset()
    check(Drift.identity(manifest,function(t) return live[t] end)==true,
        'a movement entry with pinned action/getter identity passes')
    local replaced={T_MOVE={action=fnAt(path,4,1),getRange=live.T_MOVE.getRange}}
    local bad,reason=Drift.identity(manifest,function(t) return replaced[t] end)
    check(bad==nil and reason==Drift.REASON,'a replaced action fails closed')
    local replacedGetter={T_MOVE={action=live.T_MOVE.action,getRange=fnAt(path,5,1)}}
    local bad2,reason2=Drift.identity(manifest,function(t) return replacedGetter[t] end)
    check(bad2==nil and reason2==Drift.REASON,'a replaced getter fails closed')
    local unpinned={ENTRIES={T_MOVE={kind='movement',conformance={builder=false},
        source={getters={getRange={path=path,line=3}}}}}}
    local bad3,reason3=Drift.identity(unpinned,function(t) return live[t] end)
    check(bad3==nil and reason3==Drift.REASON,'a movement entry without an action pin fails closed')
    -- A distinct closure at the same source/line is a replacement and never
    -- overwrites the trusted baseline.
    Drift.reset()
    local upFactory=assert(loadstring('local captured=...\nreturn function(self,t) return {v=captured} end','@'..path))
    local a=upFactory(1)
    local b=upFactory(2)
    local upManifest={ENTRIES={T_MOVE={kind='movement',conformance={builder=false},
        source={action={path=path,line=2},getters={getRange={path=path,line=3}}}}}}
    check(rawequal(a,b)==false and string.dump(a)==string.dump(b),
        'the same-line replacement fixture is distinct but byte-identical')
    check(Drift.identity(upManifest,function() return {action=a,getRange=live.T_MOVE.getRange} end)==true,
        'the first action establishes the trusted baseline')
    local rep,repReason=Drift.identity(upManifest,function() return {action=b,getRange=live.T_MOVE.getRange} end)
    check(rep==nil and repReason==Drift.REASON,
        'a same-line distinct action closure is rejected')
    check(Drift.identity(upManifest,function() return {action=a,getRange=live.T_MOVE.getRange} end)==true,
        'the rejected replacement did not overwrite the baseline')
    Drift.reset()
end

print('Movement adapter factory: '..checks..' checks passed')
