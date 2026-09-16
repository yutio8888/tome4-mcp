-- Policy presets and versioned import/export.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Presets=require 'mod.auto_combat.PolicyPresets'
local PolicyIO=require 'mod.auto_combat.PolicyIO'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- Presets are real policies ---------------------------------------------------
local names=Presets.names()
check(#names>=1 and names[1]=='anorithil_p1a','the P1a pilot preset is registered')
for _,name in ipairs(names) do
    local policy=Presets.get(name)
    check(Schema.validate(policy)==true,'preset '..name..' passes the schema')
    check(Catalog.verify(policy)==true,'preset '..name..' is semantically compatible')
end
do
    local edit=Presets.copy('anorithil_p1a')
    edit.rules[1].priority=1
    check(Presets.get('anorithil_p1a').rules[1].priority==100,'copy() does not mutate the built-in preset')
    check(Presets.copy('missing')==nil,'an unknown preset name returns nil')
    local summaries=Presets.summaries()
    check(summaries[1].name=='anorithil_p1a' and summaries[1].rules>0,'summaries list the presets')
end

-- Import/export ---------------------------------------------------------------
local preset=Presets.get('anorithil_p1a')
do
    local document,err=PolicyIO.export(preset)
    check(type(document)=='string' and err==nil,'a valid policy exports to a document')
    local policy,info=PolicyIO.import(document)
    check(policy~=nil and info.hash==Schema.hash(preset),'the document round-trips to the same policy')
    check(PolicyIO.import(document)~=nil,'a freshly exported document imports')
end
do
    local document=PolicyIO.export(preset)
    -- A hand-edited body with the stale hash is refused.
    local decoded=Json.decode(document)
    decoded.policy.rules[1].priority=1
    local tampered=Json.encode(decoded)
    check(tampered~=document,'the tamper helper changed the document')
    local policy,err=PolicyIO.import(tampered)
    check(policy==nil and err.code=='hash_mismatch','a tampered policy is refused')
end
do
    local policy,err=PolicyIO.import('{"envelope":"other","format":1,"policy":{}}')
    check(policy==nil and err.code=='wrong_envelope','a foreign envelope is refused')
    policy,err=PolicyIO.import('{"envelope":"tome-auto-combat-policy","format":99,"policy":{}}')
    check(policy==nil and err.code=='unsupported_format','an unknown format is refused')
    policy,err=PolicyIO.import('not json')
    check(policy==nil and err.code=='invalid_json','malformed json is refused')
    policy,err=PolicyIO.import('{"envelope":"tome-auto-combat-policy","format":1}')
    check(policy==nil and err.code=='missing_policy','a missing policy is refused')
end
do
    local invalid=Presets.copy('anorithil_p1a')
    invalid.rules[1]['then'].talent='T_NOT_ALLOWED'
    local document,err=PolicyIO.export(invalid)
    check(document==nil and err.code=='invalid_policy','an invalid policy cannot be exported')
    local payload='{"envelope":"tome-auto-combat-policy","format":1,"policy":'..Schema.canonical(invalid)..'}'
    local policy,err2=PolicyIO.import(payload)
    check(policy==nil and err2.code=='invalid_policy','an invalid imported policy is refused')
end

print('Auto-combat IO: '..checks..' checks passed')
