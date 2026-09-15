-- Dialog is already cached before addon superloads are installed. Patch its
-- audited native constructors before ToME loads subclasses.
require 'mod.mcp_bridge.NativeDialogSeams'
require 'mod.mcp_bridge.NativeGameSeams'
require 'mod.mcp_bridge.NativeChatSeams'
local class=require 'engine.class'
class:bindHook('ToME:runDone',function()
    require('mod.mcp_bridge.Runtime').reset(game)
end)
