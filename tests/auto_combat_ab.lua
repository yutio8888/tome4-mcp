-- GPL-3.0-or-later. Deterministic A/B tuning harness for auto-combat policies.
--
-- Runs a fixed set of scripted snapshots through the pure PolicyEvaluator for
-- two or more policies and reports the per-scenario outcome plus the scenarios
-- where the policies diverge (decision / rule / action / reason). No engine
-- access, no RNG: the same inputs always produce the same report.
local Evaluator=require 'mod.auto_combat.PolicyEvaluator'
local M={}

-- scenario = {id, ctx, selectors={selector -> ctx}}
-- policy   = {name, policy}
function M.run(scenarios,policies)
    local rows={}
    for _,scenario in ipairs(scenarios) do
        for _,entry in ipairs(policies) do
            local ctx=scenario.ctx
            local opts
            if scenario.selectors then
                opts={context_for=function(selector)
                    return scenario.selectors[selector] or ctx
                end}
            end
            local decision=Evaluator.evaluate(entry.policy,ctx,opts)
            rows[#rows+1]={scenario=scenario.id,policy=entry.name,
                decision=decision.decision,rule=decision.rule,reason=decision.reason,
                action=decision.action,talent=decision.talent,target=decision.target,
                layer=decision.layer}
        end
    end
    return rows
end

-- Group rows by scenario and return only the scenarios whose policy rows
-- diverge, preserving scenario order.
function M.differences(rows)
    local byScenario,order={},{}
    for _,row in ipairs(rows) do
        if not byScenario[row.scenario] then
            byScenario[row.scenario]={}
            order[#order+1]=row.scenario
        end
        local group=byScenario[row.scenario]
        group[#group+1]=row
    end
    local out={}
    for _,id in ipairs(order) do
        local group=byScenario[id]
        local first=group[1]
        local differs=false
        for index=2,#group do
            local other=group[index]
            if other.decision~=first.decision or other.rule~=first.rule
                or other.action~=first.action or other.reason~=first.reason then
                differs=true
            end
        end
        if differs then out[#out+1]={scenario=id,rows=group} end
    end
    return out
end

return M
