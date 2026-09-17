-- S1 (rev 2): closed movement-adapter factory + Phase Door matrix + audit order.
--
-- Pure unit tests over the factory and the planner. They are non-tautological:
-- each asserts the exact expanded descriptor (a wrong default/field fails),
-- every indeterminate condition produces the typed fail-closed reason, a fixed
-- template invariant cannot be overridden, and the drift preflight runs before
-- any dynamic reader is called.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Factory=require 'mod.auto_combat.MovementAdapterFactory'
local Planner=require 'mod.auto_combat.MovementPlanner'
local Manifest=require 'mod.auto_combat.EffectManifest'
local Drift=require 'mod.auto_combat.EffectManifestDrift'
local Distance=require 'mod.mcp_bridge.Distance'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local ACCEPT={visibility='any',passability='native',hazard='any',landing='allow_random'}

local function provider(overrides)
    local p={preflight=function() return true end,
        origin=function() return {x=20,y=20} end,
        anchor=function(_,bound) return {x=30,y=20} end,
        talentLevel=function() return 1 end,
        attr=function() return nil,true end,
        talentGetter=function() return 6 end,
        builder=function() return {shape='hit',range=8} end,
        occupancy=function() return 'empty' end,
        knowledge=function() return {in_bounds=true,visible=true,passable=true,hazard=false} end}
    for k,v in pairs(overrides or {}) do p[k]=v end
    return p
end

-- 1. Template expansion: exact mechanical defaults + per-talent params --------
do
    local rush=assert(Factory.expand('actor_charge',{landing_proof='line proof',builder_shape='bolt'}))
    check(rush.target_requests[1]=='actor' and #rush.target_requests==1,
        'actor_charge defaults to a single actor request')
    check(rush.delivery=='line_move' and rush.landing=='bounded_alternatives'
        and rush.center=='actor' and rush.traverses==true and rush.relocates_other==false,
        'actor_charge defaults match the reviewed Rush shape')
    check(rush.landing_proof=='line proof' and rush.builder_shape=='bolt',
        'the per-talent landing proof/builder shape are retained')

    local tumble=assert(Factory.expand('grid_move_exact',{delivery='line_move',traverses=true,
        builder_shape='beam',landing_proof='exact'}))
    check(tumble.target_requests[1]=='grid' and tumble.landing=='exact'
        and tumble.center=='requested_grid' and tumble.relocates_other==false,
        'grid_move_exact defaults to the requested-grid exact landing')
    check(tumble.delivery=='line_move' and tumble.traverses==true and tumble.builder_shape=='beam',
        'grid_move_exact keeps the per-talent delivery/traverses/builder')

    local blink=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=5,landing_proof='findFreeGrid radius 5'}))
    check(blink.landing=='bounded_alternatives' and blink.radius==5 and blink.min_radius==0,
        'grid_move_bounded declares a finite bounded envelope with a zero minimum')

    local door=assert(Factory.expand('self_random_teleport',{radius={getter='getRange'},
        min_radius=0,landing_proof='no prompt'}))
    check(door.target_requests[1]=='none' and door.landing=='random' and door.center=='self',
        'self_random_teleport defaults to the no-prompt random self landing')
    check(type(door.radius)=='table' and door.radius.getter=='getRange',
        'self_random_teleport keeps the audited dynamic radius declaration')

    local anchor=assert(Factory.expand('actor_anchor_teleport',{radius={getter='getRadius'},
        landing_proof='actor anchor'}))
    check(anchor.target_requests[1]=='actor' and anchor.center=='actor'
        and anchor.traverses==false and anchor.relocates_other==false,
        'actor_anchor_teleport is an actor-anchored non-relocating self teleport')
end

