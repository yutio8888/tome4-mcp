-- GPL-3.0-or-later. Control arbiter: who may drive the native action stream.
--
-- Certification (a policy being approved) is deliberately separate from control:
-- an approved policy still cannot act until it owns the lease. Manual input
-- always wins and returns the lease to the player.
local M={}
M.SOURCES={manual=true,mcp=true,auto_combat=true}

function M.new()
    return {owner='manual',lease=0,revision=0,reason='initial'}
end

function M.owner(a) return a.owner end
function M.canAct(a,source) return a.owner==source end
function M.isManual(a) return a.owner=='manual' end

-- Grant the lease to a non-manual source. Manual must explicitly hand over.
function M.grant(a,source,reason)
    if not M.SOURCES[source] or source=='manual' then return false,'invalid_source' end
    if a.owner==source then a.revision=a.revision+1; return true,'already_owned' end
    if a.owner~='manual' then return false,'control_busy' end
    a.owner=source; a.lease=a.lease+1; a.revision=a.revision+1
    a.reason=reason or 'granted'
    return true,'granted'
end

-- A manual input revokes any held lease immediately.
function M.manualInput(a,reason)
    local previous=a.owner
    a.owner='manual'; a.lease=a.lease+1; a.revision=a.revision+1
    a.reason=reason or 'manual_input'
    return previous~='manual',previous
end

function M.revoke(a,source,reason)
    if a.owner~=source then return false,'not_owner' end
    a.owner='manual'; a.lease=a.lease+1; a.revision=a.revision+1
    a.reason=reason or 'revoked'
    return true
end

function M.status(a)
    return {owner=a.owner,lease=a.lease,revision=a.revision,reason=a.reason,
        actionable=a.owner~='manual'}
end
return M
