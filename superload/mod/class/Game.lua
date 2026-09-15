local _M=loadPrevious(...)
local Runtime=require 'mod.mcp_bridge.Runtime'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Manifest=require 'mod.mcp_bridge.NativeManifest'
local display=_M.display
function _M:display(...)
    local ret=display(self,...)
    Runtime.onFrame(self)
    return ret
end
local tick=_M.tick
function _M:tick(...)
    Runtime.beforeTick(self)
    local ok,ret=pcall(tick,self,...)
    if not ok then pcall(Runtime.onNativeError,self,'native_tick_error',true);error(ret,0) end
    Runtime.afterTick(self)
    return ret
end
local loaded=_M.loaded
function _M:loaded(...)
    local ret=loaded(self,...)
    Runtime.reset(self)
    return ret
end
local register=_M.onRegisterDialog
function _M:onRegisterDialog(dialog,...)
    Runtime.boundary(self,'dialog',true,dialog)
    return register(self,dialog,...)
end
local unregister=_M.onUnregisterDialog
function _M:onUnregisterDialog(dialog,...)
    local ret=unregister(self,dialog,...)
    Runtime.boundary(self,'dialog',false,dialog)
    return ret
end
local change=_M.changeLevelReal
function _M:changeLevelReal(...)
    local ticket=Runtime.beginSceneChange(self)
    local ok,ret=pcall(change,self,...)
    Runtime.endSceneChange(self,ticket,ok)
    if not ok then pcall(Runtime.onNativeError,self,'native_change_error',false);error(ret,0) end
    return ret
end
Compat.register('changeLevelReal',_M.changeLevelReal,change,'/mod/class/Game.lua',Manifest.game_md5,
    {path='/mod/addons/battle-companion/superload/mod/class/Game.lua',digest=Manifest.companion_game_md5,upvalue='change'})
local save=_M.saveGame
function _M:saveGame(...)
    if Runtime.deferSave(self) then return end
    Runtime.boundary(self,'saving',true)
    local ok,ret=pcall(save,self,...)
    Runtime.boundary(self,'saving',false)
    if not ok then pcall(Runtime.onNativeError,self,'native_save_error',false);error(ret,0) end
    return ret
end
return _M
