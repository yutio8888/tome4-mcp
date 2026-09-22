-- Offline selection/load boundary only. No game or native outcome doubles.
local entry=assert(arg[1],'pass the absolute AutoCombatProbe.lua path')
local cases={
    {name='no config',value=nil,policy=false},
    {name='empty settings',value={settings={}},policy=false},
    {name='false',value={settings={tome_mcp_sysfix_policy_probe=false}},policy=false},
    {name='string true',value={settings={tome_mcp_sysfix_policy_probe='true'}},policy=false},
    {name='explicit true',value={settings={tome_mcp_sysfix_policy_probe=true}},policy=true},
}
local checks=0
for _,case in ipairs(cases) do
    local selected={tag='policy-only'}
    local imports={}
    local env=setmetatable({config=case.value,os={},require=function(name)
        imports[name]=(imports[name] or 0)+1
        if name=='mod.SysfixPolicyProbe' then return selected end
        return {} -- top-level imports only; no scenario is executed
    end},{__index=_G})
    local chunk=assert(loadfile(entry));setfenv(chunk,env)
    local result=chunk()
    assert((result==selected)==case.policy,case.name..': selected wrong suite')
    assert((imports['mod.SysfixPolicyProbe'] or 0)==(case.policy and 1 or 0),case.name..': wrong import')
    if not case.policy then
        assert(type(result.onFrame)=='function' and result.EXPECTED['critical'],
            case.name..': default aggregate probe unavailable')
    end
    checks=checks+1
end
print('Native probe sandbox startup: '..checks..' cases passed (os.getenv absent; no native execution)')
