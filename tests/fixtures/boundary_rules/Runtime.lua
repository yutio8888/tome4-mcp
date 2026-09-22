-- Small structural test fixture; this is NOT production runtime evidence.
local function dispatch(s,request)
    local valid,validationCode=RequestValidation.validate(request)
    if not valid then return fail(validationCode) end
    local a,op=request.args,request.op
    return a,op
end
