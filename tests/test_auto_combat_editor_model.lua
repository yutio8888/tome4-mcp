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

print('Auto-combat editor model: '..checks..' checks passed')
