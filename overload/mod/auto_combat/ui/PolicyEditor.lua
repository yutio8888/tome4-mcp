-- GPL-3.0-or-later. In-game auto-combat policy editor.
--
-- This is the standalone (no MCP client) entry point: pick a preset, edit the
-- data, save it as a draft, approve, activate, start and stop. It is a thin
-- renderer: all availability rules and all mutations live in the pure
-- PolicyEditorModel, and all engine work goes through the Runtime auto-combat
-- accessors (which also hold the explicit local execution authorization).
local Runtime=require 'mod.mcp_bridge.Runtime'
local Model=require 'mod.auto_combat.PolicyEditorModel'
local M={}

local function tr(text) return _t and _t(text) or text end

local function presetNames()
    local result=Runtime.autoCombatHandle(game,'presets',{})
    if result and result.ok and result.names then return result.names end
    return {}
end

-- A human-readable description of one rule for the details pane.
local function describeField(field)
    if field.kind=='boolean' then
        return tr('Click to toggle.')..' '..(field.value and tr('Currently on.') or tr('Currently off.'))
    end
    return tr('Left click increases, right click decreases.')..' '
        ..string.format(tr('Range %s to %s.'),tostring(field.min),tostring(field.max))
end

function M.open(player)
    local d=require('engine.ui.Dialog').new(tr('Auto-combat policy'),math.floor(math.min(920,game.w*0.95)),
        math.floor(math.min(720,game.h*0.95)))
    local Textzone=require('engine.ui.Textzone').new
    local ListColumns=require('engine.ui.ListColumns').new
    local Button=require('engine.ui.Button').new
    local Checkbox=require('engine.ui.Checkbox').new
    local font_h=d.font_h or 18
    local row=font_h+6

    local svc=Runtime.autoCombatService(game)
    local working=Model.clone(svc and (svc.store.draft or svc.store.approved) or nil)
    if not working then
        local preset=Runtime.autoCombatHandle(game,'preset',{name='anorithil_p1a'})
        working=preset and preset.ok and preset.policy or nil
    end
    if not working then
        -- No policy at all: the editor is read-only until a preset loads.
        game.log('#LIGHT_RED#Auto-combat: no policy available and the built-in preset is missing.#LAST#')
        return
    end
    local selected
    local message=''

    local function status() return Runtime.autoCombatStatus(game) or {} end
    local function apply(op,args)
        local result=Runtime.autoCombatHandle(game,op,args or {})
        if result and result.ok then
            message=''
        elseif result and result.error then
            message=tr('Error: ')..tostring(result.error.code or result.error.details or result.error)
        end
        d:refresh()
    end

    local function saveDraft()
        apply('set_draft',{policy=working,expected_hash=status().draft_hash})
    end

    d.c_status=Textzone{width=d.iw,height=font_h*4,text='',scrollbar=true,can_focus=false}
    d.c_fields=ListColumns{width=d.iw,height=row*10,list={},scrollbar=true,all_clicks=true,columns={
        {name=tr('Group'),width=14,display_prop='group'},
        {name=tr('Setting'),width=44,display_prop='label'},
        {name=tr('Value'),width=12,display_prop='value'},
        {name=tr('Action'),width=30,display_prop='action'},
    },fct=function(item,sel,button)
        if not item then return end
        local field
        for _,candidate in ipairs(Model.fields(working)) do
            if candidate.id==item.id then field=candidate break end
        end
        if not field then return end
        if field.kind=='boolean' then
            local updated,err=Model.toggle(working,item.id)
            if updated then working=updated else message=tr('Error: ')..tostring(err.code) end
        else
            local delta=button=='right' and -1 or 1
            local updated,err=Model.bump(working,item.id,delta)
            if updated then working=updated else message=tr('Error: ')..tostring(err.code) end
        end
        d:refresh()
    end,select=function(item)
        selected=item
        if item then
            local field
            for _,candidate in ipairs(Model.fields(working)) do
                if candidate.id==item.id then field=candidate break end
            end
            d.c_detail.text=field and describeField(field) or ''
        else
            d.c_detail.text=''
        end
        d.c_detail:generate()
    end}
    d.c_detail=Textzone{width=d.iw,height=row*2,text='',can_focus=false}
    d.c_log=Textzone{width=d.iw,height=row*5,text='',scrollbar=true,can_focus=false}

    d.c_preset=Button{text=tr('Load preset'),width=130,fct=function()
        local names=presetNames()
        if #names==0 then message=tr('No presets available');d:refresh();return end
        if #names==1 then
            local preset=Runtime.autoCombatHandle(game,'preset',{name=names[1]})
            if preset and preset.ok then working=Model.clone(preset.policy) end
            saveDraft()
        else
            local items={}
            for _,name in ipairs(names) do items[#items+1]={name=name} end
            require('engine.ui.Dialog'):listPopup(tr('Choose a preset'),tr('Load'),
                items,400,300,function(item)
                    if not item then return end
                    local preset=Runtime.autoCombatHandle(game,'preset',{name=item.name})
                    if preset and preset.ok then working=Model.clone(preset.policy) end
                    saveDraft()
                end)
        end
    end}
    d.c_save=Button{text=tr('Save draft'),width=110,fct=saveDraft}
    d.c_approve=Button{text=tr('Approve'),width=110,fct=function()
        apply('approve',{expected_hash=status().draft_hash})
    end}
    d.c_activate=Button{text=tr('Activate'),width=110,fct=function()
        apply('activate',{expected_hash=status().approved_hash})
    end}
    d.c_deactivate=Button{text=tr('Deactivate'),width=110,fct=function()
        apply('deactivate')
    end}
    d.c_start=Button{text=tr('Start'),width=110,fct=function()
        apply('start')
    end}
    d.c_stop=Button{text=tr('Stop'),width=110,fct=function()
        apply('stop')
    end}
    d.c_pause=Button{text=tr('Pause'),width=110,fct=function()
        apply('pause')
    end}
    d.c_resume=Button{text=tr('Resume'),width=110,fct=function()
        apply('resume')
    end}
    d.c_export=Button{text=tr('Export JSON'),width=130,fct=function()
        local result=Runtime.autoCombatHandle(game,'export',{})
        if result and result.ok then
            require('engine.ui.Dialog'):simplePopup(tr('Auto-combat policy JSON'),result.document)
        else
            message=tr('Error: ')..tostring(result and result.error and result.error.code)
            d:refresh()
        end
    end}
    d.c_exec=Checkbox{title=tr('Enable live execution (local)'),default=false,fct=function() end,
        on_change=function(value)
            Runtime.setAutoCombatExecution(game,value and true or false)
            d:refresh()
        end}
    d.c_close=Button{text=tr('Close'),width=110,fct=function() game:unregisterDialog(d) end}

    function d:refresh()
        local st=status()
        local lines=Model.lines(st)
        lines[#lines+1]='Live execution: '..(Runtime.autoCombatExecutionEnabled(game) and 'enabled' or 'disabled')
        if message~='' then lines[#lines+1]='#LIGHT_RED#'..message..'#LAST#' end
        d.c_status.text=table.concat(lines,'\n')
        d.c_status:generate()
        local rows={}
        for _,field in ipairs(Model.fields(working)) do
            local value
            if type(field.value)=='boolean' then value=field.value and '[x]' or '[ ]'
            else value=field.value==nil and '-' or tostring(field.value) end
            local action
            if field.kind=='boolean' then action=tr('toggle')
            elseif field.kind=='integer' or field.kind=='number' then action=tr('left +1 / right -1')
            else action='' end
            rows[#rows+1]={id=field.id,group=field.group,label=field.label,value=value,action=action}
        end
        d.c_fields:setList(rows)
        d.c_exec.checked=Runtime.autoCombatExecutionEnabled(game) and true or false
        local log=Runtime.autoCombatHandle(game,'log',{limit=8})
        if log and log.ok and log.events then
            local out={}
            for _,event in ipairs(log.events) do
                out[#out+1]=tostring(event.kind)..(event.reason and (' / '..tostring(event.reason)) or '')
                    ..(event.rule and (' / '..tostring(event.rule)) or '')
                    ..(event.talent and (' / '..tostring(event.talent)) or '')
            end
            d.c_log.text=tr('Recent decisions:')..'\n'..table.concat(out,'\n')
            d.c_log:generate()
        end
    end

    local top=d.c_status.h+d.c_detail.h+16
    local fields_height=math.max(row*4,d.ih-top-d.c_log.h-d.c_close.h-24)
    d.c_fields.height=fields_height
    d:refresh()
    d:loadUI{
        {left=0,top=0,ui=d.c_status},
        {left=0,top=d.c_status.h+8,ui=d.c_preset},
        {left=d.c_preset,top=d.c_status.h+8,ui=d.c_save},
        {left=d.c_save,top=d.c_status.h+8,ui=d.c_approve},
        {left=d.c_approve,top=d.c_status.h+8,ui=d.c_activate},
        {left=d.c_activate,top=d.c_status.h+8,ui=d.c_deactivate},
        {left=d.c_deactivate,top=d.c_status.h+8,ui=d.c_export},
        {left=0,top=top,ui=d.c_fields},
        {left=0,top=top+fields_height+6,ui=d.c_detail},
        {left=0,bottom=d.c_close.h+4,ui=d.c_exec},
        {right=0,bottom=d.c_close.h+4,ui=d.c_start},
        {right=d.c_start,bottom=d.c_close.h+4,ui=d.c_stop},
        {right=d.c_stop,bottom=d.c_close.h+4,ui=d.c_pause},
        {right=d.c_pause,bottom=d.c_close.h+4,ui=d.c_resume},
        {left=0,bottom=0,ui=d.c_log},
        {right=0,bottom=0,ui=d.c_close},
    }
    d:setFocus(d.c_fields)
    d:setupUI()
    d.key:addBinds{EXIT=function() game:unregisterDialog(d) end}
    game:registerDialog(d)
    return d
end
return M
