-- Policy presets and versioned import/export.
-- P3-b (TODO #63): derive the addon root from this test's own path so a bare
-- relative invocation fails loudly instead of silently testing the canonical
-- `game/addons/tome-mcp-bridge` tree from another checkout.
local root=(arg[0] or ''):match('^(.*)[/\\]tests[/\\][^/\\]+$')
if root==nil and (arg[0] or ''):match('^tests[/\\][^/\\]+$') then root='.' end
local root_name=(arg[0] or ''):match('([^/\\]+)$') or 'this test'
local root_probe=root and io.open(root..'/tests/'..root_name,'r')
assert(root_probe,'cannot resolve the addon root from '..tostring(arg[0])..'; invoke this test as '
    ..'<addon>/tests/'..root_name..' or ./tests/'..root_name..' (bare paths are rejected so a '
    ..'mis-invocation never silently tests another checkout)')
root_probe:close()
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
    -- The pilot preset declares an explicit cooldown-recovery wait so a fight
    -- does not stop every opportunity while the main ray recharges.
    local recover
    for _,rule in ipairs(Presets.get('anorithil_p1a').rules) do
        if rule.id=='recover' then recover=rule end
    end
    check(recover and recover['then'].action=='wait','the pilot preset has an explicit wait recovery rule')
    -- D-3: the pilot preset chooses the non-parking new-enemy mode so a group
    -- fight keeps acting instead of pausing on every wandering enemy.
    local preset=Presets.get('anorithil_p1a')
    check(preset.mode and preset.mode.on_new_enemy=='continue',
        'the anorithil preset continues on a new enemy (D-3)')
    check(preset.safety.pause_on_new_enemy==false,
        'the legacy new-enemy boolean stays coherent with the mode (D-3)')
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
