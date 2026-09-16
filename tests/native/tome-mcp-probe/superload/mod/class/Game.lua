local _M = loadPrevious(...)
local base = _M.display
function _M:display(...)
    local result = base(self, ...)
    require("mod.MCPProbe").onFrame()
    -- The auto-combat probe (a separate test-only addon) hooks its scenario
    -- runner here so it reuses this already-composed display seam.
    local auto = package.loaded["mod.AutoCombatProbe"]
    if auto then auto.onFrame() end
    return result
end
local save = _M.saveGame
function _M:saveGame(...)
    local result = save(self, ...)
    local Probe = require "mod.MCPProbe"
    if Probe.ready then
        savefile_pipe:pushGeneric("mcp_probe_save_complete", function()
            Probe.emit{kind="save_complete", save_name=self.save_name, state=Probe.state()}
        end)
    end
    return result
end
return _M
