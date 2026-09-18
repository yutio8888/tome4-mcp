-- PolicyEditorModel: availability rules of the standalone in-game editor.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Model=require 'mod.auto_combat.PolicyEditorModel'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local function option(options,id)
    for _,entry in ipairs(options) do if entry.id==id then return entry end end
    return nil
end

-- Fresh: nothing approved, nothing running.
do
    local status={draft_hash='aaaa',approved_hash=nil,running_hash=nil,active=false,
        control_owner='manual',actionable=false,strict=true,run={state='stopped'}}
    local options=Model.options(status)
    check(option(options,'activate').enabled==false and option(options,'activate').reason=='not_approved',
        'activate is blocked without an approved policy')
    check(option(options,'start').enabled==false and option(options,'start').reason=='not_activated',
        'start is blocked without an activated policy')
    check(option(options,'export').enabled==true,'a draft can be exported')
    check(option(options,'preset').enabled==true,'a preset can always be loaded')
    check(option(options,'pause').enabled==false,'pause needs a running plugin')
end

-- Approved+active and running: start/stop/pause become available.
do
    local status={approved_hash='bbbb',running_hash='bbbb',active=true,
        control_owner='auto_combat',actionable=true,strict=true,run={state='running',generation=3}}
    local options=Model.options(status)
    check(option(options,'activate').enabled==false and option(options,'activate').reason=='already_active',
        'an active policy cannot be re-activated')
    check(option(options,'start').enabled==false and option(options,'start').reason=='already_running',
        'a running plugin cannot be started twice')
    check(option(options,'stop').enabled==true,'a running plugin can be stopped')
    check(option(options,'pause').enabled==true,'a running plugin can be paused')
    check(option(options,'resume').enabled==false and option(options,'resume').reason=='not_paused',
        'resume needs a paused plugin')
    check(Model.canApply(status,'stop')==true,'canApply agrees with the option table')
end

do
    local status={approved_hash='bbbb',running_hash='bbbb',active=true,
        control_owner='auto_combat',actionable=true,run={state='paused',generation=4}}
    check(option(Model.options(status),'pause').enabled==false,'an already paused plugin cannot pause again')
    check(option(Model.options(status),'resume').enabled==true,'a paused plugin can resume')
    check(Model.canApply(status,'resume')==true,'canApply enables resume')
    check(Model.canApply(status,'frobnicate')==false,'an unknown action is refused')
end

-- The status lines are stable and never nil.
do
    local lines=Model.lines({approved_hash='0123456789',running_hash=nil,active=false,
        control_owner='manual',run={state='stopped'}})
    check(#lines==4 and lines[1]:find('01234567',1,true)~=nil,'status lines shorten hashes')
    check(Model.lines(nil)[1]:find('none',1,true)~=nil,'a missing status still renders')
end

do
    local op,args=Model.request('preset','anorithil_p1a')
    check(op=='preset' and args.name=='anorithil_p1a','the preset action carries the name')
    op,args=Model.request('start')
    check(op=='start' and next(args)==nil,'a plain action carries no arguments')
    check(Model.request('bogus')==nil,'an unknown request maps to nil')
end

-- Editing: fields describe the current policy and every mutation is a pure
-- clone (the source policy is never modified).
do
    local Presets=require 'mod.auto_combat.PolicyPresets'
    local original=Presets.copy('anorithil_p1a')
    local fields=Model.fields(original)
    check(#fields>4,'the editor exposes global setting and rule fields')
    local byId={}
    for _,field in ipairs(fields) do byId[field.id]=field end
    check(byId['limits.max_actions_per_tick']~=nil,'limits are editable')
    check(byId['safety.min_hp_pct']~=nil,'safety thresholds are editable')
    check(byId['rules.heal.enabled']~=nil,'rule enabled state is editable')
    check(byId['rules.heal.priority']~=nil,'rule priority is editable')

    local bumped=Model.bump(original,'safety.min_hp_pct',5)
    check(bumped~=nil and bumped.safety.min_hp_pct==original.safety.min_hp_pct+5,
        'bump increases a numeric field')
    check(original.safety.min_hp_pct==35,'bump never mutates the source policy')
    local clamped=Model.bump(original,'limits.max_actions_per_tick',99)
    check(clamped.limits.max_actions_per_tick==4,'bump clamps to the schema hard cap')
    local lowered=Model.bump(original,'rules.heal.priority',1)
    check(lowered.rules[1].priority==101,'bump edits the addressed rule by id')

    local toggled=Model.toggle(original,'rules.heal.enabled')
    check(toggled.rules[1].enabled==false,'toggle flips a rule off')
    check(original.rules[1].enabled==nil,'toggle never mutates the source policy')
    local back=Model.toggle(toggled,'rules.heal.enabled')
    check(back.rules[1].enabled==true,'toggle flips a rule back on')
    local safety=Model.toggle(original,'mode.on_new_enemy')
    check(safety.mode.on_new_enemy=='pause','toggle flips the new-enemy mode field (D-3)')
    check(safety.safety.pause_on_new_enemy==true,
        'toggling the new-enemy mode keeps the legacy safety boolean coherent')

    local _,err=Model.toggle(original,'safety.min_hp_pct')
    check(err and err.code=='not_boolean','toggling a numeric field is refused')
    local _,err2=Model.bump(original,'rules.heal.enabled',1)
    check(err2 and err2.code=='not_numeric','bumping a boolean field is refused')

    local Schema=require 'mod.auto_combat.PolicySchema'
    local Catalog=require 'mod.auto_combat.AutoCombatCatalog'
    check(Schema.validate(clamped)==true and Catalog.verify(clamped)==true,
        'an edited policy still validates and stays supported')
    check(Schema.hash(clamped)~=Schema.hash(original),'an edit changes the content hash')
end

print('Auto-combat editor model: '..checks..' checks passed')
