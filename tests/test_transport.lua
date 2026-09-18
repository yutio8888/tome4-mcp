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
package.path = root..'/overload/?.lua;'..package.path
local Json = require 'mod.mcp_bridge.Json'
local Transport = require 'mod.mcp_bridge.TransportSocket'
local checks = 0
local function check(value, message) checks=checks+1; assert(value, message) end
local function client()
    return {
        reads={}, writes='', send_plan={}, calls={},
        settimeout=function(self,n) self.timeout=n; return 1 end,
        close=function(self) self.closed=true end,
        receive=function(self,n)
            local nextread = table.remove(self.reads,1)
            if not nextread then return nil,'timeout','' end
            if type(nextread)=='string' then
                if #nextread >= n then
                    if #nextread > n then table.insert(self.reads,1,nextread:sub(n+1)) end
                    return nextread:sub(1,n)
                end
                return nil,'timeout',nextread
            end
            return nil,nextread.error,nextread.partial or ''
        end,
        send=function(self,data,first,last)
            self.calls[#self.calls+1]={first=first,last=last}
            local plan=table.remove(self.send_plan,1)
            local count=math.min(plan and plan.bytes or (last-first+1),last-first+1)
            self.writes=self.writes..data:sub(first,first+count-1)
            if plan and plan.error then return nil,plan.error,first+count-1 end
            return first+count-1
        end,
    }
end
local function fixture(options)
    local listener={pending={},settimeout=function(self,n) self.timeout=n;return 1 end,
        setoption=function(self,name,value) self[name]=value; return 1 end,
        bind=function(self,host,port) self.host,self.port=host,port; return 1 end,
        listen=function() return 1 end,close=function(self) self.closed=true end,
        accept=function(self) return table.remove(self.pending,1),'timeout' end}
    options=options or {}; options.port=55555; options.socket={tcp=function() return listener end}
    local bridge,err=Transport.new(options); assert(bridge,err)
    return bridge,listener
end
local received,disconnected={},{}
local bridge,listener=fixture{onRequest=function(v) received[#received+1]=v end,
    onDisconnect=function(reason) disconnected[#disconnected+1]=reason end}
local peer=client(); listener.pending[1]=peer
peer.reads[1]='{"v":1,"id":"一",'; peer.reads[2]='"op":"observe","args":{}}\n'
bridge:poll(); check(#received==0,'partial line not dispatched')
bridge:poll(); check(#received==1 and received[1].id=='一','partial UTF-8 message parsed')
check(listener.timeout==0 and peer.timeout==0 and listener.host=='127.0.0.1' and listener.reuseaddr,'loopback nonblocking reuseaddr')
local second=client();listener.pending[1]=second;bridge:poll()
check(second.closed and bridge.client==peer,'second client rejected')
peer.send_plan={{bytes=3,error='timeout'},{bytes=2,error='timeout'}}
local response={v=1,id='one',ok=true,result={hello='中文'}}
check(bridge:send(response),'response queued')
bridge:poll();bridge:poll();bridge:poll()
check(peer.writes==Json.encode(response)..'\n','partial output preserves bytes')
check(peer.calls[2].first==4 and peer.calls[3].first==6,'partial send uses absolute index')
check(bridge.output_bytes==0 and #bridge.output==0,'queue drains')
peer.reads[1]='{}\n{}\n{}\n';bridge.message_budget=2
bridge:poll();check(#received==3,'per-frame message budget')
bridge:poll();check(#received==4,'buffered remaining line dispatched next frame')
peer.reads[1]='{"incomplete":';bridge:poll();peer.reads[1]={error='closed'};bridge:poll()
check(#disconnected==1 and bridge.client==nil and bridge.input=='','disconnect drops old partial input')
local replacement=client();listener.pending[1]=replacement;replacement.reads[1]='{}\n';bridge:poll()
check(#received==5 and bridge.client==replacement,'reconnect accepts fresh request only')
local immediate=client();listener.pending[1]=immediate;replacement.reads[1]={error='closed'}
immediate.reads[1]='{}\n';bridge:poll()
check(replacement.closed and not immediate.closed and bridge.client==immediate and #received==6,
    'old EOF is handled before immediate reconnect acceptance')
bridge:disconnectClient('manual');check(#disconnected==3 and not listener.closed,'manual disconnect keeps listener')
bridge:close();check(listener.closed and #disconnected==3,'close does not duplicate callbacks')

local limits,limits_listener=fixture{max_message=16,max_queue=32,write_budget=4,read_budget=8}
local limited=client();limits_listener.pending[1]=limited;limits:poll()
check(limits:send({x='abc'}),'small output queued')
limits:poll();check(#limited.writes==4 and limits.output_bytes>0,'write byte budget')
limits:poll();limits:poll();check(limits.output_bytes==0,'remaining output sent')
check(not limits:send({x=string.rep('x',20)}) and limited.closed,'oversize output disconnects')
local huge=client();limits_listener.pending[1]=huge;huge.reads[1]=string.rep('x',20)
limits:poll();check(not huge.closed and #limits.input==8,'read byte budget')
limits:poll();check(huge.closed,'unterminated oversize line disconnects')

local invalid,invalid_listener=fixture{}
local bad=client();invalid_listener.pending[1]=bad;bad.reads[1]='{"a":1,"a":2}\n';invalid:poll()
check(bad.closed,'invalid JSON disconnects')
local callback,callback_listener=fixture{onRequest=function() error('boom') end}
local boom=client();callback_listener.pending[1]=boom;boom.reads[1]='{}\n';callback:poll()
check(boom.closed and not callback.polling,'callback failure contained')
local recursive
recursive,listener=fixture{onDisconnect=function() recursive:disconnectClient('nested') end}
peer=client();listener.pending[1]=peer;recursive:poll();recursive:disconnectClient('first')
check(peer.closed and recursive.client==nil,'disconnect cleanup is reentrant')
check(not Transport.new{host='0.0.0.0',port=55555},'external bind rejected')
check(not Transport.new{port=0},'invalid port rejected')
local calls={}
local function restart_listener()
    return {settimeout=function() return 1 end,
        setoption=function(self,name,value) self.reuse=value;calls[#calls+1]='reuse';return 1 end,
        bind=function(self) calls[#calls+1]='bind'; return self.reuse and 1 or nil,'address in use' end,
        listen=function() return 1 end,close=function() end}
end
local address={tcp=restart_listener}
local first=assert(Transport.new{port=55555,socket=address});first:close()
local restarted=assert(Transport.new{port=55555,socket=address});restarted:close()
check(table.concat(calls,',')=='reuse,bind,reuse,bind','restart applies reuseaddr before every bind')
local failed=restart_listener();failed.setoption=function() return nil,'option failed' end
failed.close=function(self) self.closed=true end
local value,reason=Transport.new{port=55555,socket={tcp=function() return failed end}}
check(not value and reason=='option failed' and failed.closed,'listener setup failure closes socket')
-- NET-02: an unauthenticated connection only holds the single slot for the
-- handshake window; an authenticated client is never dropped by that timer.
local clock={t=0}
local hbridge,hlistener=fixture{clock=function() return clock.t end,handshake_timeout=5000}
local hpeer=client();hlistener.pending[1]=hpeer
hbridge:poll()
check(not hpeer.closed and hbridge.client==hpeer,'a new unauthenticated client is accepted')
clock.t=5001
hbridge:poll()
check(hpeer.closed and hbridge.client==nil,'an unauthenticated client past the window is dropped')
local abridge,alistener=fixture{clock=function() return clock.t end,handshake_timeout=5000}
local apeer=client();alistener.pending[1]=apeer
abridge:poll();abridge:markAuthenticated()
clock.t=clock.t+100000
abridge:poll()
check(not apeer.closed and abridge.client==apeer,'an authenticated client is not dropped by the handshake timer')
print(('transport: %d checks passed'):format(checks))
