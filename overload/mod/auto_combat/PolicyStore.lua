-- GPL-3.0-or-later. Policy store: draft / approved / running versions.
--
-- Writing a draft compares `expected_hash` against the current draft; approving
-- and activating compare against the approved version. A mismatch is a conflict,
-- so a stale client can never silently overwrite another writer's policy. The
-- content hash comes from PolicySchema and ignores editable metadata.
local Schema=require 'mod.auto_combat.PolicySchema'
local M={}

function M.new()
    return {draft=nil,approved=nil,running=nil,active=false,revision=0}
end

local function hashOf(policy) return policy and Schema.hash(policy) or nil end

function M.setDraft(store,policy,expected_hash)
    local ok,errors=Schema.validate(policy)
    if not ok then return nil,{code='invalid_policy',errors=errors} end
    if expected_hash~=nil and hashOf(store.draft)~=expected_hash then
        return nil,{code='policy_conflict',current_draft_hash=hashOf(store.draft)}
    end
    store.draft=policy; store.revision=store.revision+1
    return {draft_hash=hashOf(policy),revision=store.revision}
end

-- Approving certifies a policy. Certification is not control.
function M.approve(store,expected_hash)
    if not store.draft then return nil,{code='no_draft'} end
    if expected_hash~=nil and hashOf(store.draft)~=expected_hash then
        return nil,{code='policy_conflict',current_draft_hash=hashOf(store.draft)}
    end
    store.approved=store.draft; store.revision=store.revision+1
    return {approved_hash=hashOf(store.approved),revision=store.revision}
end

-- Activating promotes the approved policy to the running version.
function M.activate(store,expected_hash)
    if not store.approved then return nil,{code='not_approved'} end
    if expected_hash~=nil and hashOf(store.approved)~=expected_hash then
        return nil,{code='policy_conflict',current_approved_hash=hashOf(store.approved)}
    end
    store.running=store.approved; store.active=true; store.revision=store.revision+1
    return {running_hash=hashOf(store.running),revision=store.revision}
end

function M.deactivate(store)
    store.running=nil; store.active=false; store.revision=store.revision+1
    return true
end

function M.hashes(store)
    return {draft=hashOf(store.draft),approved=hashOf(store.approved),running=hashOf(store.running)}
end

function M.status(store)
    local hashes=M.hashes(store)
    return {active=store.active,revision=store.revision,
        draft_hash=hashes.draft,approved_hash=hashes.approved,running_hash=hashes.running}
end
return M
