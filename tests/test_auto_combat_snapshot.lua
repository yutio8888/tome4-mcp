-- PolicySnapshot: deterministic target binding and evaluator context assembly.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
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
    check(ctx.enemy_in_melee==nil,'no hostiles means melee is unknown, not false')
end

print('Auto-combat snapshot: '..checks..' checks passed')
