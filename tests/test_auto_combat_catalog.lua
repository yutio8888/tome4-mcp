-- Capability catalogue semantics plus the bounded policy log.
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
    -- N1: the client-visible movement_retry entry must keep the refused
    -- deterministic landing (not only the native code), so policy_log/replay can
    -- reconstruct which coordinate the engine refused.
    PolicyLog.add(log,{kind='movement_retry',rule='approach',action='move',
        landing='4,2',native_result='blocked',generation=7})
    local retry=PolicyLog.tail(log,1)[1]
    check(retry.kind=='movement_retry' and retry.landing=='4,2'
        and retry.native_result=='blocked' and retry.action=='move',
        'PolicyLog keeps the refused landing on a movement_retry entry (N1)')
    -- P3-c: a non-string landing cannot grow the ring.
    PolicyLog.add(log,{kind='movement_retry',landing={nested='table'}})
    check(PolicyLog.tail(log,1)[1].landing==nil,'PolicyLog drops a non-string landing (P3-c)')
    -- D-2: a native refusal's structured cooldown detail stays client-visible
    -- and bounded, so the auto denied event matches the command path.
    PolicyLog.add(log,{kind='denied',rule='heal',reason='native_rejected',
        missing={{kind='cooldown',talent='T_HEALING_LIGHT',remaining=7,required=0}},
        native_message='Healing Light is still on cooldown for 7 turns.',
        hint='talent on cooldown; wait for the listed turns before retrying'})
    local deniedEntry=PolicyLog.tail(log,1)[1]
    check(deniedEntry.missing and deniedEntry.missing[1].kind=='cooldown'
        and deniedEntry.missing[1].remaining==7 and deniedEntry.missing[1].talent=='T_HEALING_LIGHT',
        'PolicyLog keeps the structured cooldown missing on a denied entry (D-2)')
    check(deniedEntry.native_message=='Healing Light is still on cooldown for 7 turns.'
        and type(deniedEntry.hint)=='string',
        'PolicyLog keeps the native message and hint on a denied entry (D-2)')
    -- A hostile missing value cannot grow the ring or leak arbitrary keys.
    PolicyLog.add(log,{kind='denied',rule='x',missing={{kind='cooldown',evil=os.time}}})
    local cleaned=PolicyLog.tail(log,1)[1].missing
    check(cleaned and cleaned[1].evil==nil,'PolicyLog projects only declared missing fields (D-2)')
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