-- 2. Expansion is canonical and closed; template invariants cannot be overridden
do
    local a=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=5,landing_proof='p'}))
    local b=assert(Factory.expand('grid_move_bounded',{landing_proof='p',radius=5,
        traverses=false,delivery='teleport'}))
    check(a.delivery==b.delivery and a.landing==b.landing and a.radius==b.radius
        and a.traverses==b.traverses and a.min_radius==b.min_radius,
        'two expansions with different insertion order are field-equivalent')

    -- MAF-REV-05: a fixed template invariant cannot be parameterized.
    local bad,err=Factory.expand('actor_charge',{landing_proof='p',delivery='teleport'})
    check(bad==nil and err.reason=='movement_adapter_invalid' and err.detail=='fixed_field'
        and err.key=='delivery','actor_charge rejects a delivery override')
    bad,err=Factory.expand('actor_charge',{landing_proof='p',center='self'})
    check(bad==nil and err.detail=='fixed_field' and err.key=='center',
        'actor_charge rejects a centre override')
    bad,err=Factory.expand('actor_anchor_teleport',{landing_proof='p',radius=5,relocates_other=true})
    check(bad==nil and err.detail=='fixed_field' and err.key=='relocates_other',
        'actor_anchor_teleport rejects a relocation override')
    bad,err=Factory.expand('grid_move_exact',{delivery='leap',traverses=false,target_requests={'actor'}})
    check(bad==nil and err.detail=='fixed_field','grid_move_exact rejects a request-kind override')

    bad,err=Factory.expand('no_such_template',{})
    check(bad==nil and err.detail=='unknown_template','an unknown template is movement_adapter_invalid')
    bad,err=Factory.expand('actor_charge',{})
    check(bad==nil and err.detail=='missing_required' and err.key=='landing_proof',
        'a missing required parameter is movement_adapter_invalid')
    bad,err=Factory.expand('actor_charge',{landing_proof='x',not_a_field=true})
    check(bad==nil and err.detail=='unknown_key','an unknown parameter key is rejected')
    bad,err=Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=-1,landing_proof='x'})
    check(bad==nil and err.detail=='bad_radius','a negative envelope is rejected')
    bad,err=Factory.expand('self_random_teleport',{radius={getter='getRange',bogus=1},
        landing_proof='x'})
    check(bad==nil and err.detail=='bad_radius','an open nested getter record is rejected')
    bad,err=Factory.expand('grid_move_exact',{delivery='teleport',traverses='yes'})
    check(bad==nil and err.detail=='bad_traverses','a non-boolean traverses is rejected')
end

-- 3. Phase Door matrix: all cells, both axes pre-read, typed S2 reason --------
do
    local movement=Manifest.entry('T_PHASE_DOOR').movement
    local calls=0
    local function read(level,known,value)
        return {talentLevel=function() return level end,
            attr=function(id)
                calls=calls+1
                if id~='phase_door_force_precise' then return nil,false end
                if not known then return nil,false end
                return value,true
            end}
    end
    local none=assert(Factory.resolveVariant(movement,'T_PHASE_DOOR',read(1,true,false)))
    check(none.target_requests[1]=='none' and none.landing=='random',
        'TL<4 without the precise attribute is the no-prompt random leaf')
    local precise=assert(Factory.resolveVariant(movement,'T_PHASE_DOOR',read(1,true,true)))
    check(precise.target_requests[1]=='grid' and precise.landing=='bounded_alternatives'
        and precise.fallback_center=='self','TL<4 with the precise attribute is the precise grid leaf')

    -- MAF-REV-01: TL4+ with a known attribute is the ordered-queue capability
    -- gap, published as the runtime `unsupported_target_plan` reason the live and
    -- dry-run controllers pause on.
    local gap,gapErr=Factory.resolveVariant(movement,'T_PHASE_DOOR',read(4,true,false))
    check(gap==nil and gapErr.reason=='unsupported_target_plan' and gapErr.scope=='multi_prompt'
        and gapErr.missing=='actor_then_grid_target_plan',
        'TL4 with a known attribute resolves to the ordered-queue pause reason')
    local gap5,gap5Err=Factory.resolveVariant(movement,'T_PHASE_DOOR',read(5,true,true))
    check(gap5==nil and gap5Err.reason=='unsupported_target_plan',
        'TL5 with a known attribute resolves to the ordered-queue pause reason')
    -- Every remaining cell: TL4 precise, TL5 non-precise, and the unknown axis
    -- at both levels fail closed with the correct typed reason.
    local tl4p,tl4pErr=Factory.resolveVariant(movement,'T_PHASE_DOOR',read(4,true,true))
    check(tl4p==nil and tl4pErr.reason=='unsupported_target_plan','TL4 with the precise attribute is the pause reason')
    local tl5f,tl5fErr=Factory.resolveVariant(movement,'T_PHASE_DOOR',read(5,true,false))
    check(tl5f==nil and tl5fErr.reason=='unsupported_target_plan','TL5 without the precise attribute is the pause reason')
    local tl5u,tl5uErr=Factory.resolveVariant(movement,'T_PHASE_DOOR',read(5,false,nil))
    check(tl5u==nil and tl5uErr.reason=='movement_variant_unknown','TL5 with an unknown attribute fails closed')

    -- MAF-REV-01: an unavailable attribute at TL4+ is still read (axes) and
    -- yields movement_variant_unknown, never a branch that skipped the read.
    calls=0
    local unknownAttr,attrErr=Factory.resolveVariant(movement,'T_PHASE_DOOR',read(4,false,nil))
    check(unknownAttr==nil and attrErr.reason=='movement_variant_unknown',
        'TL4 with an unknown attribute is movement_variant_unknown')
    check(calls>0,'the attribute axis is pre-read at TL4+')
    calls=0
    local unknownLevel,levelErr=Factory.resolveVariant(movement,'T_PHASE_DOOR',read(nil,true,false))
    check(unknownLevel==nil and levelErr.reason=='movement_variant_unknown',
        'an unknown effective level is movement_variant_unknown')

    -- Overlap and no-match are non-determinability, never an ordering pick.
    local overlapping=Factory.matrix({
        {when={kind='talent_level',below=5},template='self_random_teleport',
            params={radius=1,landing_proof='a'}},
        {when={kind='talent_level',below=6},template='self_random_teleport',
            params={radius=1,landing_proof='b'}},
    })
    local multi,multiErr=Factory.resolveVariant(overlapping,'T_PHASE_DOOR',read(1,true,false))
    check(multi==nil and multiErr.detail=='multiple_matches','overlapping variant matches fail closed')
    local unmatched=Factory.matrix({
        {when={kind='talent_level',at_least=9},template='self_random_teleport',
            params={radius=1,landing_proof='a'}},
    })
    local zero,zeroErr=Factory.resolveVariant(unmatched,'T_PHASE_DOOR',read(1,true,false))
    check(zero==nil and zeroErr.detail=='no_match','zero variant matches fail closed')

    -- A malformed closed condition is rejected at build time.
    local bad,err=Factory.matrix({{when={kind='attr',id='x',bogus=1},
        template='self_random_teleport',params={radius=1,landing_proof='a'}}})
    check(bad==nil and err.reason=='movement_adapter_invalid',
        'an open condition record is rejected by the matrix builder')
