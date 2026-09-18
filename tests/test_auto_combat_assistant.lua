-- AssistantAdapter: generation-only, version-pinned translation of a legacy
-- auto-talent-assistant export into a policy draft.
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
local Adapter=require 'mod.auto_combat.AssistantAdapter'
local Schema=require 'mod.auto_combat.PolicySchema'
local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
local Json=require 'mod.mcp_bridge.Json'
local Service=require 'mod.auto_combat.AutoCombatService'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end
local fixture_dir=root..'/tests/fixtures/assistant/'
local function fixture(name)
    local file=assert(io.open(fixture_dir..name,'r'))
    local text=file:read('*a');file:close()
    return Json.decode(text)
end
local function codes(list)
    local out={}
    for _,entry in ipairs(list or {}) do out[entry.code]=(out[entry.code] or 0)+1 end
    return out
end
local function hasCode(list,code)
    for _,entry in ipairs(list or {}) do if entry.code==code then return true end end
    return false
end

-- Pinned accept --------------------------------------------------------------
local pinned=fixture('anorithil_pinned.json')
do
    local detected,err=Adapter.detect(pinned)
    check(detected and err==nil,'the pinned assistant export is detected')
    check(detected.version==Adapter.PINNED.addon_version,'detect returns the pinned version string')
    check(detected.format==Adapter.FORMAT,'detect returns the export format')

    local result=Adapter.translate(pinned)
    check(result.ok==true,'the pinned export translates')
    check(result.draft and result.draft.schema==Schema.SCHEMA,'the translation yields a policy draft')
    check(Schema.validate(result.draft)==true,'the generated draft passes PolicySchema')
    check(Catalog.verify(result.draft)==true,'the generated draft passes AutoCombatCatalog')
    check(result.hash==Schema.hash(result.draft),'the result carries the draft hash')

    -- Rules: heal, barrier, attack, ray, twilight. Unsupported entries dropped.
    check(#result.draft.rules==5,'only the supported talents become rules')
    local byId={}
    for _,rule in ipairs(result.draft.rules) do byId[rule.id]=rule end
    check(byId['healing_light'] and byId['healing_light'].emergency==true,
        'an emergency heal maps with emergency:true')
    check(byId['healing_light']['then'].target=='self','a self talent binds self')
    check(byId['attack'] and byId['attack']['then'].action=='attack' and byId['attack']['then'].talent==nil,
        'T_ATTACK maps to the native attack action')
    check(byId['moonlight_ray']['then'].talent=='T_MOONLIGHT_RAY','a hostile talent maps to use_talent')
    check(byId['twilight'] and byId['twilight']['then'].target=='self','a buff talent binds self')
    check(#result.draft.sustains==2,'only the supported sustains are kept')

    -- Unsupported fields / talents / actions are recorded, never dropped.
    local unsupported=codes(result.unsupported)
    check(unsupported['unsupported_field'] and unsupported['unsupported_field']>=2,
        'unknown top-level and settings fields are reported')
    check(unsupported['unsupported_sustain']==1,'an unknown sustain is reported')
    check(unsupported['unsupported_talent']==1,'an unknown talent is reported')
    check(unsupported['unsupported_action']==1,'an unsupported action is reported')
    check(not hasCode(result.warnings,'unsupported_condition'),
        'a P2.5-wired predicate is accepted without a condition warning')

    -- Determinism.
    local again=Adapter.translate(fixture('anorithil_pinned.json'))
    check(again.hash==result.hash,'translation is deterministic')
end

-- Version / format refusal ---------------------------------------------------
do
    local wrong=fixture('wrong_version.json')
    local detected,err=Adapter.detect(wrong)
    check(detected==nil and err.code=='assistant_version_mismatch',
        'a different assistant version is refused')
    check(err.expected=='2.3.9' and err.got=='9.9.9','the refusal reports expected and got')
    local result=Adapter.translate(wrong)
    check(result.ok==false and result.error.code=='assistant_version_mismatch',
        'translate refuses a mismatched version')
end
do
    local wrong=fixture('wrong_format.json')
    local detected,err=Adapter.detect(wrong)
    check(detected==nil and err.code=='unsupported_format','a different export format is refused')
end
do
    local result=Adapter.translate({format=Adapter.FORMAT})
    check(result.ok==false and result.error.code=='missing_assistant','a missing assistant block is refused')
end

-- Nothing supported ----------------------------------------------------------
do
    local result=Adapter.translate(fixture('unsupported_only.json'))
    check(result.ok==false and result.error.code=='no_supported_rules',
        'an export with only unsupported entries yields no draft')
    check(hasCode(result.error.unsupported,'unsupported_talent')
        and hasCode(result.error.unsupported,'unsupported_sustain'),
        'the refusal still carries the unsupported report')
end

-- Safety mapping -------------------------------------------------------------
do
    local config={format=Adapter.FORMAT,
        assistant={addon='auto_talent_assistant',addon_version={2,3,9},tome_version={1,7,4}},
        class='celestial/anorithil',settings={min_hp_pct=35,flee_below_hp_pct=90,
            max_actions_per_tick=2,default_target='bogus'},
        talents={{talent='T_MOONLIGHT_RAY',enabled=true,priority=10,emergency=true,
            when={enemy_count={ge=1}},target='nearest_hostile'}}}
    local result=Adapter.translate(config)
    check(result.ok==true,'a hostile emergency is still translatable')
    check(not result.draft.rules[1].emergency,'emergency is dropped from a hostile talent')
    check(hasCode(result.warnings,'emergency_not_self_preservation'),
        'a non-self emergency is warned')
    check(result.draft.safety.flee_below_hp_pct==result.draft.safety.min_hp_pct,
        'a flee threshold above min_hp_pct is clamped')
    check(hasCode(result.warnings,'flee_above_min_hp'),'the flee clamp is warned')
    check(result.draft.targeting.default=='nearest_hostile','a bogus default target falls back')
    check(hasCode(result.warnings,'unsupported_selector'),'the bogus selector is warned')
    -- change_level is never generated even if requested.
    local activity=Adapter.translate({format=Adapter.FORMAT,
        assistant={addon='auto_talent_assistant',addon_version={2,3,9}},
        talents={{talent='T_ATTACK',enabled=true,priority=10,action='change_level',
            when={always={}}}}})
    check(activity.ok==false or hasCode(activity.unsupported,'action_not_generated'),
        'generation never emits a native activity or change_level')
end

-- Service path: draft only, never approve/activate/start ---------------------
do
    local svc=Service.new()
    local result=Service.handle(svc,'import_assistant',{config=fixture('anorithil_pinned.json')})
    check(result.ok and result.imported==true and result.draft~=nil,'the service generates a draft')
    check(result.stored==nil and svc.store.draft==nil,'generation alone does not store a draft')
    check(svc.store.approved==nil and svc.store.running==nil,'generation never approves or activates')
    check(result.version and result.version.addon_version=='2.3.9','the result reports the pinned version')

    local stored=Service.handle(svc,'import_assistant',{config=fixture('anorithil_pinned.json'),store=true})
    check(stored.ok and stored.stored and stored.stored.draft_hash,'explicit store writes the draft only')
    check(svc.store.draft~=nil and svc.store.approved==nil and svc.store.running==nil,
        'store writes only the draft')
    local refused=Service.handle(svc,'import_assistant',{config=fixture('wrong_version.json')})
    check(refused.error and refused.error.code=='assistant_version_mismatch',
        'the service refuses a wrong version')
    check(Service.handle(svc,'import_assistant',{}).error.code=='invalid_argument',
        'the service requires a config or document')
end

print('Auto-combat assistant adapter: '..checks..' checks passed')
