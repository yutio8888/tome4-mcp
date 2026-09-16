-- GPL-3.0-or-later. Versioned policy import/export.
--
-- The envelope carries a format number and the content hash, so a stale or
-- hand-edited policy is rejected on import instead of silently changing the
-- plugin's behaviour. Import revalidates against the schema and the capability
-- catalogue: an imported file is untrusted input.
local Json=require 'mod.mcp_bridge.Json'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local M={}
M.ENVELOPE='tome-auto-combat-policy'
M.FORMAT=1

local function verify(policy)
    local ok,errors=Schema.validate(policy)
    if not ok then return nil,{code='invalid_policy',errors=errors} end
    local compatible,semantic=Catalog.verify(policy)
    if not compatible then return nil,{code='invalid_policy',errors=semantic} end
    return true
end

function M.export(policy)
    local valid,err=verify(policy)
    if not valid then return nil,err end
    return Json.encode{format=M.FORMAT,envelope=M.ENVELOPE,hash=Schema.hash(policy),policy=policy}
end

function M.import(text)
    if type(text)~='string' or #text==0 then return nil,{code='invalid_json'} end
    local ok,data=pcall(Json.decode,text)
    if not ok or type(data)~='table' or data==Json.null then return nil,{code='invalid_json'} end
    if data.envelope~=M.ENVELOPE then return nil,{code='wrong_envelope'} end
    if data.format~=M.FORMAT then return nil,{code='unsupported_format',format=data.format} end
    if type(data.policy)~='table' then return nil,{code='missing_policy'} end
    local valid,err=verify(data.policy)
    if not valid then return nil,err end
    local hash=Schema.hash(data.policy)
    if type(data.hash)=='string' and data.hash~=hash then
        return nil,{code='hash_mismatch',expected=data.hash,actual=hash}
    end
    return data.policy,{hash=hash}
end
return M
