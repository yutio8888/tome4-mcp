-- GPL-3.0-or-later. Pure component-risk composition for the v2 effect manifest.
--
-- The manifest describes each talent as a list of components (cursor / instant /
-- projectile / secondary / ground). This module turns the resolved filter values
-- and footprint membership into a single safety verdict, with no engine access,
-- so the policy is unit-testable in isolation.
--
-- Engine semantics (design 8.1-8.3, investigation 1-5):
--   * a boolean `true` is 100%, `false` is 0%; a finite number is a percentage;
--     any validation failure is `unknown`;
--   * self is affected only when the origin is inside the footprint AND both
--     `selffire` and `friendlyfire` are positive;
--   * a moving projectile fired by the player is suppressed for self unless
--     `player_selffire`/`allow_player_selffire` opts in; direct and ground
--     effects ignore that override;
--   * a friendly/neutral actor is affected by the `friendlyfire` filter alone;
--   * a persistent ground component with positive or unknown self/friendly
--     probability is future risk even when its current footprint is empty.
local M={}

function M.flag(value)
    if value==true then return 100 end
    if value==false then return 0 end
    if value=='unknown' or value==nil then return 'unknown' end
    if type(value)=='number' and value==value and value>-math.huge and value<math.huge then
        if value<=0 then return 0 end
        if value>=100 then return 100 end
        return value
    end
    return 'unknown'
end

local function positive(value)
    -- `unknown` is positive (conservative); only an explicit 0 is safe.
    return value~=0
end

local function isMelee(component)
    return component.phase=='melee' or component.delivery=='attackTarget'
end

local function isCursor(component)
    return component.phase=='cursor'
end

-- Resolve one component against its footprint membership.
-- `membership` = {self=false|true|'unknown', friendlies=count|'unknown', player_override=false|true}
-- Returns nil when the component adds no risk, else a detail table.
function M.component(component,membership)
    if component==nil or isCursor(component) or isMelee(component) then return nil end
    local m=membership or {}
    local sf,ff=M.flag(component.selffire),M.flag(component.friendlyfire)
    if component.phase=='ground' then
        -- Native `Map:updateEffects` applies both filters to the caster and only
        -- the friendly-fire filter to allies. A persistent zone is future risk
        -- whenever a required filter is positive/unknown.
        if positive(sf) and positive(ff) then
            return {phase='ground',component=component.id or 'ground',risk='self',
                selffire=sf,friendlyfire=ff,provenance=component.provenance}
        end
        if positive(ff) then
            return {phase='ground',component=component.id or 'ground',risk='friendly',
                selffire=sf,friendlyfire=ff,provenance=component.provenance}
        end
        return nil
    end
    -- Self risk: containment AND both filters. The projectile self-opt-in is
    -- required in addition; a direct projection or map effect ignores it.
    if m.self==true or m.self=='unknown' then
        if positive(sf) and positive(ff) then
            local suppressed=(component.delivery=='projectile') and (m.player_override~=true)
            if not suppressed then
                return {phase=component.phase or 'instant',component=component.id,risk='self',
                    selffire=sf,friendlyfire=ff,provenance=component.provenance}
            end
        end
    end
    -- Friendly risk: the friendly-fire filter alone, against known occupants.
    if m.friendlies=='unknown' or (type(m.friendlies)=='number' and m.friendlies>0) then
        if positive(ff) then
            return {phase=component.phase or 'instant',component=component.id,risk='friendly',
                selffire=sf,friendlyfire=ff,friendlies=m.friendlies,provenance=component.provenance}
        end
    end
    return nil
end

-- Evaluate a whole component list. Returns `true` (safe) or `nil, detail` with
-- the first risk found. Ordering follows the manifest, ground last, so an
-- instantaneous self-hit is reported before a future-zone concern.
function M.evaluate(components,memberships)
    memberships=memberships or {}
    for _,component in ipairs(components or {}) do
        local detail=M.component(component,memberships[component.id or component.phase])
        if detail then return nil,detail end
    end
    return true
end

return M