end

-- 4. MAF-REV-02: the drift preflight runs before any dynamic reader -----------
do
    local dynamicCalls=0
    local p=provider({preflight=function() return nil,'adapter_source_drift','test' end,
        talentLevel=function() dynamicCalls=dynamicCalls+1;return 1 end,
        attr=function() dynamicCalls=dynamicCalls+1;return nil,true end,
        talentGetter=function() dynamicCalls=dynamicCalls+1;return 6 end,
        builder=function() dynamicCalls=dynamicCalls+1;return {shape='hit'} end})
    local planned,err=Planner.plan({action='use_talent',talent='T_PHASE_DOOR',
        destination={selector='native_random',accept=ACCEPT}},p,
        Manifest.entry('T_PHASE_DOOR').movement)
    check(planned==nil and err.reason=='adapter_source_drift' and err.preflight==true,
        'a preflight failure is returned as adapter_source_drift')
    check(dynamicCalls==0,'no variant/bounds/builder reader is called before the preflight passes')

    -- Plain move has no adapter read and must not be disabled by an adapter drift.
    local move=Planner.plan({action='move',direction=4},p,nil)
    check(move~=nil and move.kind=='step','a plain step does not require the movement preflight')
end

-- 5. Dynamic envelope bounds: audited getter only ----------------------------
do
    local movement=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius={getter='getRadius'},min_radius=0,landing_proof='p'}))
    local bounds,err=Factory.resolveBounds(movement,'T_PHASE_DOOR',{})
    check(bounds==nil and err.reason=='movement_derivation_unknown' and err.dependency=='getRadius',
        'a missing getter reader is movement_derivation_unknown')
    bounds,err=Factory.resolveBounds(movement,'T_PHASE_DOOR',{talentGetter=function() return 1/0 end})
    check(bounds==nil and err.reason=='movement_derivation_unknown','a non-finite getter is unknown')
    bounds,err=Factory.resolveBounds(movement,'T_PHASE_DOOR',{talentGetter=function() return 5 end})
    check(err==nil and bounds.radius==5,'a finite getter value resolves the envelope')
    local clamped=assert(Factory.resolveBounds(
        assert(Factory.expand('self_random_teleport',{radius={getter='r',min=1,max=4},
            landing_proof='p'})),'T_X',{talentGetter=function() return 9 end}))
    check(clamped.radius==4,'an audited getter value is clamped to the declared maximum')
