class:bindHook("ToME:birthDone", function()
    game:onTickEnd(function() require("mod.MCPProbe").start() end, "mcp_probe_birth")
end)
class:bindHook('ToME:load',function()
    if __module_extra_info.mcp_probe_interactions then require('mod.MCPInteractionProbe').define() end
end)
class:bindHook("ToME:runDone", function()
    if __module_extra_info.mcp_probe_reload then
        game:onTickEnd(function() require("mod.MCPProbe").reload() end, "mcp_probe_reload")
    end
end)
