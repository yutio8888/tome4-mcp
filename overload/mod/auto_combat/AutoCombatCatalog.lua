-- GPL-3.0-or-later. Capability catalogue facade for the frozen P1 talent
-- whitelist. The canonical data lives in the v2 `EffectManifest`; this module
-- exposes the conservative, derived compatibility view the policy validator and
-- capability summary consume. It is never the guard's source of truth.
--
-- Static data only: nothing here calls the engine or the talent itself.
local Manifest=require 'mod.auto_combat.EffectManifest'
local M={}
M.VERSION=Manifest.VERSION
M.SCHEMA=Manifest.SCHEMA
M.SOURCES=Manifest.SOURCES
M.UNSUPPORTED=Manifest.UNSUPPORTED

local derived={}
for talent,entry in pairs(Manifest.ENTRIES) do
    local compat=Manifest.compat(entry)
    derived[talent]={kind=entry.kind,target=entry.target,resource=entry.resource,
        range=entry.range,radius=entry.radius,direct_hit=entry.direct_hit,melee=entry.melee,
        shape=compat.shape,delivery=compat.delivery,selffire=compat.selffire,
        friendlyfire=compat.friendlyfire,friendlyfire_risk=compat.friendlyfire_risk,
        cursor=compat.cursor,ground=compat.ground,secondary=compat.secondary,
        union=compat.union,components=compat.components,callbacks=entry.callbacks,
        manifest=entry}
end
M.ENTRIES=derived
M.HOSTILE_SELECTORS=Manifest.HOSTILE_SELECTORS
M.SELF_SELECTORS=Manifest.SELF_SELECTORS
M.ACTIONS=Manifest.ACTIONS

function M.actionSupported(action) return action~=nil and M.ACTIONS[action]~=nil end
function M.supported(talent) return talent~=nil and M.ENTRIES[talent]~=nil end
function M.entry(talent) return M.ENTRIES[talent] end
function M.manifestEntry(talent) return Manifest.ENTRIES[talent] end
function M.isSustain(talent)
    local entry=M.ENTRIES[talent]; return entry~=nil and entry.kind=='sustain'
end
function M.verify(policy) return Manifest.verify(policy) end

function M.summary()
    local summary=Manifest.summary()
    local actions={}
    for action,entry in pairs(M.ACTIONS) do
        actions[#actions+1]={action=action,kind=entry.kind,activity=entry.activity,
            default_max_turns=entry.default_max_turns,default_enabled=entry.default_enabled}
    end
    table.sort(actions,function(a,b) return a.action<b.action end)
    summary.actions=actions
    return summary
end

return M