end

-- 6. MAF-REV-03: live builder geometry/conformance and live range -------------
do
    local movement=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        builder_shape='beam',landing_proof='p'}))
    local built=assert(Factory.resolveBuilder(movement,'T_X',
        {builder=function() return {shape='beam',range=3} end}))
    check(built.range==3 and built.builder_geometry.shape=='beam','the builder range/shape is copied')
    local bad,err=Factory.resolveBuilder(movement,'T_X',
        {builder=function() return {shape='ball',range=3} end})
    check(bad==nil and err.reason=='adapter_source_drift' and err.detail=='builder_shape',
        'a wrong builder shape fails closed as adapter_source_drift')
    bad,err=Factory.resolveBuilder(movement,'T_X',{})
    check(bad==nil and err.reason=='movement_derivation_unknown',
        'a missing builder reader fails closed')
    bad,err=Factory.resolveBuilder(movement,'T_X',{builder=function() error('boom') end})
    check(bad==nil and err.reason=='movement_derivation_unknown','a throwing builder fails closed')
    -- A descriptor with no declared builder shape is never forced to call one.
    local plain=assert(Factory.expand('self_random_teleport',{radius=1,landing_proof='p'}))
    check(Factory.resolveBuilder(plain,'T_X',{})==plain,'a no-builder descriptor is returned unchanged')

    -- The scan uses the live finite range; an unknown range fails closed instead
    -- of falling back to a hard-coded scan radius.
    local ranged=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        builder_shape='beam',landing_proof='p'}))
    -- The resolved descriptor carries the live builder range.
    ranged.range=8
    local p=provider()
    local plan=assert(Planner.planTalent({selector='toward',anchor='bound_target',accept=ACCEPT},
        p,nil,ranged))
    check(Distance.grid(20,20,plan.x,plan.y)<=8,'the scan respects the live builder range')
    local none=Planner.planTalent({selector='toward',anchor='bound_target',accept=ACCEPT},
        p,nil,assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
            landing_proof='p'})))
    check(none==nil,'a scan without a finite range fails closed')
end

-- 7. MAF-REV-04: occupancy-dependent Dimensional Step TL5 ---------------------
do
    local movement=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=5,builder_shape='hit',occupancy_dependent=true,landing_proof='p'}))
    local empty=assert(Factory.resolveOccupancy(movement,'empty'))
    check(empty.relocates_other==false and empty.occupancy=='empty',
        'a known empty grid admits the non-swap descriptor')
    local actor,actorErr=Factory.resolveOccupancy(movement,'actor')
    check(actor==nil and actorErr.reason=='unsupported_movement_variant'
        and actorErr.missing=='moving_or_swapping_another_actor','a known actor is the S4 swap gap')
    local unknown,unknownErr=Factory.resolveOccupancy(movement,'unknown')
    check(unknown==nil and unknownErr.reason=='movement_variant_unknown',
        'unknown occupancy fails closed without probing a hidden actor')
    local plain=assert(Factory.resolveOccupancy(assert(Factory.expand('grid_move_exact',
        {delivery='leap',traverses=false,landing_proof='p'})),'actor'))
    check(plain.relocates_other==false,'a non-occupancy descriptor ignores the occupancy read')

    -- Full planner path for the manifest TL5 adapter.
    local step=Manifest.entry('T_DIMENSIONAL_STEP').movement
    local function planWith(occupancy)
        return Planner.plan({action='use_talent',talent='T_DIMENSIONAL_STEP',
            destination={selector='position',x=22,y=20,accept=ACCEPT}},
            provider({occupancy=function() return occupancy end,builder=function() return {shape='hit',range=8} end,
                talentLevel=function() return 5 end}),step)
    end
    local plan=assert(planWith('empty'))
    check(plan.kind=='grid','TL5 known-empty Dimensional Step is admitted as a non-swap grid')
    local s,err=planWith('actor')
    check(s==nil and err.reason=='unsupported_movement_variant'
        and err.missing=='moving_or_swapping_another_actor','TL5 known-actor is the S4 gap')
    s,err=planWith('unknown')
    check(s==nil and err.reason=='movement_variant_unknown','TL5 unknown occupancy fails closed')
end

