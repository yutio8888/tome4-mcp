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
-- XDP-REV-01: snapshot RECORDS are PRIVATE. They live in a vault keyed by a
-- unique Lua table (a key no caller can reconstruct), so no string-keyed field
-- of the store is ever the live record. `getSnapshot` returns a fresh COPY of
-- the record (mutating it cannot reach the store) and `getVersion` a detached
-- decoded policy tree. Every ingress (setDraft), promotion (approve/activate)
-- and restore (restore) normalises its input through `Codec.prepare` /
-- `Codec.normalise`: the bytes are re-opened and re-validated under the CURRENT
-- schema and the hash is re-derived from the exact bytes — a supplied `.hash`
-- is never authority, and the promoted record is never the same table
-- reference. Because every record in the vault was produced by that route, its
-- recorded `.hash` is the derived hash of its exact bytes.
local Codec=require 'mod.auto_combat.PolicyCodec'
local M={}

-- Unique table key: the record vault is not reachable through any string key,
-- so an ordinary holder of the store/service table never holds a record alias.
local PRIVATE={}

function M.new()
    return {[PRIVATE]={draft=nil,approved=nil,running=nil},active=false,revision=0}
end

local function vault(store)
    local v=store[PRIVATE]
    if not v then error('PolicyStore: not a store created by PolicyStore.new',3) end
    return v
end

local function getRecord(store,name)
    return vault(store)[name]
end

-- Normalise ANY input (a raw policy table, a snapshot record, a wire-shaped
-- {bytes,hash} dict) into a fresh private record: complete audit + current
-- schema/catalog validation + canonical bytes + a hash re-derived from the
-- exact bytes. A malformed input is refused typed with nothing published.
local function prepare(value,sink)
    if Codec.isSnapshot(value) then
        return Codec.normalise(value)
    end
    return Codec.prepare(value,sink or 'store')
end
M.prepare=prepare

-- A caller-supplied record never becomes authority directly: restore
-- normalises it first (used by the service's loadState).
function M.restore(store,name,value,sink)
    assert(name=='draft' or name=='approved','PolicyStore.restore: unknown slot')
    local snapshot,err=prepare(value,sink or ('restore_'..name))
    if not snapshot then return nil,err end
    vault(store)[name]=snapshot
    store.revision=store.revision+1
    return snapshot
end

-- The hash is always the record's DERIVED hash: every record in the vault was
-- normalised on ingress, so `.hash` is the hash of its exact bytes.
local function hashOf(store,name)
    local record=getRecord(store,name)
    return record and record.hash or nil
end

function M.setDraft(store,policy,expected_hash)
    local snapshot,err=prepare(policy,'set_draft')
    if not snapshot then return nil,err end
    local current=hashOf(store,'draft')
    if expected_hash~=nil and current~=expected_hash then
        return nil,{code='policy_conflict',current_draft_hash=current}
    end
    vault(store).draft=snapshot; store.revision=store.revision+1
    return {draft_hash=snapshot.hash,revision=store.revision}
end

-- Approving certifies a specific snapshot. Certification is not control.
function M.approve(store,expected_hash)
    local draft=getRecord(store,'draft')
    if not draft then return nil,{code='no_draft'} end
    local current=hashOf(store,'draft')
    if expected_hash~=nil and current~=expected_hash then
        return nil,{code='policy_conflict',current_draft_hash=current}
    end
    -- XDP-REV-01: promote a FRESH record re-derived from the exact bytes; a
    -- later edit of any returned copy cannot change what the approval means.
    local approved,err=Codec.normalise(draft)
    if not approved then return nil,err end
    vault(store).approved=approved; store.revision=store.revision+1
    return {approved_hash=approved.hash,revision=store.revision}
end

-- Activating promotes the approved snapshot to the running version.
function M.activate(store,expected_hash)
    local approved=getRecord(store,'approved')
    if not approved then return nil,{code='not_approved'} end
    local current=hashOf(store,'approved')
    if expected_hash~=nil and current~=expected_hash then
        return nil,{code='policy_conflict',current_approved_hash=current}
    end
    local running,err=Codec.normalise(approved)
    if not running then return nil,err end
    vault(store).running=running; store.active=true; store.revision=store.revision+1
    return {running_hash=running.hash,revision=store.revision}
end

function M.deactivate(store)
    vault(store).running=nil; store.active=false; store.revision=store.revision+1
    return true
end

function M.clearDraft(store)
    vault(store).draft=nil; store.revision=store.revision+1
    return true
end

function M.hashes(store)
    return {draft=hashOf(store,'draft'),approved=hashOf(store,'approved'),running=hashOf(store,'running')}
end

function M.status(store)
    local hashes=M.hashes(store)
    return {active=store.active,revision=store.revision,
        draft_hash=hashes.draft,approved_hash=hashes.approved,running_hash=hashes.running}
end

-- Whether a slot currently holds a record (the vault itself stays private).
function M.has(store,name)
    return getRecord(store,name)~=nil
end

-- Detached decoded copies for public consumers. Mutating them cannot reach the
-- stored bytes.
function M.getVersion(store,name)
    local snapshot=getRecord(store,name)
    if not snapshot then return nil end
    return select(1,Codec.open(snapshot))
end

-- XDP-REV-01: a fresh COPY of the private record, never the live table. The
-- copy's fields are immutable strings (bytes/hash); a caller editing the copy
-- edits only the copy.
function M.getSnapshot(store,name)
    local record=getRecord(store,name)
    if not record then return nil end
    return {bytes=record.bytes,hash=record.hash,schema=record.schema,
        id=record.id,version=record.version}
end

-- Convenience for callers that only need the immutable handle.
function M.setDraftSnapshot(store,snapshot,expected_hash)
    return M.setDraft(store,snapshot,expected_hash)
end

return M
