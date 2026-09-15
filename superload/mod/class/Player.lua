local _M=loadPrevious(...)
local Runtime=require 'mod.mcp_bridge.Runtime'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Manifest=require 'mod.mcp_bridge.NativeManifest'
-- Wilderness playerFOV returns after native applyLite; it never sets infovs.
-- Register identities and full source checksums without changing FOV execution.
Compat.register('playerFOV',_M.playerFOV,_M.playerFOV,'/mod/class/Player.lua',Manifest.player_md5)
Compat.register('computeFOV',_M.computeFOV,_M.computeFOV,'/engine/interface/ActorFOV.lua',Manifest.actor_fov_md5)
local Map=require 'engine.Map'
for _,name in ipairs{'applyLite','cleanFOV'} do
    Compat.register('map.'..name,Map[name],Map[name],'/engine/Map.lua',Manifest.map_md5)
end
require('mod.mcp_bridge.NativeItemSeams')(_M)
Compat.register('playerGetTarget',_M.getTarget,_M.getTarget,'/mod/class/Player.lua',Manifest.player_md5)
local useEnergy=_M.useEnergy
if useEnergy then
function _M:useEnergy(...)
    local before=self.energy and self.energy.value
    local ret=useEnergy(self,...)
    Runtime.recordEnergy(self,before,self.energy and self.energy.value)
    return ret
end
Compat.register('playerUseEnergy',_M.useEnergy,useEnergy,'/mod/class/Player.lua',Manifest.player_md5)
end
local act=_M.act
function _M:act(...)
    local ret=act(self,...)
    Runtime.onReady(self)
    return ret
end
local automatic=_M.automaticTalents
function _M:automaticTalents(...)
    if Runtime.hasControl(self) then return end
    return automatic(self,...)
end
local restStep=_M.restStep
function _M:restStep(...)
    local allowed,task=Runtime.beforeRestStep(self)
    if not allowed then return false end
    local energy=self.energy.value
    local ret=restStep(self,...)
    Runtime.afterRestStep(self,energy,task)
    return ret
end
local restStop=_M.restStop
function _M:restStop(message,...)
    local command,was_stopping=Runtime.onRestStop(self,message)
    local ok,ret=pcall(restStop,self,message,...)
    Runtime.afterRestStop(command,was_stopping)
    if not ok then Runtime.onRestStopError(command);error(ret,0) end
    return ret
end
Compat.alias('playerRestStop',_M.restStop,'restStop',restStop)
local takeHit=_M.onTakeHit
function _M:onTakeHit(...)
    Runtime.markRestInterruption(self,'damaged')
    return takeHit(self,...)
end
local setEffect=_M.on_set_temporary_effect
function _M:on_set_temporary_effect(id,effect,parameters,...)
    if effect and effect.status=='detrimental' and not effect.no_stop_resting and parameters and (parameters.dur or 0)>0 then
        Runtime.markRestInterruption(self,'detrimental_effect')
    end
    return setEffect(self,id,effect,parameters,...)
end
return _M