-- S3 admission 3 (V-U6): the agility Vault IS a catalogue adapter now — a MIXED
-- movement/effect entry with the ordered actor-then-grid program and two direct
-- components; its unsupported disposition is gone. The acrobatics
-- T_SKIRMISHER_VAULT is a different talent and stays admitted unchanged.
do
    check(Catalog.supported('T_VAULT'),'the agility Vault is a catalogue adapter (V-U6)')
    local entry=Catalog.entry('T_VAULT')
    check(entry~=nil and entry.kind=='movement' and entry.target=='hostile',
        'the agility Vault resolves to the hostile mixed descriptor (V-U6)')
    check(Catalog.manifestEntry('T_VAULT')~=nil,'the agility Vault has its manifest entry (V-U6)')
    local unsupportedCount=0
    for _,u in ipairs(Catalog.UNSUPPORTED or {}) do
        if u.talent=='T_VAULT' then unsupportedCount=unsupportedCount+1 end
    end
    check(unsupportedCount==0,'the agility Vault no longer appears in the unsupported list (V-U6)')
    -- T_SKIRMISHER_VAULT (acrobatics) is a different talent and stays admitted,
    -- component-free and unchanged (V-U6 byte-equivalence checked in the
    -- movement-factory test).
    check(Catalog.supported('T_SKIRMISHER_VAULT'),'T_SKIRMISHER_VAULT stays a catalogue adapter')
    check(Catalog.entry('T_SKIRMISHER_VAULT').kind=='movement',
        'T_SKIRMISHER_VAULT stays a movement descriptor')
    check(#(Catalog.entry('T_SKIRMISHER_VAULT').components or {})==0,
        'T_SKIRMISHER_VAULT stays component-free (V-U6)')
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
    -- MFT-REV-03 (Option A): the actor step selector is the effective binding when
    -- `then.target` and `targeting.default` are both absent, and it is checked
    -- against the talent (so an omitted 'self' on a hostile talent is rejected).
    local function noDefault(rule)
        local p=policy(rule)
        p.targeting=nil
        return p
    end
    local omitted=noDefault({id='rush',priority=1,when={always={}},['then']={action='use_talent',
        talent='T_RUSH',target_plan={{request='actor',selector='nearest_hostile'}},
        destination={selector='native_landing',anchor='bound_target',accept=accept}}})
    check(Catalog.verify(omitted),'an actor step selector binds when no action selector exists (MFT-REV-03)')
    local omittedSelf=noDefault({id='rush',priority=1,when={always={}},['then']={action='use_talent',
        talent='T_RUSH',target_plan={{request='actor',selector='self'}},
        destination={selector='native_landing',anchor='bound_target',accept=accept}}})
    local omittedOk,omittedErrors=Catalog.verify(omittedSelf)
    check(omittedOk==nil,'the omitted action selector uses the declared actor step selector')
    local omittedCode=false
    for _,error in ipairs(omittedErrors or {}) do
        if error.code=='selector_not_hostile' then omittedCode=true end
    end
    check(omittedCode,'an omitted self step selector is rejected for a hostile talent')
    -- S3-A2-R3: the catalogue consumes `#`/`ipairs` over the caller-supplied
    -- plan, so a sparse plan (a hidden key beyond the dense end) must be
    -- rejected at the catalogue too — never silently truncated into a shorter
    -- matching plan (reviewer SPARSE_TARGET_PLAN line: schema=false AND
    -- catalog=false).
    local sparsePlan={}
    sparsePlan[1]={request='actor',selector='nearest_hostile'}
    sparsePlan[2]={request='grid',destination={selector='position',x=6,y=2,accept=accept}}
    sparsePlan[5]={request='NOT_A_REAL_ENUM'}
    local sparsePolicy=policy({id='vault',priority=1,when={always={}},['then']={action='use_talent',
        talent='T_VAULT',target='nearest_hostile',target_plan=sparsePlan,
        destination={selector='position',x=6,y=2,accept=accept}}})
    local sparseOk,sparseErrors=Catalog.verify(sparsePolicy)
    local sparseCode=false
    for _,error in ipairs(sparseErrors or {}) do
        if error.code=='target_plan_not_dense' then sparseCode=true end
    end
    check(sparseOk==nil and sparseCode,
        'a sparse target_plan with a hidden key-5 entry is rejected by the catalogue (R3)',
        sparseErrors and sparseErrors[1] and sparseErrors[1].code)
    -- S3-A2-FIX1-03: the catalogue's own `rules`/`sustains` walks are
    -- dense-and-closed BEFORE iteration; a hidden rule beyond a hole must not be
    -- silently dropped from the compatibility check.
    local sparseRulesPolicy=policy({id='sparse-rules',priority=1,when={always={}},['then']={action='wait'}})
    sparseRulesPolicy.rules={[1]={id='a',priority=1,when={always={}},['then']={action='wait'}},
        [3]={id='c',priority=1,when={always={}},['then']={action='wait'}}}
    local srOk,srErrors=Catalog.verify(sparseRulesPolicy)
    local srCode=false
    for _,error in ipairs(srErrors or {}) do
        if error.code=='rules_not_dense' then srCode=true end
    end
    check(srOk==nil and srCode,
        'the catalogue rejects a sparse rules array (FIX1-03)',
        srErrors and srErrors[1] and srErrors[1].code)
    local summary=Catalog.summary()
    check(#summary.actions>=6 and summary.adapter_version==Catalog.VERSION,
        'the capability summary lists the action adapters and the adapter version')
    check(not summary.self_preservation,'emergency is not a catalogue talent category (D1)')
end

print('Auto-combat catalog: '..checks..' checks passed')