-- 8. Grid landings are annotated by the declared class -----------------------
do
    local p=provider()
    local blink=assert(Factory.expand('grid_move_bounded',{delivery='teleport',traverses=false,
        radius=5,landing_proof='p'}))
    local plan=assert(Planner.planTalent({selector='position',x=5,y=5,accept=ACCEPT},p,nil,blink))
    check(plan.annotation.landing.kind=='bounded' and plan.annotation.landing.radius==5,
        'a bounded grid adapter annotates the landing as bounded')
    local strict=Planner.planTalent({selector='position',x=5,y=5,
        accept={visibility='any',passability='native',hazard='any',landing='deterministic'}},
        p,nil,blink)
    check(strict==nil,'landing=deterministic rejects the bounded grid landing')
    local exact=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        landing_proof='p'}))
    local ex=assert(Planner.planTalent({selector='position',x=5,y=5,accept=ACCEPT},p,nil,exact))
    check(ex.annotation.landing.kind=='deterministic',
        'an exact grid adapter keeps the deterministic landing annotation')
end

-- 8b. MAF-REV-03: the live range bounds position/relative/scan requests ------
do
    local saved_core=core
    -- Reproduce the native circular metric in the headless fixture so the
    -- diagonal (3,3) case is genuinely outside a range-3 domain.
    core={fov={distance=function(ax,ay,bx,by)
        return math.sqrt((ax-bx)^2+(ay-by)^2)
    end}}
    local p=provider()
    local exact=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        builder_shape='beam',landing_proof='p'}))
    exact.range=3
    -- position: cardinal minimum/maximum, then outside.
    check(Planner.planTalent({selector='position',x=20,y=20,accept=ACCEPT},p,nil,exact)~=nil,
        'position at the origin is in range')
    check(Planner.planTalent({selector='position',x=23,y=20,accept=ACCEPT},p,nil,exact)~=nil,
        'position at the cardinal maximum is in range')
    local none,err=Planner.planTalent({selector='position',x=24,y=20,accept=ACCEPT},p,nil,exact)
    check(none==nil and err.reason=='destination_out_of_range','position outside the cardinal range is rejected')
    none,err=Planner.planTalent({selector='position',x=23,y=23,accept=ACCEPT},p,nil,exact)
    check(none==nil and err.reason=='destination_out_of_range','position at a diagonal outside the circular range is rejected')
    -- relative: cardinal in range and diagonal outside.
    check(Planner.planTalent({selector='relative',dx=0,dy=3,accept=ACCEPT},p,nil,exact)~=nil,
        'relative at the cardinal maximum is in range')
    none,err=Planner.planTalent({selector='relative',dx=3,dy=3,accept=ACCEPT},p,nil,exact)
    check(none==nil and err.reason=='destination_out_of_range','relative diagonal outside the circular range is rejected')
    -- scan: `away` must not select the out-of-metric diagonal (it did before the
    -- Distance.grid filter, because the square scan scored it best).
    local selfAnchor=provider({anchor=function() return {x=20,y=20} end})
    local away=assert(Planner.planTalent({selector='away',anchor='bound_target',accept=ACCEPT},
        selfAnchor,nil,exact))
    check(Distance.grid(20,20,away.x,away.y)<=3,'a scan candidate is inside the shared native metric')
    check(not (away.x==23 and away.y==23),'the scan does not select an out-of-metric diagonal')
    core=saved_core
end

-- 8c. MAF-REV-03: range 0 is an empty non-self target domain -----------------
do
    local p=provider()
    local zero=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        builder_shape='beam',landing_proof='p'}))
    zero.range=0
    local none,err=Planner.planTalent({selector='toward',anchor='bound_target',accept=ACCEPT},
        p,nil,zero)
    check(none==nil and err.reason=='no_acceptable_destination',
        'range 0 has an empty non-self domain instead of a forced radius 1')
end

-- 8d. MAF-REV-02: the builder must expose a finite range ---------------------
do
    local movement=assert(Factory.expand('grid_move_exact',{delivery='leap',traverses=false,
        builder_shape='beam',landing_proof='p'}))
    local bad,err=Factory.resolveBuilder(movement,'T_X',
        {builder=function() return {shape='beam'} end})
    check(bad==nil and err.reason=='movement_derivation_unknown'
        and err.dependency=='t.target.range','a builder without a finite range fails closed')
end

