-- PolicySnapshot: deterministic target binding and evaluator context assembly.
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
local Snapshot=require 'mod.auto_combat.PolicySnapshot'
local Evaluator=require 'mod.auto_combat.PolicyEvaluator'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local origin={x=10,y=10}
local hostiles={
    {id='near',x=11,y=10,hp_pct=90},
    {id='low',x=14,y=10,hp_pct=20},
    {id='far',x=16,y=10,hp_pct=50},
}

check(Snapshot.select('nearest_hostile',hostiles,origin).id=='near','nearest_hostile picks the closest')
check(Snapshot.select('lowest_hp_hostile',hostiles,origin).id=='low','lowest_hp_hostile picks the lowest hp')
check(Snapshot.select('self',hostiles,origin)==nil,'self binds no hostile')
check(Snapshot.nearestDistance(origin,hostiles)==1,'nearest distance uses the documented metric')

-- P2 rank/type selectors ----------------------------------------------------
do
    local ranked={
        {id='norm',x=11,y=10,hp_pct=90,rank=2,level=10,type='animal'},
        {id='elite',x=12,y=10,hp_pct=80,rank=3,level=12,type='humanoid'},
        {id='boss',x=15,y=10,hp_pct=70,rank=4,level=20,type='undead'},
    }
    check(Snapshot.select('highest_rank_hostile',ranked,origin).id=='boss',
        'highest_rank_hostile picks the highest rank')
    check(Snapshot.select('most_dangerous_hostile',ranked,origin).id=='boss',
        'most_dangerous_hostile picks the highest rank')
    local tied={
        {id='a',x=12,y=10,hp_pct=80,rank=3},
        {id='b',x=13,y=10,hp_pct=20,rank=3},
    }
    check(Snapshot.select('highest_rank_hostile',tied,origin).id=='a',
        'highest_rank_hostile ties break on distance')
    check(Snapshot.select('most_dangerous_hostile',tied,origin).id=='b',
        'most_dangerous_hostile ties break on lowest hp')
end

-- Deterministic tie-break: equal distance prefers lower y then lower x.
do
    local tied={{id='b',x=12,y=12,hp_pct=50},{id='a',x=12,y=11,hp_pct=50}}
    check(Snapshot.select('nearest_hostile',tied,origin).id=='a','ties resolve deterministically')
end

local function host(overrides)
    local h={
        origin=function() return origin end,
        hp_pct=function() return 80 end,
        resource_pct=function(name) return name=='positive' and 60 or 40 end,
        resource_value=function() return 120 end,
        talent_known=function() return true end,
        cooldown_ready=function(id) return id=='T_MOONLIGHT_RAY' end,
        has_effect=function() return false end,
        hostiles=function() return hostiles end,
        computed=function(field) return field=='stunned' and false or nil end,
    }
    for k,v in pairs(overrides or {}) do h[k]=v end
    return h
end

local policy={targeting={default='nearest_hostile'},rules={}}

do
    local ctx=Snapshot.build(host(),policy)
    check(ctx.hp_pct==80 and ctx.enemy_count==3,'the snapshot reads hp and the hostile count')
    check(ctx.nearest_enemy_distance==1 and ctx.enemy_in_melee==true,'melee proximity is derived')
    check(ctx.bound_target=='near' and ctx.enemy_hp_pct==90,'the bound target drives enemy_hp_pct')
    check(ctx.resource_pct('positive')==60 and ctx.resource_value('positive')==120,'resources are forwarded')
end

do
    -- The condition and the execution bind to the same target: a rule that
    -- requires a low-hp enemy only fires when that enemy is the bound one.
    local policy2={targeting={default='lowest_hp_hostile'},rules={
        {id='finish',priority=10,when={enemy_hp_pct={lt=30}},
            ['then']={action='use_talent',talent='T_SEARING_LIGHT',target='lowest_hp_hostile'}},
    }}
    local ctx=Snapshot.build(host(),policy2)
    check(ctx.bound_target=='low' and ctx.enemy_hp_pct==20,'binding follows the rule selector')
    local decision=Evaluator.evaluate(policy2,ctx)
    check(decision.decision=='act' and decision.rule=='finish' and decision.target=='lowest_hp_hostile',
        'the bound target satisfies the condition and the action')
    -- If the low-hp enemy dies, the bound target changes and the rule holds.
    local healed=Snapshot.build(host({hostiles=function()
        return {{id='near',x=11,y=10,hp_pct=90}}
    end}),policy2)
    check(Evaluator.evaluate(policy2,healed).decision=='hold','a vanished low-hp target stops the rule')
end

do
    -- Empty hostile set: no binding, no melee, count zero.
    local ctx=Snapshot.build(host({hostiles=function() return {} end}),policy)
    check(ctx.enemy_count==0 and ctx.bound_target==nil and ctx.enemy_hp_pct==nil,
        'an empty hostile set binds nothing')
    check(ctx.enemy_in_melee==false,'an empty hostile read means melee is false')
end

do
    -- Visible enemies outside melee are a known false, not unknown.
    local far=Snapshot.build(host({hostiles=function()
        return {{id='far',x=16,y=10,hp_pct=50}}
    end}),policy)
    check(far.enemy_in_melee==false,'visible enemies outside melee are known false')
end

do
    -- The bound target exposes the P2 audited rank/level/type/distance reads.
    local ranked={{id='boss',x=12,y=10,hp_pct=70,rank=4,level=20,type='undead'}}
    local p2={targeting={default='most_dangerous_hostile'},rules={}}
    local ctx=Snapshot.build(host({hostiles=function() return ranked end}),p2)
    check(ctx.bound_target=='boss' and ctx.enemy_rank==4 and ctx.enemy_level==20
        and ctx.enemy_type=='undead','the bound target exposes rank/level/type')
    check(ctx.enemy_distance==2,'the bound target exposes its own distance')
end

do
    -- P2.5 reads: bounded ally count, bound-target effects and numeric computed.
    local calls={}
    local h=host({allies=function() return {{id='a1'},{id='a2'}} end,
        computed=function(field) calls.computed=field; return field=='crit.spell' and 42 or nil end,
        has_effect=function(effect,who,bound)
            calls.effect={effect,who,bound};return who=='target'
        end})
    local p2={targeting={default='lowest_hp_hostile'},rules={}}
    local ctx=Snapshot.build(h,p2)
    check(ctx.ally_count==2,'the snapshot forwards the bounded ally count')
    check(ctx.bound_target=='low' and ctx.has_effect('EFF','target')==true
        and calls.effect[3]=='low','has_effect resolves who=target against the bound target')
    check(ctx.computed('crit.spell')==42 and calls.computed=='crit.spell',
        'computed forwards the finite-enum field')
    local noallies=Snapshot.build(host(),p2)
    check(noallies.ally_count==nil,'a missing ally read stays unknown')
end

print('Auto-combat snapshot: '..checks..' checks passed')
