-- Diagnostic wrappers live on the class, so no closure is serialized in a player.
local _M = loadPrevious(...)
for _, name in ipairs{"moveDir", "waitTurn", "useTalent", "attackTarget"} do
    -- v2 audits useTalent identity. Trace its tracker events instead; do not
    -- disguise a test wrapper as a production-compatible native entrypoint.
    if name~='useTalent' or not __module_extra_info.mcp_probe_interactions then
    local original = assert(_M[name])
    _M[name] = function(self, ...)
        local Probe = require "mod.MCPProbe"
        if not Probe.ready or self ~= game.player then return original(self, ...) end
        Probe.actions = Probe.actions + 1
        local args = {n=select("#", ...), ...}
        local before = Probe.state()
        local function pack(...) return {n=select("#", ...), ...} end
        local result = pack(original(self, unpack(args, 1, args.n)))
        Probe.emit{kind="native_action", method=name, argument=tostring(args[1]),
            before=before, after=Probe.state(), returned=tostring(result[1])}
        return unpack(result, 1, result.n)
    end
    end
end
return _M
