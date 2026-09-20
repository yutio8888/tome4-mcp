-- GPL-3.0-or-later. Policy store: draft / approved / running snapshots.
--
-- X-doubleprime: authoritative state is a canonical immutable BYTE snapshot
-- (`PolicyCodec`), never a caller table. Writing a draft compares
-- `expected_hash` against the current draft; approving and activating compare
-- against the approved version. A mismatch is a conflict, so a stale client can
-- never silently overwrite another writer's policy. The content hash is the
-- historical projection of the validated snapshot and ignores editable
-- metadata.
--
-- Every entry point consumes a snapshot RECORD produced by `PolicyCodec`
-- (validated bytes + recorded hash). A raw table arriving here is prepared
-- (audited + validated + encoded) before use — never trusted because of
-- identity. `getVersion` returns a detached decoded copy; `getSnapshot`
-- returns the immutable record (bytes) itself.
local Codec=require 'mod.auto_combat.PolicyCodec'
local M={}

function M.new()
    return {draft=nil,approved=nil,running=nil,active=false,revision=0}
end

-- Accept a snapshot record or a raw policy table. A raw table is validated and
-- encoded here (the store's own transaction boundary); a malformed table is
-- refused typed with nothing published.
local function prepare(value,sink)
    if Codec.isSnapshot(value) then
        -- Re-derive the hash from the bytes and re-validate under the CURRENT
        -- schema, so a retained record cannot be promoted after a schema change
        -- or a record tamper.
        local tree,err=Codec.open(value)
        if not tree then return nil,err end
        return {bytes=value.bytes,hash=Codec.hash(tree),schema=tree.schema,
            id=tree.id,version=Codec.VERSION}
    end
    return Codec.prepare(value,sink or 'store')
end
M.prepare=prepare

local function hashOf(version) return version and version.hash or nil end

function M.setDraft(store,policy,expected_hash)
    local snapshot,err=prepare(policy,'set_draft')
    if not snapshot then return nil,err end
    if expected_hash~=nil and hashOf(store.draft)~=expected_hash then
        return nil,{code='policy_conflict',current_draft_hash=hashOf(store.draft)}
    end
    store.draft=snapshot; store.revision=store.revision+1
    return {draft_hash=snapshot.hash,revision=store.revision}
end

-- Approving certifies a specific snapshot. Certification is not control.
function M.approve(store,expected_hash)
    if not store.draft then return nil,{code='no_draft'} end
    if expected_hash~=nil and hashOf(store.draft)~=expected_hash then
        return nil,{code='policy_conflict',current_draft_hash=hashOf(store.draft)}
    end
    -- Bind the SPECIFIC snapshot bytes: a later edit of any returned copy
    -- cannot change what the approval means.
    store.approved=store.draft; store.revision=store.revision+1
    return {approved_hash=store.approved.hash,revision=store.revision}
end

-- Activating promotes the approved snapshot to the running version.
function M.activate(store,expected_hash)
    if not store.approved then return nil,{code='not_approved'} end
    if expected_hash~=nil and hashOf(store.approved)~=expected_hash then
        return nil,{code='policy_conflict',current_approved_hash=hashOf(store.approved)}
    end
    store.running=store.approved; store.active=true; store.revision=store.revision+1
    return {running_hash=store.running.hash,revision=store.revision}
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

-- Detached decoded copies for public consumers. Mutating them cannot reach the
-- stored bytes.
function M.getVersion(store,name)
    local snapshot=store[name]
    if not snapshot then return nil end
    return select(1,Codec.open(snapshot))
end

function M.getSnapshot(store,name)
    return store[name]
end

-- Convenience for callers that only need the immutable handle.
function M.setDraftSnapshot(store,snapshot,expected_hash)
    return M.setDraft(store,snapshot,expected_hash)
end

return M
