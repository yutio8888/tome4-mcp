-- GPL-3.0-or-later. Versioned policy import/export.
--
-- The envelope carries a format number and the content hash, so a stale or
-- hand-edited policy is rejected on import instead of silently changing the
-- plugin's behaviour. Import revalidates against the schema and the capability
-- catalogue: an imported file is untrusted input.
local Json=require 'mod.mcp_bridge.Json'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local Adapter=require 'mod.auto_combat.AssistantAdapter'
local Codec=require 'mod.auto_combat.PolicyCodec'
local M={}
M.ENVELOPE='tome-auto-combat-policy'
M.FORMAT=1

function M.export(policy)
    -- X-doubleprime: export is a hash sink. The policy is re-validated in full
    -- (a detached decoded snapshot is accepted too, since `Codec.open`
    -- re-validates it) before the envelope hash is projected.
    local snapshot,err=Adapter.policySnapshot(policy,'export')
    if not snapshot then return nil,err end
    local tree=select(1,Codec.open(snapshot))
    if not tree then return nil,{code='invalid_policy'} end
    return Json.encode{format=M.FORMAT,envelope=M.ENVELOPE,hash=snapshot.hash,policy=tree}
end

function M.import(text)
    if type(text)~='string' or #text==0 then return nil,{code='invalid_json'} end
    local ok,data=pcall(Json.decode,text)
    if not ok or type(data)~='table' or data==Json.null then return nil,{code='invalid_json'} end
    if data.envelope~=M.ENVELOPE then return nil,{code='wrong_envelope'} end
    if data.format~=M.FORMAT then return nil,{code='unsupported_format',format=data.format} end
    if type(data.policy)~='table' then return nil,{code='missing_policy'} end
    -- X-doubleprime: the decoded document is untrusted; validate it fully (the
    -- same transaction every other sink uses) BEFORE projecting a hash or
    -- comparing the envelope hash.
    local snapshot,err=Adapter.policySnapshot(data.policy,'import')
    if not snapshot then return nil,err.code=='invalid_policy' and {code='invalid_policy'} or err end
    local hash=snapshot.hash
    if type(data.hash)=='string' and data.hash~=hash then
        return nil,{code='hash_mismatch',expected=data.hash,actual=hash}
    end
    return select(1,Codec.open(snapshot)),{hash=hash}
end
return M
