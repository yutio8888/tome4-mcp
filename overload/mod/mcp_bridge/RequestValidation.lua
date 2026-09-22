-- GPL-3.0-or-later. Public v4 ingress, before authentication/control mutation.
-- RequestSchema is generated from protocol/v4; game-internal action carriers
-- bypass this boundary and retain their own executor validation.
local Json=require 'mod.mcp_bridge.Json'
local Schema=require 'mod.mcp_bridge.RequestSchema'
local Actions=require 'mod.mcp_bridge.Actions'
local M={}
local function finite(v) return type(v)=='number' and v==v and v>-math.huge and v<math.huge end
local function object(v)
    if type(v)~='table' or v==Json.null or Json.isArrayMarked(v) then return false end
    for key in pairs(v) do if type(key)~='string' then return false end end
    return true
end
local function matchesType(kind,value)
    if kind=='null' then return value==Json.null end
    if kind=='object' then return object(value) end
    if kind=='array' then return type(value)=='table' and value~=Json.null end
    if kind=='integer' then return finite(value) and value%1==0 end
    if kind=='number' then return finite(value) end
    return type(value)==kind
end
local function validateValue(schema,value,path)
    if schema.type then
        local accepted=false
        if type(schema.type)=='table' then
            for _,kind in ipairs(schema.type) do if matchesType(kind,value) then accepted=true end end
        else accepted=matchesType(schema.type,value) end
        if not accepted then return false,path end
    end
    if schema.const~=nil and value~=schema.const then return false,path end
    if schema.enum then
        local found=false
        for _,entry in ipairs(schema.enum) do if value==entry then found=true end end
        if not found then return false,path end
    end
    for _,union in ipairs{'oneOf','anyOf'} do
        if schema[union] then
            local matches=0
            for _,branch in ipairs(schema[union]) do
                if validateValue(branch,value,path) then matches=matches+1 end
            end
            if matches==0 or (union=='oneOf' and matches~=1) then return false,path end
        end
    end
    if schema['not'] and validateValue(schema['not'],value,path) then return false,path end
    if type(value)=='string' then
        -- The decoder guarantees UTF-8, but direct Lua callers must too.
        if not Json.utf8Valid(value) then return false,path end
        local _,characters=value:gsub('[^\128-\191]','')
        if schema.minLength and characters<schema.minLength then return false,path end
        if schema.maxLength and characters>schema.maxLength then return false,path end
        if schema['x-max-utf8-bytes'] and #value>schema['x-max-utf8-bytes'] then return false,path end
        if schema.pattern and not value:match(schema.pattern) then return false,path end
        if schema['x-max-sequence'] then
            local seq=tonumber(value:sub(5))
            if not seq or seq>schema['x-max-sequence'] then return false,path end
        end
    elseif finite(value) then
        if schema.minimum and value<schema.minimum then return false,path end
        if schema.maximum and value>schema.maximum then return false,path end
    end
    if schema.type=='array' then
        -- Do not inspect length/iterate caller entries until every key passed
        -- the shared dense + closed gate. In particular JSON {} is NOT [].
        local dense,length=Json.denseArray(value)
        if not dense then return false,path end
        if length==0 and not Json.isArrayMarked(value) then return false,path end
        if schema.minItems and length<schema.minItems then return false,path end
        if schema.maxItems and length>schema.maxItems then return false,path end
        local seen={}
        for i=1,length do
            if schema.items and not validateValue(schema.items,value[i],path) then return false,path end
            if schema.uniqueItems then
                local key=Json.encode(value[i])
                if seen[key] then return false,path end
                seen[key]=true
            end
        end
    elseif object(value) then
        for _,key in ipairs(schema.required or {}) do
            if value[key]==nil then return false,path..'.'..key end
        end
        for key,entry in pairs(value) do
            local child=schema.properties and schema.properties[key]
            if child then
                local ok,reason=validateValue(child,entry,path..'.'..key)
                if not ok then return false,reason end
            elseif schema.additionalProperties==false then return false,path..'.'..key end
        end
    end
    return true
end
local codes={sections='invalid_sections',radius='invalid_radius',events_after='invalid_event_cursor',
    include_map='invalid_include_map',detail='invalid_detail',command_id='invalid_command_id',
    options_offset='invalid_options_offset',compact='invalid_compact',action='invalid_action',
    answer='invalid_answer',region='invalid_region',format='invalid_map_format',source='unsupported_map_source'}
function M.validate(request)
    local valid=validateValue(Schema.envelope,request,'request')
    if not valid then return nil,'invalid_request' end
    local args=request.args
    -- Separate public validation never takes a caller-supplied mode switch.
    -- Keep existing typed action errors and normalized replay fingerprints.
    if request.op=='act' then
        local action,code=Actions.validatePublic(args.action)
        if not action then return nil,code end
    end
    local ok,path=validateValue(Schema.operations[request.op],args,'args')
    if not ok then
        if request.op=='list_collection' and path=='args.request' and object(args.request)
            and args.request.type=='first' then
            local collections=Schema.operations.list_collection.properties.request.oneOf[1].properties.collection
            if not validateValue(collections,args.request.collection,'collection') then return nil,'unsupported_collection' end
        end
        return nil,codes[path:match('^args%.([^%.]+)')] or 'invalid_request'
    end
    return true
end
return M
