-- Runtime handlers are excluded by the engine's save-field rules.
local M={}
local wrapped=setmetatable({}, {__mode='k'})
local function wrap(handler, method, g, before)
    if not handler or type(handler[method])~='function' then return end
    local attached=wrapped[handler]
    if attached and attached.fn==handler[method] and attached.game==g then return end
    local original=handler[method]
    local function receive(self,...)
        before(self,...)
        return original(self,...)
    end
    handler[method]=receive
    -- Lua 5.1 weak keys are not ephemerons: a strong value pointing through
    -- Game back to its handler would keep the old game alive after reload.
    wrapped[handler]=setmetatable({fn=receive,game=g},{__mode='v'})
end
local function attachHandlers(g,owner)
    local game_ref=setmetatable({g},{__mode='v'})
    wrap(owner.key,'receiveKey',g,function(self,sym,ctrl,shift,alt,meta,unicode,isup)
        local current=game_ref[1]
        if current and not isup then require('mod.mcp_bridge.Runtime').manualInput(current,'keyboard') end
    end)
    wrap(owner.mouse,'receiveMouse',g,function(self,button,x,y,isup)
        local current=game_ref[1]
        if current and not isup then require('mod.mcp_bridge.Runtime').manualInput(current,'mouse') end
    end)
end
function M.attach(g)
    attachHandlers(g,g)
    for _,dialog in ipairs(g.dialogs or {}) do attachHandlers(g,dialog) end
end
return M
