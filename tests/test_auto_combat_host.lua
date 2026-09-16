-- AutoCombatHost: assemble the controller host from injected reads + executor.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Host=require 'mod.auto_combat.AutoCombatHost'
local AutoCombat=require 'mod.auto_combat.AutoCombat'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local policy={targeting={default='nearest_hostile'},limits={max_actions_per_tick=1},
    safety={min_hp_pct=35},
    rules={{id='beam',priority=1,when={enemy_count={ge=1}},
        ['then']={action='use_talent',talent='T_MOONLIGHT_RAY',target='nearest_hostile'}}}}

local function opts(overrides)
    local o={policy=policy,
        phase=function() return 'ready' end,
        opportunity_id=function() return 1 end,
        enemy_ids=function() return {'e1'} end,
        origin=function() return {x=5,y=5} end,
        hp_pct=function() return 80 end,
        resource_pct=function(name) return name=='negative' and 50 or 100 end,
        resource_value=function() return 100 end,
        talent_known=function() return true end,
        cooldown_ready=function() return true end,
        has_effect=function() return nil end,
        computed=function() return nil end,
        hostiles=function() return {{id='e1',x=6,y=5,hp_pct=70}} end,
        execute=function(attempt) return {status='ok',energy_spent=true,attempt=attempt} end,
        notify=function() end}
    for k,v in pairs(overrides or {}) do o[k]=v end
    return o
end

do
    local host=Host.new(opts())
    check(host.phase()=='ready','the host forwards phase')
    local ctx=host.snapshot('nearest_hostile')
    check(ctx.hp_pct==80 and ctx.enemy_count==1 and ctx.bound_target=='e1',
        'the host snapshot binds the injected hostile')
    check(host.request({action='use_talent'}).status=='ok','the host forwards the executor result')
end

do
    -- A missing phase/read is unknown rather than a crash.
    local host=Host.new({policy=policy})
    check(host.phase()=='settling','a missing phase defaults to settling')
    local ctx=host.snapshot()
    check(ctx.hp_pct==nil and ctx.enemy_count==0,'missing reads stay unknown and bind nothing')
end

do
    -- Executor errors are reported, never raised at the controller.
    local host=Host.new(opts({execute=function() error('boom') end}))
    local outcome=host.request({})
    check(outcome.status=='error' and outcome.code=='execution_error','an executor error is contained')
    local missing=Host.new(opts({execute=false})).request({})
    check(missing.status=='error' and missing.code=='execution_not_available','a missing executor is reported')
    local boolean=Host.new(opts({execute=function() return true end})).request({})
    check(boolean.status=='error' and boolean.code=='invalid_executor_result',
        'a non-table executor result is rejected')
end

do
    -- End to end through the controller: the host drives one real action.
    local executed={}
    local host=Host.new(opts({execute=function(attempt)
        executed[#executed+1]=attempt
        return {status='ok',energy_spent=true}
    end}))
    local c=AutoCombat.new(policy,host)
    c:start()
    local step=c:onOpportunity()
    check(step.action=='acted' and executed[1].talent=='T_MOONLIGHT_RAY' and executed[1].bound_target=='e1',
        'the controller acts through the host on the bound target')
end

print('Auto-combat host: '..checks..' checks passed')
