-- Dialog is already cached before addon superloads are installed. Patch its
-- audited native constructors before ToME loads subclasses.
require 'mod.mcp_bridge.NativeDialogSeams'
require 'mod.mcp_bridge.NativeGameSeams'
require 'mod.mcp_bridge.NativeChatSeams'
local class=require 'engine.class'
class:bindHook('ToME:load',function()
    -- Ctrl+G opens the standalone auto-combat policy editor; Ctrl+Shift+G
    -- starts/stops it. Both are deliberately independent of the MCP transport:
    -- a human can use the plugin with no client attached (design 6.1 / 9.3).
    local KeyBind=require('engine.KeyBind')
    KeyBind:defineAction{default={'sym:_g:true:false:false:false'},type='AUTO_COMBAT_POLICY',
        group='actions',name=_t'Auto-combat policy'}
    KeyBind:defineAction{default={'sym:_g:true:true:false:false'},type='AUTO_COMBAT_TOGGLE',
        group='actions',name=_t'Start or stop auto-combat'}
end)
class:bindHook('ToME:runDone',function()
    require('mod.mcp_bridge.Runtime').reset(game)
    -- Establish the read-only dependency baseline for the cost helpers once the
    -- native player methods are loaded (spec QRY-02).
    require('mod.mcp_bridge.TalentQuery').registerNative(game.player)
    local function openEditor()
        require('mod.auto_combat.ui.PolicyEditor').open(game.player)
    end
    game.key:addBind('AUTO_COMBAT_POLICY',openEditor)
    -- Native start/stop hotkey keeps the standalone form usable without MCP.
    game.key:addBind('AUTO_COMBAT_TOGGLE',function()
        local Runtime=require 'mod.mcp_bridge.Runtime'
        local status=Runtime.autoCombatStatus(game) or {}
        local running=status.run and status.run.state~='stopped'
        if running then
            Runtime.autoCombatHandle(game,'stop',{reason='hotkey'})
        else
            local start=Runtime.autoCombatHandle(game,'start',{})
            if not start.ok and start.error then
                game.log('#LIGHT_RED#Auto-combat: '..tostring(start.error.code)..'#LAST#')
            end
        end
    end)
end)
class:bindHook('Game:alterGameMenu',function(self,data)
    data.menu[#data.menu+1]={_t'Auto-combat policy',function()
        if data.unregister then data.unregister() end
        require('mod.auto_combat.ui.PolicyEditor').open(game.player)
    end}
end)
