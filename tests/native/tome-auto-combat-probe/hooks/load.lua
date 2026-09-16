-- The native scenario runner is loaded at addon load time (so the shared
-- display seam can find it); the arena-ready signal just arms it.
local Probe=require('mod.AutoCombatProbe')
local class=require 'engine.class'
class:bindHook('AutoCombatProbe:run',function()
    Probe.pending=true
end)
