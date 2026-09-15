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
print('Native compatibility: '..count..' checks passed')
