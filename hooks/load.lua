-- Dialog is already cached before addon superloads are installed. Patch its
-- audited native constructors before ToME loads subclasses.
require 'mod.mcp_bridge.NativeDialogSeams'
require 'mod.mcp_bridge.NativeGameSeams'
require 'mod.mcp_bridge.NativeChatSeams'
local class=require 'engine.class'
class:bindHook('ToME:runDone',function()
    require('mod.mcp_bridge.Runtime').reset(game)
    -- Establish the read-only dependency baseline for the cost helpers once the
    -- native player methods are loaded (spec QRY-02).
    require('mod.mcp_bridge.TalentQuery').registerNative(game.player)
end)
