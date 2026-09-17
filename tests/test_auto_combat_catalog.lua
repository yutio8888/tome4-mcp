-- Capability catalogue semantics plus the bounded policy log.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local PolicyLog=require 'mod.auto_combat.PolicyLog'
local PolicyStore=require 'mod.auto_combat.PolicyStore'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function policy(rule)
    return {schema='tome-auto-combat/v1',id='p1',name='p1',
        limits={max_actions_per_tick=1},
        safety={min_hp_pct=35},
        targeting={default='nearest_hostile'},
        sustains={},
        rules={rule or {id='beam',priority=1,when={enemy_count={ge=1}},
            ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}
end

check(Catalog.supported('T_MOONLIGHT_RAY'),'the whitelist is known to the catalogue')
check(not Catalog.supported('T_NOT_ALLOWED'),'an unknown talent is not supported')
do
    -- The §15.1 talent whitelist and the capability catalogue must not drift:
    -- every whitelisted talent has an adapter entry, and every declared sustain
    -- is a sustain in the catalogue.
    local Schema=require 'mod.auto_combat.PolicySchema'
    for talent in pairs(Schema.TALENTS) do
        check(Catalog.supported(talent),'whitelisted talent '..talent..' has a catalogue entry')
    end
    for talent in pairs(Schema.SUSTAINS) do
        check(Catalog.isSustain(talent),'sustain '..talent..' is declared a sustain in the catalogue')
    end
end
check(Catalog.verify(policy()),'an attack talent with a hostile selector is compatible')
do
    local bad=policy({id='heal',priority=1,when={hp_pct={lt=50}},
        ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='nearest_hostile'}})
    local ok,errors=Catalog.verify(bad)
    check(ok==nil and errors[1].code=='selector_not_self_only','a self-only talent rejects a hostile selector')
end
do
    local bad=policy({id='attack',priority=1,when={always={}},
        ['then']={action='use_talent',talent='T_ATTACK',target='self'}})
    local ok,errors=Catalog.verify(bad)
    check(ok==nil and errors[1].code=='selector_not_hostile','a hostile talent rejects a self selector')
end
do
    local p=policy(); p.sustains={{talent='T_ATTACK',priority=10}}
    local ok,errors=Catalog.verify(p)
    check(ok==nil and errors[1].code=='not_a_sustain','a non-sustain cannot be in sustains')
    p.sustains={{talent='T_CHANT_OF_FORTRESS',priority=10}}
    check(Catalog.verify(p),'a sustain talent is accepted')
end
do
    -- The store enforces the catalogue too, not only the schema.
    local s=PolicyStore.new()
    local bad=policy({id='heal',priority=1,when={hp_pct={lt=50}},
        ['then']={action='use_talent',talent='T_HEALING_LIGHT',target='nearest_hostile'}})
    local result,err=PolicyStore.setDraft(s,bad,nil)
    check(result==nil and err.code=='invalid_policy','the store rejects an incompatible talent/selector pair')
end

-- Bounded log -----------------------------------------------------------------
do
    local log=PolicyLog.new(3)
    for i=1,5 do PolicyLog.add(log,{kind='acted',rule='r'..i,generation=i,policy_hash='h'}) end
    local status=PolicyLog.status(log)
    check(status.count==3 and status.total==5,'the log ring keeps only the newest entries')
    local tail=PolicyLog.tail(log,2)
    check(#tail==2 and tail[1].rule=='r5' and tail[2].rule=='r4','tail is newest first')
    check(tail[1].seq==5 and tail[1].generation==5,'entries keep their sequence and generation')
    PolicyLog.add(log,{kind='acted',rule='r6',generation=6,tick=9,revision=2,level_instance_id='level-1'})
    local tagged=PolicyLog.tail(log,1)[1]
    check(tagged.tick==9 and tagged.revision==2 and tagged.level_instance_id=='level-1',
        'log entries carry replay metadata when supplied (design 10)')
    local empty=PolicyLog.tail(log,0)
    check(#empty==0,'an empty tail is empty')
    -- MFT-REV-07: the stored entry carries the movement annotation and the
    -- permitted-risk detail (bounded), so tome.policy_log/replay can
    -- reconstruct them.
    PolicyLog.add(log,{kind='acted',rule='move-risk',movement={landing={kind='deterministic',x=4,y=4},
        visible=true,known_passable=true,known_hazard='unknown'},
        risk={measurement=40,threshold=50,phase='instant',provenance={selffire='explicit'}}})
    local carried=PolicyLog.tail(log,1)[1]
    check(carried.movement and carried.movement.landing.kind=='deterministic'
        and carried.movement.known_passable==true,
        'PolicyLog stores the accepted movement annotation')
    check(carried.risk and carried.risk.measurement==40 and carried.risk.threshold==50
        and carried.risk.provenance and carried.risk.provenance.selffire=='explicit',
        'PolicyLog stores the permitted-risk detail (MFT-REV-07)')
    -- A hostile deep/wide table cannot grow the entry unbounded.
    local deep={}
    local cursor=deep
    for _=1,12 do cursor.next={};cursor=cursor.next end
    PolicyLog.add(log,{kind='acted',rule='deep',movement=deep})
    local boundedEntry=PolicyLog.tail(log,1)[1]
    local depth,node=0,boundedEntry.movement
    while type(node)=='table' and node.next do depth=depth+1;node=node.next end
    check(depth<=4,'the movement detail projection is depth-bounded')
end

-- P1b native-activity action adapters --------------------------------------
do
    check(Catalog.actionSupported('rest') and Catalog.actionSupported('auto_explore'),
        'the catalogue knows the P1b activity actions')
    check(Catalog.actionSupported('change_level') and Catalog.actionSupported('move'),
        'v1.6 re-admits change_level and adds the move action to the catalogue')
    check(not Catalog.actionSupported('teleport'),'an unknown action is not supported by the catalogue')
    local camp=policy({id='camp',priority=1,when={always={}},['then']={action='rest',max_turns=5}})
    check(Catalog.verify(camp),'a rest rule is semantically compatible')
    local explore=policy({id='explore',priority=1,when={always={}},['then']={action='auto_explore'}})
    check(Catalog.verify(explore),'an auto_explore rule is semantically compatible')
    local descend=policy({id='descend',priority=1,when={always={}},['then']={action='change_level'}})
    check(Catalog.verify(descend),'the catalogue re-admits change_level (D5 supersession, MOV-5)')
    local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
    local step=policy({id='step',priority=1,when={always={}},['then']={action='move',
        target='nearest_hostile',destination={selector='away',anchor='bound_target',accept=accept}}})
    check(Catalog.verify(step),'the catalogue accepts a movement rule')
    local door=policy({id='door',priority=1,when={always={}},['then']={action='use_talent',
        talent='T_PHASE_DOOR',destination={selector='native_random',accept=accept}}})
    check(Catalog.verify(door),'a no-target self teleport needs no hostile selector (design 3.2)')
    local rush=policy({id='rush',priority=1,when={always={}},['then']={action='use_talent',
        talent='T_RUSH',target='nearest_hostile',
        destination={selector='native_landing',anchor='bound_target',accept=accept}}})
    check(Catalog.verify(rush),'an actor-anchored Rush rule is semantically compatible')
    -- MFT-REV-03: an actor target_plan step selector must agree with the action
    -- binding; a contradiction is rejected instead of silently resolved.
    local mismatch=policy({id='rush',priority=1,when={always={}},['then']={action='use_talent',
        talent='T_RUSH',target='nearest_hostile',
        target_plan={{request='actor',selector='self'}},
        destination={selector='native_landing',anchor='bound_target',accept=accept}}})
    local mismatchOk,mismatchErrors=Catalog.verify(mismatch)
    check(mismatchOk==nil,'a contradictory actor target_plan selector is rejected')
    local mismatchCode=false
    for _,error in ipairs(mismatchErrors or {}) do
        if error.code=='target_plan_selector_mismatch' then mismatchCode=true end
    end
    check(mismatchCode,'the contradiction carries target_plan_selector_mismatch')
    local summary=Catalog.summary()
    check(#summary.actions>=6 and summary.adapter_version==Catalog.VERSION,
        'the capability summary lists the action adapters and the adapter version')
    check(not summary.self_preservation,'emergency is not a catalogue talent category (D1)')
end

print('Auto-combat catalog: '..checks..' checks passed')
