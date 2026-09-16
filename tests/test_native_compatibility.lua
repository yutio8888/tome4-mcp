-- Full source fingerprint and captured-native chain validation, independently
-- of engine MD5 availability. Real package hashes run in native acceptance.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
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
Compat.register('method',exposed,wrapper,'/native.lua','native bytes',spec)
check(Compat.matches('method',exposed),'audited wrapper delegates to audited native captured function')
check(not Compat.matches('method',wrapper),'runtime entrypoint identity must still match registered bridge wrapper')
files['/wrapper.lua']='modified wrapper'
Compat.register('method',exposed,wrapper,'/native.lua','native bytes',spec)
check(not Compat.available('method'),'modified wrapper fingerprint rejected')
files['/wrapper.lua']='wrapper bytes';files['/native.lua']='modified native'
Compat.register('method',exposed,wrapper,'/native.lua','native bytes',spec)
check(not Compat.available('method'),'modified underlying native fingerprint rejected')
files['/native.lua']='native bytes'
local other=assert(loadstring('return function() return true end','@/unknown.lua'))()
local bad=assert(loadstring('return function(change) return function() return change() end end','@/wrapper.lua'))()(other)
Compat.register('method',exposed,bad,'/native.lua','native bytes',spec)
check(not Compat.available('method'),'known wrapper cannot hide unrecognized captured native entrypoint')
Compat.register('method',exposed,native,'/native.lua','native bytes',spec)
check(Compat.matches('method',exposed),'direct native entrypoint works without companion installed')
-- Indirect dependency closure (CMP-01/03).
Compat.resetDependencies()
files['/dep.lua']='return function() return 2 end'
local dep_digest=files['/dep.lua']
local child=assert(loadstring('return function() return 2 end','@/dep.lua'))()
local parent=assert(loadstring('return function() return 3 end','@/dep.lua'))()
check(Compat.registerDependency('dep.child','test',child,'/dep.lua','child',dep_digest,'function'),'audited dependency registered')
check(Compat.registerDependency('dep.parent','test',parent,'/dep.lua','parent',dep_digest,'function',{'dep.child'})~=nil,'parent dependency registered')
check(Compat.dependency('dep.parent',parent)~=nil,'an intact indirect closure resolves')
check(Compat.registerDependency('dep.orphan','test',parent,'/dep.lua','orphan',dep_digest,'function',{'dep.missing'})~=nil,'orphan dependency registered')
check(select(2,Compat.dependency('dep.orphan',parent))=='dependency_closure_broken','a missing transitive dependency makes the field unknown')
local summary=Compat.closureSummary()
check(summary['dep.parent'] and #summary['dep.parent'].depends_on==1 and summary['dep.orphan'].depends_on[1].ok==false,
    'closure summary exposes the edges and their status')
print('Native compatibility: '..count..' checks passed')
