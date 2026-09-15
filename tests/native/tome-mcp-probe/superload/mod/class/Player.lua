-- Diagnostic wrappers live on the class, so no closure is serialized in a player.
local _M = loadPrevious(...)
for _, name in ipairs{"moveDir", "waitTurn", "attackTarget"} do
    -- v3 audits useTalent identity; do not wrap it. Trace its tracker events
    -- instead and keep the production-compatible native entrypoint intact.
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
return _M
