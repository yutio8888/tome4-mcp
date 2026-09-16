-- GPL-3.0-or-later. Frozen collection views and bounded pagination (spec
-- OBS-01..08). Game independent: it stores only already-projected pure data
-- for a captured context, never actors, maps, dialogs or callbacks.
--
-- The caller projects the allowed items (player knowledge and pure scalar
-- fields) and hands them in. The store freezes them, assigns an opaque cursor,
-- and pages by count and byte budget. A normal revision change makes a page
-- historical; TTL, capacity eviction or a context change expire the cursor.
local Json = require 'mod.mcp_bridge.Json'
local M = {}
local Store = {}
Store.__index = Store
local DEFAULTS = {
    max_views = 4, byte_budget = 4194304, ttl_ms = 120000,
    default_page = 32, max_page = 64, page_bytes = 131072,
    max_items = 4096, max_view_bytes = 1048576,
}

function M.new(options)
    options = options or {}
    local store = setmetatable({}, Store)
    for key, value in pairs(DEFAULTS) do store[key] = options[key] or value end
    store.clock = options.clock
    store.views = {}
    store.order = {}
    store.serial = 0
    store.bytes = 0
    store.revision = 0
    return store
end

function Store:now()
    if self.clock then return self.clock() end
    return os.time() * 1000
end

local function contextMatches(view, context)
    if not context then return true end
    for _, key in ipairs{'session_id', 'level_instance_id', 'connection_generation'} do
        if context[key] ~= nil and view.context[key] ~= context[key] then return false end
    end
    return true
end

function Store:drop(view, reason)
    if not view or view.dropped then return end
    view.dropped = reason or 'dropped'
    self.views[view.id] = nil
    self.bytes = self.bytes - (view.bytes or 0)
    for index = #self.order, 1, -1 do
        if self.order[index] == view.id then table.remove(self.order, index); break end
    end
end

function Store:dropExpired(now)
    now = now or self:now()
    for _, id in ipairs(self.order) do
        local view = self.views[id]
        if view and now >= view.expires_ms then self:drop(view, 'expired') end
    end
end

-- Keep views within count and byte budgets, dropping the oldest first.
function Store:enforceCapacity()
    while #self.order > self.max_views or self.bytes > self.byte_budget do
        local view = self.views[self.order[1]]
        if not view then table.remove(self.order, 1) else self:drop(view, 'evicted') end
    end
end

local function itemSizes(items)
    local sizes, total = {}, 0
    for index, item in ipairs(items) do
        local ok, encoded = pcall(Json.encode, item)
        local size = (ok and type(encoded) == 'string') and #encoded or 32
        sizes[index] = size
        total = total + size
    end
    return sizes, total
end

local function newCursor(view, offset)
    return view.id .. '-p' .. tostring(offset)
end

local function parseCursor(cursor)
    if type(cursor) ~= 'string' then return nil end
    return cursor:match('^(view%-%d+)%-p(%d+)$')
end

function Store:page(view, offset, page_size)
    local now = self:now()
    if now >= view.expires_ms then
        self:drop(view, 'expired')
        return nil, 'cursor_expired'
    end
    local limit = page_size or self.default_page
    if limit > self.max_page then limit = self.max_page end
    if limit < 1 then limit = 1 end
    local items, data_bytes, index = Json.array(), 0, offset + 1
    while index <= #view.items and #items < limit do
        local size = view.sizes[index] or 32
        if #items > 0 and data_bytes + size > self.page_bytes then break end
        if #items == 0 and size > self.page_bytes then return nil, 'item_projection_too_large' end
        data_bytes = data_bytes + size
        items[#items + 1] = view.items[index]
        index = index + 1
    end
    local returned = index - offset - 1
    local has_more = (offset + returned) < #view.items
    return {
        view_id = view.id,
        session_id = view.context.session_id,
        level_instance_id = view.context.level_instance_id,
        captured_revision = view.captured_revision,
        current_revision = self.revision,
        historical = self.revision ~= view.captured_revision,
        collection = view.collection,
        items = items,
        returned_count = returned,
        total_count = #view.items,
        capture_complete = view.capture_complete,
        has_more = has_more,
        next_cursor = has_more and newCursor(view, offset + returned) or Json.null,
        expires_in_ms = math.max(0, view.expires_ms - now),
    }
end

-- Capture a frozen view. `items` is an ordered array of pure data already
-- filtered to what the player may know. `complete` says whether that array is
-- the full allowed set within this view's definition.
function Store:capture(options)
    local now = self:now()
    self:dropExpired(now)
    local items = options.items or {}
    local sizes, total = itemSizes(items)
    if #items > self.max_items or total > self.max_view_bytes then
        return nil, 'collection_limit_exceeded'
    end
    local revision = options.revision or self.revision
    self.revision = revision
    self.serial = self.serial + 1
    local view = {
        id = 'view-' .. tostring(self.serial),
        collection = options.collection,
        items = items,
        sizes = sizes,
        bytes = total,
        capture_complete = options.complete == true,
        context = options.context or {},
        captured_revision = revision,
        expires_ms = now + self.ttl_ms,
    }
    self.views[view.id] = view
    self.order[#self.order + 1] = view.id
    self.bytes = self.bytes + total
    self:enforceCapacity()
    if not self.views[view.id] then return nil, 'collection_limit_exceeded' end
    return self:page(view, 0, options.page_size)
end

function Store:nextPage(cursor, page_size)
    self:dropExpired()
    local id, offset = parseCursor(cursor)
    if not id then return nil, 'cursor_expired' end
    local view = self.views[id]
    if not view then return nil, 'cursor_expired' end
    return self:page(view, tonumber(offset), page_size)
end

function Store:setRevision(revision)
    if type(revision) == 'number' then self.revision = revision end
end

function Store:invalidate(reason)
    local ids = {}
    for _, id in ipairs(self.order) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do self:drop(self.views[id], reason or 'invalidated') end
end

-- Drop views whose captured context no longer matches (session, level or
-- connection generation changed).
function Store:invalidateContext(context)
    local ids, kept = {}, false
    for _, id in ipairs(self.order) do
        local view = self.views[id]
        if view and not contextMatches(view, context) then ids[#ids + 1] = id else kept = true end
    end
    for _, id in ipairs(ids) do self:drop(self.views[id], 'context_changed') end
    return kept
end

function M.parseCursor(cursor) return parseCursor(cursor) end
return M
