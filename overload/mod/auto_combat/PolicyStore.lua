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
--
-- XDP-CLOSE-01 (Fix 1): the vault is a MODULE-LEVEL lexical weak map keyed by
-- the store token (`local VAULT=setmetatable({},{__mode='k'})`). It is NOT an
-- entry of the store table, so `pairs(store)` cannot enumerate it and no public
-- API returns the stored record: every API returns scalars or detached copies
-- (`restore` returns a copy, never the record it stored). A store token created
-- by `M.new` is the only way to reach its vault, and nothing reachable from the
-- token references the vault.
local Codec=require 'mod.auto_combat.PolicyCodec'
local Json=require 'mod.mcp_bridge.Json'
local M={}

-- Module-level private vault: store token -> policy snapshots and migration
-- metadata. draft_source keeps the current draft's pre-migration bytes. Weak
-- keys, so a discarded store does not keep its records alive. Because it is a
-- lexical local of this module, an ordinary holder of the store table cannot
-- name it; because it is not an entry of the store, `pairs(store)` cannot
-- enumerate it.
local VAULT=setmetatable({},{__mode='k'})

local function vault(store)
    local v=VAULT[store]
    if not v then error('PolicyStore: not a store created by PolicyStore.new',3) end
    return v
end

function M.new()
    local store={active=false,revision=0}
    VAULT[store]={draft=nil,draft_source=nil,approved=nil,running=nil}
    return store
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

-- A DETACHED copy of a record: fresh table, scalar fields (immutable strings).
-- Mutating the copy cannot reach the vault.
local function copyRecord(record)
    if not record then return nil end
    return {bytes=record.bytes,hash=record.hash,schema=record.schema,
        id=record.id,version=record.version}
end

-- A caller-supplied record never becomes authority directly: restore
-- normalises it first (used by the service's loadState). XDP-CLOSE-01: the
-- return value is a detached copy, never the record now stored.
function M.restore(store,name,value,sink)
    assert(name=='draft' or name=='approved','PolicyStore.restore: unknown slot')
    local snapshot,err=prepare(value,sink or ('restore_'..name))
    if not snapshot then return nil,err end
    local migrated,migration_err,warnings=Codec.migrate(snapshot)
    if not migrated then return nil,migration_err end
    local v=vault(store)
    if name=='approved' and #warnings>0 then
        -- Approval certified the old implicit fallback. Retain both documents,
        -- move its normalised replacement to draft, and require new approval.
        v.migration={reason='emergency_fallback_migration',warnings=warnings,
            requires_reapproval=true,original_approved=Codec.copy(snapshot),
            previous_draft=v.draft and Codec.copy(v.draft_source or v.draft) or nil}
        v.approved=nil; v.running=nil; store.active=false
        v.draft=migrated; v.draft_source=snapshot
    else
        v[name]=migrated
        -- Capture the current draft's original bytes before migration. A later
        -- legacy approval must not replace this user document with its already
        -- normalized version or with an older migration notice's draft.
        if name=='draft' then v.draft_source=snapshot end
        if #warnings>0 then
            v.migration={reason='emergency_fallback_migration',warnings=warnings,
                requires_reapproval=true,original_draft=Codec.copy(snapshot)}
        end
    end
    store.revision=store.revision+1
    return copyRecord(migrated),nil,warnings
end

-- The hash is always the record's DERIVED hash: every record in the vault was
-- normalised on ingress, so `.hash` is the hash of its exact bytes.
local function hashOf(store,name)
    local record=getRecord(store,name)
    return record and record.hash or nil
end

local function idOf(store,name)
    local record=getRecord(store,name)
    return record and record.id or nil
end

function M.setDraft(store,policy,expected_hash)
    local snapshot,err=prepare(policy,'set_draft')
    if not snapshot then return nil,err end
    local current=hashOf(store,'draft')
    if expected_hash~=nil and current~=expected_hash then
        return nil,{code='policy_conflict',current_draft_hash=current}
    end
    local migrated,migration_err,warnings=Codec.migrate(snapshot)
    if not migrated then return nil,migration_err end
    vault(store).draft=migrated; vault(store).draft_source=snapshot; store.revision=store.revision+1
    if #warnings>0 then
        vault(store).migration={reason='emergency_fallback_migration',warnings=warnings,
            requires_reapproval=true,original_draft=Codec.copy(snapshot)}
    end
    return {draft_hash=migrated.hash,revision=store.revision,warnings=warnings,
        migrated=#warnings>0 or nil}
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
    if vault(store).migration then vault(store).migration.requires_reapproval=false end
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
    vault(store).draft=nil; vault(store).draft_source=nil; store.revision=store.revision+1
    return true
end

function M.migration(store)
    local value=vault(store).migration
    return value and Json.decode(Json.encode(value)) or nil
end

function M.restoreMigration(store,value)
    if type(value)~='table' or Codec.audit(value,'migration') then return false end
    -- Only descriptive user data; no executable policy/approval authority.
    vault(store).migration=Json.decode(Json.encode(value))
    return true
end

function M.hashes(store)
    return {draft=hashOf(store,'draft'),approved=hashOf(store,'approved'),running=hashOf(store,'running')}
end

-- Public status: scalars only (hashes + the running/draft/approved ids). The
-- ids let a public consumer (e.g. `Runtime`'s observe summary) name the running
-- policy without reaching the private records.
function M.status(store)
    local hashes=M.hashes(store)
    return {active=store.active,revision=store.revision,
        draft_hash=hashes.draft,approved_hash=hashes.approved,running_hash=hashes.running,
        draft_id=idOf(store,'draft'),approved_id=idOf(store,'approved'),running_id=idOf(store,'running'),
        migration=M.migration(store)}
end

-- The running policy id, via the public API only (never the private record).
function M.runningId(store)
    return idOf(store,'running')
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

-- XDP-REV-01/XDP-CLOSE-01: a fresh COPY of the private record, never the live
-- table. The copy's fields are immutable strings (bytes/hash); a caller editing
-- the copy edits only the copy.
function M.getSnapshot(store,name)
    return copyRecord(getRecord(store,name))
end

-- Convenience for callers that only need the immutable handle.
function M.setDraftSnapshot(store,snapshot,expected_hash)
    return M.setDraft(store,snapshot,expected_hash)
end

-- XDP-CLOSE-02 (Fix 2): an in-flight transaction captures the store generation
-- and the exact slot hash/ids BEFORE it invokes a caller callback, then compares
-- them AFTER. A reentrant public call (set_draft/approve/activate/deactivate)
-- changes the revision, so the mismatch is detectable without exposing records.
function M.authority(store,name)
    return {revision=store.revision,hash=hashOf(store,name),id=idOf(store,name)}
end

function M.matchesAuthority(store,name,authority)
    if type(authority)~='table' then return false end
    return store.revision==authority.revision and hashOf(store,name)==authority.hash
        and idOf(store,name)==authority.id
end

return M
