local _M = loadPrevious(...)
local original = _M.act
function _M:act(...)
    if self.mcp_probe_dummy then
        local Probe = require "mod.MCPProbe"
        Probe.enemy_acts = Probe.enemy_acts + 1
    end
    local result=original(self, ...)
    local interaction=package.loaded['mod.MCPInteractionProbe']
    if self.mcp_probe_dummy and interaction and interaction.npc_chat_armed then
        interaction.npc_chat_armed=false
        require('engine.Chat').new('mcp-probe+acceptance',self,game.player):invoke()
        game:onTickEnd(function()
            game:registerDialog(require('mod.dialogs.QuestPopup').new({name='NPC turn fixture'},engine.Quest.PENDING))
        end,'mcp_chat_npc_notice')
    end
    return result
end
return _M
