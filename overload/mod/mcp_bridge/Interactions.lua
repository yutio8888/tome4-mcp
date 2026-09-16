-- GPL-3.0-or-later. Typed native input providers; no talent-specific scripts.
local Json=require 'mod.mcp_bridge.Json'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Observer=require 'mod.mcp_bridge.Observer'
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Distance=require 'mod.mcp_bridge.Distance'
local M={MAX_RESPONSES=128,PAGE_SIZE=32}
local dialogs=setmetatable({}, {__mode='k'})
local targets=setmetatable({}, {__mode='k'})
local listener
local serial=0
local function nativeOwner()
    local owner=Tracker.current()
    if owner then return owner end
    local runtime=package.loaded['mod.mcp_bridge.Runtime']
    if type(runtime)=='table' and runtime.nativeUIOwner then return runtime.nativeUIOwner(game) end
end
local function integer(n,lo,hi) return type(n)=='number' and n%1==0 and n>=lo and n<=hi end
local function changed(root) if listener then listener(root) end end
local function liveDialog(g,d)
    for _,entry in ipairs(g.dialogs or {}) do if entry==d then return true end end
    return false
end
local function issue(h)
    local command=h.root.command
    command.interaction_sequence=(command.interaction_sequence or 0)+1
    h.sequence=command.interaction_sequence
    serial=serial+1
    h.interaction_id='interaction-'..serial
    h.consumed=false
    changed(h.root)
