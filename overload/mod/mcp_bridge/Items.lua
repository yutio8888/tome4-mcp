-- GPL-3.0-or-later. Explicit item operations through native inventory paths.
-- Observation reads existing fields only; execution retains native callbacks.
local Json=require 'mod.mcp_bridge.Json'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local M={LIMIT=32,PILE_LIMIT=128}
local kinds={pickup=true,equip=true,unequip=true,use_item=true}
local equipment_slots={MAINHAND=true,OFFHAND=true,BODY=true,HEAD=true,HANDS=true,FEET=true,
    CLOAK=true,BELT=true,NECK=true,LITE=true,RING=true,TOOL=true}
local function integer(n,lo,hi) return Details.finite(n) and n%1==0 and n>=lo and n<=hi end
local function stringId(v) return type(v)=='string' and #v>0 and #v<=256 and not v:find('%z') end
local function active(v) return v~=nil and v~=false and v~=0 end
function M.isAction(kind) return kinds[kind]==true end
function M.validate(action)
    if type(action)~='table' or not M.isAction(action.type) then return nil,'unsupported_action' end
    if not stringId(action.item_id) then return nil,'invalid_item_id' end
    for key in pairs(action) do if key~='type' and key~='item_id' then return nil,'unexpected_action_field' end end
    return {type=action.type,item_id=action.item_id}
end
local function context(g)
    local p,map=g.player,g.level and g.level.map
    if not p or not map or type(map.map)~='table' or not integer(map.w,1,100000)
        or not integer(map.h,1,100000) or not integer(p.x,0,map.w-1) or not integer(p.y,0,map.h-1) then return end
    return p,map
end
local function visibleCell(p,map,x,y)
    if active(p.blind) then return false end
    local index=x+y*map.w
    if not map.seens or not map.seens[index] or not map.infovs or not map.infovs[index] then return false end
    local cell=map.map[index]
    if type(cell)~='table' then return false end
    local actor=cell[map.ACTOR or 3]
    -- ESP on an actor does not grant knowledge of objects under it. Match the
    -- conservative terrain observation rule when a different actor occupies it.
    return not actor or actor==p or map.lites and map.lites[index] and true or false
end
local function visibleObject(obj)
    return type(obj)=='table' and not obj.hidden and not obj.hide and not active(obj.invisible)
