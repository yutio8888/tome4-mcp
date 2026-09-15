-- Actual native Chat:use with a controlled UI container. The full engine
-- constructor, generated seams and source audits are tested by chat/fixture.py.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local count=0
local function check(value,message) count=count+1;assert(value,message) end
local allow=true
package.loaded['mod.mcp_bridge.NativeCompatibility']={matches=function() return allow end}
local Tracker=require 'mod.mcp_bridge.InvocationTracker'
local Interactions=require 'mod.mcp_bridge.Interactions'
local Json=require 'mod.mcp_bridge.Json'
local file=assert(io.open('game/engines/default/engine/dialogs/Chat.lua'));local source=file:read('*a');file:close()
local native=assert(source:match('(function _M:use%(item, a%).-\nend)'))
local factory=assert(loadstring('local _M={}\n'..native..'\nreturn _M.use','@/engine/dialogs/Chat.lua'))
local use=factory()
local function fixture()
    Tracker.reset();Interactions.reset()
    local player={};local npc={};game={player=player,level={},dialogs={}}
    function game:unregisterDialog(d) Interactions.closeDialog(d);self.dialogs={} end
    local calls={get=0,reward=0,regen=0}
    local answer={'Rendered answer',action=function() calls.reward=calls.reward+1 end,jump='done'}
    local row={name='a) Rendered answer',answer=2}
    local page={answers={{'Invisible answer',cond=function() error('condition must not run on read') end},answer}}
    local provider={chats={welcome=page}}
    function provider:get(id) calls.get=calls.get+1;return self.chats[id] end
    local list={row}
    local d={player=player,npc=npc,chat=provider,cur_id='welcome',list=list,c_list={list=list},text='Rendered text',use=use}
    function d:regen() calls.regen=calls.regen+1;game:unregisterDialog(self) end
    local invocation=Tracker.startAction(game,{command_id='chat'},function() Interactions.openChat(d);game.dialogs={d} end)
    return d,invocation,Interactions.current(invocation),calls,answer
end
local d,invocation,h,calls,answer=fixture()
local description=Interactions.describe(invocation,{revision=1})
check(description.options[1].label=='Rendered answer' and description.answer_types[1]=='option' and #description.answer_types==1,
    'native visible list is projected without keyboard prefix or invented cancel')
check(calls.get==0,'reads never invoke native chat.get or condition callbacks')
local prepared=assert(Interactions.prepare(h,{type='option',option_id=description.options[1].option_id},{}))
Interactions.apply(h,prepared)
check(calls.get==1 and calls.reward==1 and calls.regen==1 and d.cur_id=='done',
    'actual native use resolves captured visible row answer index, executes reward and jumps')
check(not Interactions.valid(h),'closed native page cannot be answered again')
local mutations={
    function(d,h,a) d.list[1].name='a) Different visible answer' end,
    function(d,h,a) d.list[1].disabled=true end,
    function(d,h,a) d.list[1].answer=1 end,
    function(d,h,a) d.list[1]={name='a) Rendered answer',answer=2} end,
    function(d,h,a) a.action=function() end end,
    function(d,h,a) a.jump='different' end,
    function(d,h,a) a.switch_npc={} end,
    function(d,h,a) a.switch_npc_move_camera=true end,
    function(d,h,a) d.chat.chats.welcome.answers[2]={'replacement'} end,
    function(d,h,a) d.cur_id='done' end,
    function(d,h,a) d.c_list={list=d.list} end,
    function(d,h,a) d.npc={} end,
    function(d,h,a) d.player={} end,
    function(d,h,a) game.level={} end,
}
for i,mutate in ipairs(mutations) do
    d,invocation,h,calls,answer=fixture();description=Interactions.describe(invocation,{revision=1})
    mutate(d,h,answer)
    local result,code=Interactions.prepare(h,{type='option',option_id=description.options[1].option_id},{})
    check(not result and code=='interaction_expired' and calls.reward==0,'native page changed before answer '..i)
end
d,invocation,h,calls,answer=fixture();allow=false
check(not Interactions.valid(h),'modified native implementation invalidates existing Chat')
allow=true
-- Native generateList's 32nd shortcut is byte 128, which is not UTF-8.
-- Only rendered content is transmitted; strict JSON encoding remains intact.
d,invocation,h=fixture();Interactions.closeDialog(d)
d.list[1].name=string.char(128)..') 中文选项'
Tracker.scope(invocation,Interactions.openChat,d)
local ok,encoded=pcall(Json.encode,Interactions.describe(invocation,{revision=1}))
check(ok and encoded:find('中文选项',1,true),'native non-UTF8 shortcut never contaminates MCP JSON')
print('Chat: '..count..' checks passed')