end
local function add(h)
    local root=h.owner.root
    h.root=root
    h.level=h.game.level
    root.interactions=root.interactions or {}
    root.interactions[#root.interactions+1]=h
    h.game.paused=true
    issue(h)
    return h
end
function M.reset(callback)
    dialogs=setmetatable({}, {__mode='k'});targets=setmetatable({}, {__mode='k'});listener=callback;serial=0
end

function M.openTarget(g,typ)
    local owner=Tracker.current()
    if not owner or not g.target_co then return end
    local target=g.target
    if not Compat.matches('setSpot',target.setSpot) then return end
    local origin=type(typ)=='table' and typ or {}
    local direction=origin.immediate_keys==true and origin.range==1
        and target.target and target.target.entity==g.player
        and Compat.matches('setDirFrom',target.setDirFrom)
    local h=add{owner=owner,game=g,target=target,co=g.target_co,
        kind=direction and 'target.direction' or 'target.grid',
        prompt=Details.text(origin.msg or origin.__name or type(origin.talent)=='table' and origin.talent.name,512)
            or 'Choose a target',
        origin={x=Details.number(origin.start_x) or g.player.x,y=Details.number(origin.start_y) or g.player.y},
        range=Details.number(origin.range),radius=Details.number(origin.radius),
        shape=Details.text(origin.type,32),selffire=origin.selffire==true or nil,
        direction_source=direction and g.player or nil}
    targets[g]=h
end
function M.closeTarget(g)
    local h=targets[g]
    if h then h.closed=true;targets[g]=nil;changed(h.root) end
end

-- Called inside audited native constructors, immediately before registration.
-- Button closures stay inside the game; clients receive only opaque option IDs.
function M.openDialog(d,kind,title,text,options,cancel,list)
    local owner=nativeOwner()
    if not owner then return end
    local h=add{owner=owner,game=owner.root.game,dialog=d,kind=kind,
        prompt=Details.text(title,512),text=Details.text(text,2048),
        options=options,cancel=cancel,list=list}
    dialogs[d]=h
end
function M.openInventory(d,class_name)
    local owner=nativeOwner()
    if not owner or not Compat.matches(class_name..'.init',d.init) then return end
    local list=d.c_inven and d.c_inven.c_inven
    if not list or type(list.list)~='table' then return end
    local h=add{owner=owner,game=owner.root.game,dialog=d,kind='inventory.select',
        prompt=Details.text(d.title,512) or 'Choose an inventory item',
        inventory={class_name=class_name,list=list,use=d.use},
        cancel=function() d.key:triggerVirtual('EXIT') end}
    dialogs[d]=h
end

local function chatCompatible(d)
    return (Compat.matches('Chat.init',d.init) or Compat.matches('TomeChat.init',d.init))
        and (Compat.matches('Chat.makeUI',d.makeUI) or Compat.matches('TomeChat.makeUI',d.makeUI))
        and Compat.matches('Chat.use',d.use) and Compat.matches('Chat.regen',d.regen)
        and Compat.matches('Chat.generateList',d.generateList) and Compat.matches('Chat.resolveAuto',d.resolveAuto)
        and d.chat and Compat.matches('Chat.get',d.chat.get)
end
function M.openChat(d)
    local owner=nativeOwner()
    if not owner or not chatCompatible(d) or d.player~=owner.root.player then return end
    local list=d.list
    local page=d.chat.chats and d.chat.chats[d.cur_id]
    if type(list)~='table' or #list>4096 or not d.c_list or d.c_list.list~=list
        or type(page)~='table' or type(page.answers)~='table' then return end
    if page.auto then
        M.adoptPassiveDialog(d,owner)
        dialogs[d].auto_chat=true
        return
    end
    local entries,rows={},{}
    for i,row in ipairs(list) do
        if type(row)~='table' or not integer(row.answer,-1,#page.answers) or row.answer==0 then return end
        local answer=page.answers[row.answer]
        if row.answer~=-1 and type(answer)~='table' then return end
        -- Audited generateList prefixes each row with one byte plus ") ".
        -- Beyond ASCII that shortcut byte is not valid UTF-8. Opaque option
        -- IDs replace keyboard shortcuts; retain the actual rendered answer.
        local label=type(row.name)=='string' and row.name:sub(4) or nil
        entries[i]={label=Details.text(label,512),disabled=row.disabled==true}
        rows[i]={row=row,name=row.name,disabled=row.disabled,index=row.answer,answer=answer,action=answer and answer.action,jump=answer and answer.jump,
            switch_npc=answer and answer.switch_npc,switch_npc_move_camera=answer and answer.switch_npc_move_camera}
    end
    local h=add{owner=owner,game=owner.root.game,dialog=d,kind='dialog.choice',prompt='Conversation',
        text=Details.text(d.text,2048),options=entries,
        chat={provider=d.chat,player=d.player,npc=d.npc,id=d.cur_id,page=page,answers=page.answers,list=list,widget=d.c_list,rows=rows,use=d.use}}
    dialogs[d]=h
end

function M.noticeText(d)
    local parts={}
    for i,entry in ipairs(d.uis or {}) do
        if i>32 then break end
        local text=entry.ui and Details.text(entry.ui.text,2048)
        if text then parts[#parts+1]=text end
    end
    return Details.text(table.concat(parts,'\n'),2048)
end
function M.openNotice(d,source,title,text)
    local key=d.key
    local close=key and key.virtuals and key.virtuals.EXIT
    if type(close)~='function' then return end
    M.openDialog(d,'dialog.notice',title and title~='' and title or source,text,{{label='Close',apply=close}},close)
    local h=dialogs[d]
    if h then h.notice={source=source,key=key,close=close} end
end
function M.dialogOwner(d) local h=dialogs[d];return h and not h.closed and h.root end
function M.adoptPassiveDialog(d,owner,task)
    local h={owner=owner,root=owner.root,dialog=d,game=owner.root.game,passive=true,task=task}
    dialogs[d]=h
    owner.root.passive_dialogs=owner.root.passive_dialogs or {}
    owner.root.passive_dialogs[#owner.root.passive_dialogs+1]=d
    changed(owner.root)
end
function M.claimSceneWaiter(d)
    local owner=Tracker.current()
    local root=owner and owner.root
    if root and root.transitioning and root.player==root.game.player and not root.error
        and root.command.input_owner~='manual' and not root.command.handoff_requested then
        M.adoptPassiveDialog(d,owner)
    end
end
function M.closeDialog(d)
    local h=dialogs[d]
    if h then h.closed=true;dialogs[d]=nil;changed(h.root) end
end

function M.exposeTop(root)
    local h=M.current(root)
    if not h then return end
    if h.sequence<(root.last_exposed_sequence or 0) then issue(h) end
    root.last_exposed_sequence=h.sequence
end

function M.valid(h)
    local g,root=h.game,h.root
    if h.closed or g.player~=root.player or g.level~=root.level or h.level and h.level~=g.level then return false end
    if h.chat then
        local d,c=h.dialog,h.chat
        if not chatCompatible(d) or d.chat~=c.provider or d.player~=c.player or d.npc~=c.npc or d.cur_id~=c.id or d.list~=c.list
            or d.c_list~=c.widget or d.c_list.list~=c.list or #c.list~=#c.rows
            or d.chat.chats[c.id]~=c.page or c.page.answers~=c.answers then return false end
        for i,entry in ipairs(c.rows) do
            local a=entry.answer
            if c.list[i]~=entry.row or entry.row.answer~=entry.index or entry.row.name~=entry.name
                or entry.row.disabled~=entry.disabled or c.answers[entry.index]~=a
                or a and (a.action~=entry.action or a.jump~=entry.jump or a.switch_npc~=entry.switch_npc
                    or a.switch_npc_move_camera~=entry.switch_npc_move_camera) then return false end
        end
    end
    if h.notice and (h.dialog.key~=h.notice.key or h.notice.key.virtuals.EXIT~=h.notice.close) then return false end
    if h.target then
        return g.target==h.target and g.target_co==h.co and g.target.active
            and Compat.matches('targetMode',g.targetMode) and Compat.matches('setSpot',g.target.setSpot)
    end
    return h.dialog and liveDialog(g,h.dialog) or false
end
function M.hasAutoDialog(root)
    for _,d in ipairs(root.passive_dialogs or {}) do
        local h=dialogs[d]
        if h and h.auto_chat and not h.closed and liveDialog(root.game,d) then return true end
    end
    return false
end

function M.current(root)
    if not root then return end
    local stack=root.game and root.game.dialogs or {}
    if #stack>0 then
        local h=dialogs[stack[#stack]]
        if h and h.root==root and not h.passive and M.valid(h) then return h end
        return
    end
    local handles=root and root.interactions or {}
    for i=#handles,1,-1 do
        local h=handles[i]
        if M.valid(h) then return h end
    end
end

function M.ownsAll(g,root)
    if g.target and g.target.active then
        local h=targets[g]
        if not h or h.root~=root or not M.valid(h) then return false end
    elseif g.target_co then
        -- Native targetMode closes targeting before its self-target warning,
        -- retaining target_co until that dialog's real callback answers it.
        local owner=Tracker.forCoroutine(g.target_co)
        local owned_dialog=false
        for _,d in ipairs(g.dialogs or {}) do
            local h=dialogs[d]
            if h and h.root==root and not h.closed then owned_dialog=true end
        end
        if not owner or owner.root~=root or not owned_dialog then return false end
    end
    for _,d in ipairs(g.dialogs or {}) do
        local h=dialogs[d]
        if not h or h.root~=root or h.closed then return false end
    end
    return true
end

local function options(h)
    if h.inventory then return h.inventory.list.list or {} end
    if h.list then return h.list.list or {} end
    return h.options or {}
end

function M.describe(root,meta,offset)
    local h=M.current(root)
    if not h then return nil end
    local result={interaction_id=h.interaction_id,sequence=h.sequence,kind=h.kind,
        revision=meta.revision,prompt=h.prompt,text=h.text,answer_types=Json.array(),
        consumed=h.consumed or false}
    if h.notice then result.native_ui=h.notice.source end
    if h.chat then result.native_ui='Chat' end
    if h.target then
        result.origin=h.origin;result.range=h.range;result.radius=h.radius
        result.shape=h.shape;result.selffire=h.selffire
        if h.kind=='target.direction' then result.answer_types=Json.array{'direction','cancel'}
        else
            result.answer_types=Json.array{'actor','position','cancel'}
            result.candidate_actor_ids=Json.array{Observer.actorId(meta,h.game.player)}
            for _,actor in pairs(h.game.level.entities or {}) do
                if actor~=h.game.player and actor.__is_actor and Observer.visible(h.game,actor) then
                    result.candidate_actor_ids[#result.candidate_actor_ids+1]=Observer.actorId(meta,actor)
                    if #result.candidate_actor_ids>32 then
                        table.sort(result.candidate_actor_ids)
                        result.candidate_actor_ids[#result.candidate_actor_ids]=nil
                        result.candidates_truncated=true
                    end
                end
            end
            table.sort(result.candidate_actor_ids)
        end
    else
        result.answer_types=Json.array{'option'}
        if h.cancel then result.answer_types[#result.answer_types+1]='cancel' end
        local entries=options(h)
        offset=offset or 0
        result.options=Json.array();result.options_offset=offset;result.options_total=#entries
        for i=offset+1,math.min(#entries,offset+M.PAGE_SIZE) do
            local o=entries[i]
            local label=type(o)=='table' and (Details.text(o.label,512) or Details.text(o.name,512)
                or Details.text(o.sortname,512))
            result.options[#result.options+1]={option_id=h.interaction_id..':option-'..i,
                label=label or 'Option '..i,
                disabled=type(o)~='table' or o.disabled==true or h.inventory~=nil and not o.object}
        end
        if offset+M.PAGE_SIZE<#entries then result.options_next=offset+M.PAGE_SIZE end
    end
    return result
end

function M.validateAnswer(answer)
    if type(answer)~='table' or answer==Json.null then return nil,'invalid_answer' end
    local a,allowed={type=answer.type},{type=true}
    if a.type=='actor' then
        if type(answer.target_id)~='string' or #answer.target_id==0 or #answer.target_id>256 then return nil,'invalid_target' end
        a.target_id=answer.target_id;allowed.target_id=true
    elseif a.type=='position' then
        if not integer(answer.x,0,2147483647) or not integer(answer.y,0,2147483647) then return nil,'invalid_position' end
        a.x=answer.x;a.y=answer.y;allowed.x=true;allowed.y=true
    elseif a.type=='direction' then
        if not integer(answer.direction,1,9) or answer.direction==5 then return nil,'invalid_direction' end
        a.direction=answer.direction;allowed.direction=true
    elseif a.type=='option' then
        if type(answer.option_id)~='string' or #answer.option_id==0 or #answer.option_id>512 then return nil,'invalid_option' end
        a.option_id=answer.option_id;allowed.option_id=true
    elseif a.type~='cancel' then return nil,'unsupported_answer' end
    for key in pairs(answer) do if not allowed[key] then return nil,'unexpected_answer_field' end end
    return a
end

function M.prepare(h,answer,meta)
    if not M.valid(h) then return nil,'interaction_expired' end
    if h.target then
        if answer.type=='cancel' then return {type='cancel'} end
        if h.kind=='target.direction' then
            if answer.type~='direction' or h.direction_source~=h.game.player
                or not Compat.matches('setDirFrom',h.target.setDirFrom) then return nil,'answer_type_mismatch' end
            return answer
        end
        local x,y=answer.x,answer.y
        if answer.type=='actor' then
            local actor=Observer.resolve(h.game,meta,answer.target_id)
            if not actor then return nil,'target_lost' end
            x,y=actor.x,actor.y
        elseif answer.type~='position' then return nil,'answer_type_mismatch' end
        local map=h.game.level.map
        if not integer(x,0,map.w-1) or not integer(y,0,map.h-1) then return nil,'position_out_of_bounds' end
        -- Native targeting limits the cursor to the talent range; enforce the
        -- same bound for programmatic answers instead of bypassing it. Measure
        -- from the native origin, which is not always the player.
        if type(h.range)=='number' and h.range==h.range and h.range>=0 then
            local p=h.game.player
            local ox,oy=(h.origin and h.origin.x) or p.x,(h.origin and h.origin.y) or p.y
            local dist=Distance.grid(ox,oy,x,y)
            if dist>h.range then return nil,'position_out_of_range' end
        end
        return {type='position',x=x,y=y}
    end
    if answer.type=='cancel' and h.cancel then return answer end
    if answer.type~='option' then return nil,'answer_type_mismatch' end
    for i,o in ipairs(options(h)) do
        if answer.option_id==h.interaction_id..':option-'..i then
            if type(o)~='table' or o.disabled==true then return nil,'option_disabled' end
            if h.inventory then
                if not Compat.matches(h.inventory.class_name..'.use',h.dialog.use) or not o.object then
                    return nil,'option_expired'
                end
                local container=h.dialog.inven
                if h.inventory.class_name=='ShowEquipInven' then
                    container=h.dialog.inven_actor and h.dialog.inven_actor.inven
                        and h.dialog.inven_actor.inven[o.inven]
                end
                if not container or container[o.item]~=o.object then return nil,'option_expired' end
            end
            return {type='option',index=i,option=o}
        end
    end
    return nil,'option_expired'
end

function M.apply(h,prepared)
    return Tracker.scope(h.owner,function()
        if h.target then
            if prepared.type=='cancel' then
                h.target.target.x,h.target.target.y,h.target.target.entity=nil,nil,nil
            elseif prepared.type=='direction' then
                h.target:setDirFrom(prepared.direction,h.direction_source)
            else h.target:setSpot(prepared.x,prepared.y,'mouse') end
            h.game:targetMode(false,false)
            h.game.tooltip_x,h.game.tooltip_y=nil,nil
        elseif prepared.type=='cancel' then h.cancel()
        elseif h.inventory then h.inventory.use(h.dialog,prepared.option,'left','button')
        elseif h.chat then h.chat.use(h.dialog,h.chat.rows[prepared.index].row)
        elseif h.list then
            h.list.sel=prepared.index
            h.list:onSelect()
            h.dialog.key:triggerVirtual('ACCEPT')
        else prepared.option.apply() end
        -- Native options can keep a dialog open; ask again with a fresh ID.
        if M.valid(h) then issue(h) end
    end)
end

function M.reissue(h) if M.valid(h) then issue(h) end end
function M.release(root)
    for _,h in ipairs(root.interactions or {}) do
        if h.dialog then dialogs[h.dialog]=nil end
        if h.target and targets[h.game]==h then targets[h.game]=nil end
    end
    for _,d in ipairs(root.passive_dialogs or {}) do dialogs[d]=nil end
    root.passive_dialogs=nil
    root.interactions=nil
end
return M