end
local function groundId(meta,obj,x,y)
    local owned=Details.objectId(meta,obj)
    if not owned then return end
    return meta.session_id..':'..meta.level_instance_id..':ground-'..x..','..y..':'..owned:sub(#meta.session_id+2)
end
local function floorCount(cell,base)
    local count=0
    while count<M.PILE_LIMIT and cell[base+count] do count=count+1 end
    return count,cell[base+count]~=nil
end
local function groundSummary(g,meta,p,obj,x,y,pile_size,pile_truncated)
    local result=Details.item(g,obj,meta)
    result.id=groundId(meta,obj,x,y)
    result.location='ground';result.x=x;result.y=y
    result.underfoot=x==p.x and y==p.y
    result.pile_size=pile_size;result.pile_truncated=pile_truncated
    return result
end
function M.ground(g,meta,radius)
    radius=Details.finite(radius) and math.max(0,math.min(12,math.floor(radius))) or 8
    local result={items=Json.array(),truncated=false,radius=radius,pickup_scope='current_tile_only',
        scope='current visible objects; distant piles reveal their top object and count; underfoot piles reveal their pickup list'}
    local p,map=context(g)
    if not p then return result end
    local base=map.OBJECT or 1000
    -- Keep underfoot and nearest objects first within the bounded response.
    for distance=0,radius do
        for y=math.max(0,p.y-distance),math.min(map.h-1,p.y+distance) do
            for x=math.max(0,p.x-distance),math.min(map.w-1,p.x+distance) do
                if math.max(math.abs(x-p.x),math.abs(y-p.y))==distance and visibleCell(p,map,x,y) then
                    local cell=map.map[x+y*map.w]
                    local count,pile_truncated=floorCount(cell,base)
                    local limit=x==p.x and y==p.y and count or math.min(count,1)
                    for i=1,limit do
                        local obj=cell[base+i-1]
                        if visibleObject(obj) then
                            if #result.items>=M.LIMIT then result.truncated=true;return result end
                            result.items[#result.items+1]=groundSummary(g,meta,p,obj,x,y,count,pile_truncated)
                        end
                    end
                    if pile_truncated then result.truncated=true end
                end
            end
        end
    end
    return result
end
local function owned(g,meta,id,by_object)
    local p=g.player
    if not p or type(p.inven)~='table' then return end
    local found
    for inven_id,inven in pairs(p.inven) do
        if integer(inven_id,1,100000) and type(inven)=='table' then
            local def=p.inven_def and p.inven_def[inven_id] or {}
            for slot,obj in ipairs(inven) do
                if type(obj)=='table' and (by_object and obj==by_object or not by_object and Details.objectId(meta,obj)==id) then
                    if found then return nil,'ambiguous_item_id' end
                    found={obj=obj,inven=inven,inven_id=inven_id,slot=slot,
                        equipped=inven.worn==true or def.is_worn==true,def=def}
                end
            end
        end
    end
    return found
end
local function floor(g,meta,id)
    local p,map=context(g)
    if not p or not stringId(id) then return end
    local prefix=meta.session_id..':'..meta.level_instance_id..':ground-'
    if id:sub(1,#prefix)~=prefix then return end
    local xs,ys=id:sub(#prefix+1):match('^(%d+),(%d+):object%-[^%z]+$')
    local x,y=tonumber(xs),tonumber(ys)
    if not integer(x,0,map.w-1) or not integer(y,0,map.h-1) or not visibleCell(p,map,x,y) then return end
    local cell=map.map[x+y*map.w]
    local base=map.OBJECT or 1000
    local count,pile_truncated=floorCount(cell,base)
    local limit=x==p.x and y==p.y and count or math.min(count,1)
    local found
    for i=1,limit do
        local obj=cell[base+i-1]
        if visibleObject(obj) and groundId(meta,obj,x,y)==id then
            if found then return nil,'ambiguous_item_id' end
            found={obj=obj,x=x,y=y,slot=i,count=count,pile_truncated=pile_truncated}
        end
    end
    return found
end
function M.inspect(g,meta,id)
    if not stringId(id) then return nil,'invalid_item_id' end
    local carried,code=owned(g,meta,id)
    if carried then
        local result=Details.item(g,carried.obj,meta)
        result.location=carried.equipped and 'equipped' or 'inventory'
        result.inventory_id=carried.inven_id;result.slot=carried.slot;result.equipped=carried.equipped
        result.container=Details.text(carried.inven.short_name or carried.def.short_name,48)
        result.transmogrification_pending=carried.obj.__transmo and true or false
        return result
    elseif code then return nil,code end
    local on_floor,reason=floor(g,meta,id)
    if on_floor then
        return groundSummary(g,meta,g.player,on_floor.obj,on_floor.x,on_floor.y,on_floor.count,on_floor.pile_truncated)
    end
    return nil,reason or 'item_not_visible_or_owned'
end
local function busy(g)
    return g.target_co or g.target and g.target.active or g.dialogs and #g.dialogs>0
end
local function audit(p,kind)
    local methods={getInven='/engine/interface/ActorInventory.lua',addObject='/engine/interface/ActorInventory.lua',
        removeObject='/engine/interface/ActorInventory.lua',attr='/engine/Entity.lua'}
    if kind=='pickup' then
        methods.pickupFloor='/engine/interface/ActorInventory.lua';methods.playerPickup='/mod/class/Player.lua'
    elseif kind=='equip' then
        methods.doWear='/mod/class/Actor.lua';methods.wearObject='/engine/interface/ActorInventory.lua'
        methods.canWearObject='/mod/class/Actor.lua';methods.takeoffObject='/engine/interface/ActorInventory.lua'
    elseif kind=='unequip' then methods.doTakeoff='/mod/class/Actor.lua';methods.takeoffObject='/engine/interface/ActorInventory.lua' end
    for method,source in pairs(methods) do if not Details.native(p[method],source) then return false end end
    return true
end
local function complexTransfer(obj)
    -- Native doWear removes the source before attempting the destination. Its
    -- transfer is not adapted for removal/addition vetoes, attached tinkers or
    -- equipment stacks; retain these native interactions for manual control.
    return obj.is_tinker or obj.tinker or obj.tinkered or obj.on_preremoveobject or obj.on_preaddobject
        or type(obj.stacked)=='table' and #obj.stacked>0
end
local function failure(code) return {ok=false,code=code,energy_spent=0} end
function M.execute(g,action,meta)
    local a,invalid=M.validate(action)
    if not a then return failure(invalid) end
    local p,map=context(g)
    if not p or type(p.energy)~='table' or not Details.finite(p.energy.value) or not meta then return failure('player_unavailable') end
    if busy(g) then return failure('player_busy') end
    if p.no_inventory_access then return failure('inventory_unavailable') end
    if not audit(p,a.type) then return failure('item_operation_modified') end
    local record,code
    if a.type=='pickup' then
        record,code=floor(g,meta,a.item_id)
        if not record then return failure(code or 'item_not_visible_or_owned') end
        if record.x~=p.x or record.y~=p.y then return failure('item_not_underfoot') end
    else
        record,code=owned(g,meta,a.item_id)
        if not record then return failure(code or 'item_not_owned') end
        if a.type=='equip' and record.inven_id~=p.INVEN_INVEN then return failure('item_not_in_backpack') end
        if a.type=='unequip' and not record.equipped then return failure('item_not_equipped') end
        if a.type~='use_item' and complexTransfer(record.obj) then return failure('unsupported_item_transfer') end
        if a.type=='equip' then
            if not equipment_slots[record.obj.slot] or not Details.native(record.obj.wornInven,'/engine/Object.lua') then
                return failure('unsupported_equipment_slot')
            end
            -- Replacement may remove another worn object. Do not enter a
            -- complex transfer implicitly through an otherwise ordinary item.
            for _,inven in pairs(p.inven or {}) do
                if type(inven)=='table' and inven.worn then
                    for _,obj in ipairs(inven) do
                        if type(obj)=='table' and complexTransfer(obj) then return failure('unsupported_item_transfer') end
                    end
                end
            end
        end
    end
    if a.type=='use_item' then
        if not Tracker.current() then return failure('interactive_required') end
        local compatible,reason=Compat.check(g)
        if not compatible then return failure(reason) end
        if not Compat.matches('playerUseItem',p.playerUseItem) or not Compat.matches('playerUseObject',p.playerUseObject) then
            return failure('item_lifecycle_unavailable')
        end
        for _,name in ipairs{'use','useObject','canUseObject'} do
            if not Compat.matches('object.'..name,record.obj[name]) then return failure('item_entrypoint_modified') end
        end
        if not g.zone or g.zone.wilderness then return failure('item_use_unavailable_in_wilderness') end
        -- The native Object:canUseObject and power callback decide wear,
        -- blindness, silence, charges, resources, cooldown and cancellation.
        local owner=Tracker.current()
        owner.root.result_from_talent=true
    end
    local before=p.energy.value
    local ok,ret=pcall(function()
        if a.type=='pickup' then
            -- Exact native Player:playerPickup branches, with the requested
            -- item replacing only the floor-dialog selection. That dialog's
            -- multi-object branch spends no energy; the single-object branch
            -- spends a turn only when pickupFloor returns an object.
            if p:attr('sleep') and not p:attr('lucid_dreamer') then return false end
            local multiple=map.map[p.x+p.y*map.w][(map.OBJECT or 1000)+1]~=nil
            local item=p:pickupFloor(record.slot,true)
            if type(item)=='table' then
                if not multiple then p:useEnergy() end
                item.__new_pickup=true
            end
            p.changed=true
            return item
        elseif a.type=='use_item' then return p:playerUseItem(record.obj,record.slot,record.inven_id)
        elseif a.type=='equip' then return p:doWear(record.inven_id,record.slot,record.obj)
        else return p:doTakeoff(record.inven_id,record.slot,record.obj) end
    end)
    local remaining=type(p.energy)=='table' and Details.number(p.energy.value)
    local result={energy_spent=remaining and math.max(0,before-remaining) or 0}
    if not remaining then
        result.ok=false;result.code='execution_error';result.uncertain=true
        result.native_message='Native item operation left player energy unavailable.'
        return result
    end
    if not ok then
        result.ok=false;result.code='execution_error';result.uncertain=true
        result.native_message=Details.text(tostring(ret),512)
        return result
    end
    if type(ret)=='boolean' then result.native_return=ret end
    if a.type=='use_item' then result.ok=ret==true
    elseif a.type=='pickup' then result.ok=ret~=nil and ret~=false
    else
        local after=owned(g,meta,nil,record.obj)
        result.ok=after and (a.type=='equip' and after.equipped or a.type=='unequip' and after.inven_id==p.INVEN_INVEN) and true or false
    end
    result.code=result.ok and 'item_action_complete' or 'native_rejected'
    return result
end
return M
