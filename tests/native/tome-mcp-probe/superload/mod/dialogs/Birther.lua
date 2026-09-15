local _M = loadPrevious(...)
local base = _M.on_register
function _M:on_register(...)
    local result = base(self, ...)
    assert(config.settings.cheat and not __module_extra_info.auto_quickbirth)
    game:onTickEnd(function()
        assert(game.creating_player and not game.level)
        require("mod.MCPProbe").emit{kind="birth_started", new_character=true}
        self:makeDefault()
    end, "mcp_probe_default_birth")
    return result
end
return _M
