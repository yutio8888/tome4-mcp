-- N1 probe: run the production controller -> service notify -> PolicyLog path
-- for a natively-rejected deterministic landing and print the client-visible
-- movement_retry entry's fields.
local addon=assert(os.getenv('TOME_MCP_ADDON_DIR'),'TOME_MCP_ADDON_DIR required')
package.path=addon..'/overload/?.lua;'..package.path
local Service=require 'mod.auto_combat.AutoCombatService'
local function policy(t)
    return {schema='tome-auto-combat/v1',id='p1',name='p1',limits={max_actions_per_tick=2},
        safety={min_hp_pct=35},targeting={default='nearest_hostile'},rules={t}}
end
local accept={visibility='any',passability='native',hazard='any',landing='allow_random'}
local attempts=0
local function plan(attempt)
    local exclude=attempt.exclude or {}
    if not exclude['4,2'] then
        return {plan={kind='step',direction=9,x=4,y=2,
            annotation={landing={kind='deterministic',x=4,y=2}}}}
    end
    return {plan={kind='step',direction=6,x=4,y=3,
        annotation={landing={kind='deterministic',x=4,y=3}}}}
end
local host={phase=function() return 'ready' end,opportunity_id=function() return 1 end,
    snapshot=function() return {hp_pct=80,enemy_count=1,binding_selector='nearest_hostile'} end,
    enemy_ids=function() return {} end,notify=function() end,plan=plan,
    request=function(attempt)
        attempts=attempts+1
        local landing=attempt.plan and (attempt.plan.x..','..attempt.plan.y)
        if landing=='4,2' then return {status='rejected',code='blocked',energy_spent=0} end
        return {status='ok',energy_spent=1000}
    end}
local p=policy({id='approach',priority=10,when={always={}},
    ['then']={action='move',target='nearest_hostile',
        destination={selector='toward',anchor='bound_target',accept=accept}}})
local svc=Service.new{host_factory=function() return host end}
local d=Service.handle(svc,'set_draft',{policy=p})
Service.handle(svc,'approve',{expected_hash=d.draft_hash})
Service.handle(svc,'activate',{})
Service.handle(svc,'start',{})
local stepped=Service.step(svc); print('step: '..tostring(stepped and stepped.step and stepped.step.action))
local log=Service.handle(svc,'log',{limit=16})
local found
for _,event in ipairs(log.events or {}) do
    if event.kind=='movement_retry' then found=event end
end
if not found then print('movement_retry entry: MISSING'); os.exit(1) end
local keys={}
for k,v in pairs(found) do keys[#keys+1]=k..'='..tostring(v) end
table.sort(keys)
print('movement_retry keys: '..table.concat(keys,','))
print('landing present: '..tostring(found.landing))
