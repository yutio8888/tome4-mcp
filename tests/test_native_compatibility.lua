-- NativeCompatibility is DIAGNOSTIC ONLY (NO-AUDIT v1.6).
--
-- The game's actual entrypoints are used as normal entrypoints: a replaced-but-
-- usable function is used, and source/digest/identity/closure are reported as
-- advisory telemetry that must never gate a decision.
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
local Compat=require 'mod.mcp_bridge.NativeCompatibility'
local count=0
local function check(value,message) count=count+1;assert(value,message) end
local files={['/native.lua']='native bytes',['/wrapper.lua']='wrapper bytes'}
fs={readAll=function(path) return files[path] end}
package.loaded.md5={sumhexa=function(bytes) return bytes end}
local native=assert(loadstring('return function() return true end','@/native.lua'))()
local wrapper=assert(loadstring('return function(change) return function() return change() end end','@/wrapper.lua'))()(native)
local exposed=function() end
local spec={path='/wrapper.lua',digest='wrapper bytes',upvalue='change'}

-- Structural availability: a function is available; a nil is not. No identity.
Compat.register('method',exposed,wrapper,'/native.lua','native bytes',spec)
check(Compat.matches('method',exposed),'a registered function is structurally available')
check(Compat.matches('method',wrapper),'a different live function is still structurally usable (no identity gate)')
check(Compat.available('method'),'available reflects function presence, not identity')

-- Advisory provenance is REPORTED and never gates: a modified source/digest or a
-- replacement still leaves the function available for use.
files['/wrapper.lua']='modified wrapper'
Compat.register('method',exposed,wrapper,'/native.lua','native bytes',spec)
check(Compat.available('method'),'a modified wrapper fingerprint is advisory, not unavailable')
local id=Compat.identity('method',exposed)
check(id.advisory==true and id.digest_ok==false,'the modified fingerprint is reported as advisory drift')
files['/native.lua']='modified native'
Compat.register('method',exposed,wrapper,'/native.lua','native bytes',spec)
check(Compat.available('method'),'a modified native fingerprint is advisory, not unavailable')
files['/native.lua']='native bytes'
local other=assert(loadstring('return function() return true end','@/unknown.lua'))()
local bad=assert(loadstring('return function(change) return function() return change() end end','@/wrapper.lua'))()(other)
Compat.register('method',exposed,bad,'/native.lua','native bytes',spec)
check(Compat.available('method'),'an unrecognized captured native is advisory, not unavailable')
-- A non-function entrypoint is the only structural unavailability.
Compat.register('missing',nil,nil,'/native.lua','native bytes',spec)
check(not Compat.available('missing'),'a missing entrypoint is structurally unavailable')

-- dependency registry is diagnostic-only: the live function is always returned.
Compat.resetDependencies()
files['/dep.lua']='return function() return 2 end'
local dep_digest=files['/dep.lua']
local child=assert(loadstring('return function() return 2 end','@/dep.lua'))()
local parent=assert(loadstring('return function() return 3 end','@/dep.lua'))()
check(Compat.registerDependency('dep.child','test',child,'/dep.lua','child',dep_digest,'function')==child,
    'a registered dependency is returned for use (not a boolean gate)')
check(Compat.registerDependency('dep.parent','test',parent,'/dep.lua','parent',dep_digest,'function',{'dep.child'})==parent,
    'a parent dependency is returned for use')
check(Compat.dependency('dep.parent',parent)==parent,'the live function resolves for use')
-- A replaced-but-usable function is returned for use (no identity gate).
local replaced=assert(loadstring('return function() return 3 end','@/dep.lua'))()
check(Compat.dependency('dep.parent',replaced)==replaced,
    'a replaced-but-usable dependency is returned for use, not refused')
-- A digest mismatch is advisory telemetry, not a gate.
Compat.resetDependencies()
local spoof=assert(loadstring('return function() return 999 end','@/combat.lua'))()
check(Compat.registerDependency('computed.combatCrit','computed',spoof,'/combat.lua','getter',
    'digest-that-does-not-match','function _M:combatCrit',{})==spoof,
    'a digest mismatch does not make the dependency unavailable')
check(Compat.dependency('computed.combatCrit',spoof)==spoof,'the mismatched dependency is still usable')
local summary=Compat.dependencySummary()
check(summary['computed.combatCrit'] and summary['computed.combatCrit'].advisory==true,
    'the digest mismatch is reported as advisory')
-- The closure summary is informational.
Compat.resetDependencies()
Compat.registerDependency('dep.child','test',child,'/dep.lua','child',dep_digest,'function')
Compat.registerDependency('dep.parent','test',parent,'/dep.lua','parent',dep_digest,'function',{'dep.child'})
local closures=Compat.closureSummary()
check(closures['dep.parent'] and #closures['dep.parent'].depends_on==1,
    'closure summary exposes the informational edges')
-- Only a non-function is unavailable.
check(Compat.dependency('dep.parent','not-a-function')==nil,'a non-function dependency is unavailable')
print('Native compatibility: '..count..' checks passed')
