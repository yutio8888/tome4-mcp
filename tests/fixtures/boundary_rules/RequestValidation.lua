-- Small structural test fixture; this is NOT a production ingress or native evidence.
local function validateValue(schema,value,path)
    if schema.type=='array' then
        local dense,length=Json.denseArray(value)
        if not dense then return false,path end
        for i=1,length do
            if not validateValue(schema.items,value[i],path) then return false,path end
        end
    end
    return true
end
function M.validate(request)
    local valid=validateValue(Schema.envelope,request,'request')
    if not valid then return nil,'invalid_request' end
    local args=request.args
    local ok,path=validateValue(Schema.operations[request.op],args,'args')
    if not ok then return nil,path end
    return true
end