-- 8e. MAF-REV-05: discriminant-closed condition/matrix/unsupported records ----
do
    local function rejectWhen(when)
        local m,err=Factory.matrix({{when=when,template='self_random_teleport',
            params={radius=1,landing_proof='p'}}})
        return m==nil and err.reason=='movement_adapter_invalid'
            and type(err.detail)=='string' and err.detail:find('bad_variant_condition',1,true)~=nil
    end
    check(rejectWhen({kind='always',id='extraneous'}),'always rejects an attr id field')
    check(rejectWhen({kind='talent_level',at_least=4,id='extraneous'}),'talent_level rejects an attr id field')
    check(rejectWhen({kind='talent_level',at_least=4,truthy=true}),'talent_level rejects an attr truthy field')
    check(rejectWhen({kind='attr',id='x',at_least=1}),'attr rejects a level bound field')
    check(rejectWhen({kind='attr',id='x',below=1}),'attr rejects a level bound field (below)')
    check(rejectWhen({kind='all',conditions={{kind='always'}},at_least=1}),'all rejects a scalar field')
    check(rejectWhen({kind='all',conditions={{kind='always',id='x'}}}),'a nested child is validated too')
    check(Factory.matrix({{when={kind='always'},template='self_random_teleport',
        params={radius=1,landing_proof='p'}}})~=nil,'a valid closed condition is accepted')
    local b,err=Factory.matrix({{when={kind='always'},template='self_random_teleport',
        params={radius=1,landing_proof='p'},bogus=1}})
    check(b==nil and err.detail=='unknown_branch_field','a matrix branch rejects an undeclared field')
    local u,uerr=Factory.matrix({{when={kind='always'},unsupported={missing='x',reason='y',bogus=1}}})
    check(u==nil and uerr.detail=='unknown_unsupported_field','an unsupported record rejects an undeclared field')
    local r,rerr=Factory.matrix({{when={kind='always'},unsupported={missing='x',reason='y',requests={{'bogus'}}}}})
    check(r==nil and rerr.detail=='bad_variant_request_kind','an unsupported request list is closed')
    -- MAF-REV-05: nested collections are dense `1..n` arrays, not just prefixes.
    local function rejectMatrix(m)
        local out,err=Factory.matrix(m)
        return out==nil and err.reason=='movement_adapter_invalid'
    end
    check(rejectMatrix({{when={kind='all',conditions={[1]={kind='always'},
        named={kind='always'}}},template='self_random_teleport',
        params={radius=1,landing_proof='p'}}}),'a named condition child is rejected')
    check(rejectMatrix({{when={kind='all',conditions={[1]={kind='always'},
        [3]={kind='always'}}},template='self_random_teleport',
        params={radius=1,landing_proof='p'}}}),'a sparse condition list is rejected')
    check(rejectMatrix({{when={kind='always'},unsupported={missing='x',reason='y',
        requests={[1]={'actor'},named={'grid'}}}}}),'a named outer request sequence is rejected')
    check(rejectMatrix({{when={kind='always'},unsupported={missing='x',reason='y',
        requests={[1]={'actor'},[3]={'grid'}}}}}),'a sparse outer request list is rejected')
    check(rejectMatrix({{when={kind='always'},unsupported={missing='x',reason='y',
        requests={{'actor',named='grid'}}}}}),'a named inner request kind is rejected')
    check(rejectMatrix({{when={kind='always'},unsupported={missing='x',reason='y',
        requests={{'actor',[3]='grid'}}}}}),'a sparse inner request list is rejected')
    check(rejectMatrix({[1]={when={kind='always'},template='self_random_teleport',
        params={radius=1,landing_proof='p'}},[3]={when={kind='always'},
        template='self_random_teleport',params={radius=1,landing_proof='p'}}}),
        'a sparse branches list is rejected')
    local ax,axErr=Factory.matrix({{when={kind='always'},template='self_random_teleport',
        params={radius=1,landing_proof='p'}}},{[1]={kind='attr',id='x'},named={kind='attr',id='y'}})
    check(ax==nil and axErr.reason=='movement_adapter_invalid','a named axis is rejected')
end

-- 9. Drift: action + getter identity pins fail closed ------------------------
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
    check(rep==nil and repReason==Drift.REASON,'a same-line distinct action closure is rejected')
    check(Drift.identity(upManifest,function() return {action=a,getRange=live.T_MOVE.getRange} end)==true,
        'the rejected replacement did not overwrite the baseline')
    Drift.reset()
end

print('Movement adapter factory: '..checks..' checks passed')
