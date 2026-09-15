-- GPL-3.0-or-later. Pure collection projections for tome.list (spec OBS-02).
--
-- Each projection enumerates the allowed underlying set directly and applies
-- the existing player-knowledge filters and pure scalar projections. It never
-- pages a summary array that observe already truncated, and never exposes
-- hidden actors, items, trees or unidentified properties.
local Json = require 'mod.mcp_bridge.Json'
local Observer = require 'mod.mcp_bridge.Observer'
local Details = require 'mod.mcp_bridge.ObservationDetails'
local Items = require 'mod.mcp_bridge.Items'
local Progression = require 'mod.mcp_bridge.Progression'
local Compat = require 'mod.mcp_bridge.NativeCompatibility'
local M = {}
local COLLECTIONS = {
    inventory = {first = {inventory_id = 'number'}},
    equipment = {first = {inventory_id = 'number'}},
    actors = {first = {}},
    talents = {first = {}},
    effects = {first = {actor_id = 'string'}},
    ground_items = {first = {radius = 'number'}},
    progression_categories = {first = {}},
    progression_talents = {first = {category_id = 'string'}, required = {'category_id'}},
    compatibility = {first = {domain = 'string'}},
}

function M.supported(collection) return COLLECTIONS[collection] ~= nil end

function M.refs()
    local out = Json.array()
    for _, collection in ipairs{'inventory', 'equipment', 'actors', 'talents', 'effects',
        'ground_items', 'progression_categories', 'progression_talents', 'compatibility'} do
        out[#out + 1] = {collection = collection, request = {type = 'first', collection = collection}}
    end
    return out
end

local function validFilter(collection, filter)
    local spec = COLLECTIONS[collection]
    if not spec then return nil, 'unsupported_collection' end
    filter = filter or {}
    if type(filter) ~= 'table' then return nil, 'invalid_filter' end
    local required = spec.required or {}
    for _, key in ipairs(required) do
        if filter[key] == nil then return nil, 'invalid_filter' end
    end
    for key, value in pairs(filter) do
        local expected = spec.first[key]
        if expected == nil then return nil, 'invalid_filter' end
        if expected == 'string' and type(value) ~= 'string' then return nil, 'invalid_filter' end
        if expected == 'number' then
            if type(value) ~= 'number' or value % 1 ~= 0 then return nil, 'invalid_filter' end
            if key == 'radius' and (value < 1 or value > 12) then return nil, 'invalid_filter' end
        end
    end
    return filter
end

-- Returns `{items=<ordered pure array>, complete=<bool>}` or nil, code.
function M.project(g, meta, collection, filter)
    local checked, code = validFilter(collection, filter)
    if not checked then return nil, code end
    filter = checked
    if collection == 'actors' then
        local items, complete = Observer.listActors(g, meta)
        return {items = items, complete = complete}
    elseif collection == 'talents' then
        local items, complete = Observer.listTalents(g)
        return {items = items, complete = complete}
    elseif collection == 'effects' then
        local actor = g.player
        if filter.actor_id ~= nil then
            if not g.player or filter.actor_id ~= Observer.actorId(meta, g.player) then
                actor = Observer.resolve(g, meta, filter.actor_id)
                if not actor then return nil, 'actor_not_visible' end
            end
        end
        local items, truncated = Details.effects(actor, 4096)
        return {items = items, complete = not truncated}
    elseif collection == 'ground_items' then
        local ground = Items.ground(g, meta, filter.radius or 8)
        return {items = ground.items or Json.array(), complete = not ground.items_truncated}
    elseif collection == 'inventory' or collection == 'equipment' then
        local items, complete = Details.inventoryAll(g, g.player, meta, collection)
        if filter.inventory_id ~= nil then
            local filtered = Json.array()
            for _, item in ipairs(items) do
                if item.inventory_id == filter.inventory_id then filtered[#filtered + 1] = item end
            end
            items = filtered
        end
        return {items = items, complete = complete}
    elseif collection == 'progression_categories' then
        local describe = Progression.describe(g, g.player)
        return {items = describe.categories, complete = not describe.categories_truncated}
    elseif collection == 'progression_talents' then
        local describe = Progression.describe(g, g.player)
        for _, entry in ipairs(describe.categories) do
            if entry.id == filter.category_id then
                return {items = entry.talents, complete = not entry.talents_truncated}
            end
        end
        return nil, 'unknown_category'
    elseif collection == 'compatibility' then
        local items, complete = Compat.providerSummary()
        if filter.domain ~= nil then
            local filtered = Json.array()
            for _, item in ipairs(items) do
                if item.domain == filter.domain then filtered[#filtered + 1] = item end
            end
            items = filtered
        end
        return {items = items, complete = complete}
    end
    return nil, 'unsupported_collection'
end

return M
