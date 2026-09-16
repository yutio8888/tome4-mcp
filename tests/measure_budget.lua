-- Budget measurement for the pure bookkeeping structures (spec G-04, LED-13,
-- OBS-07). Pure Lua: no engine and no game source. Prints one JSON object.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Ledger=require 'mod.mcp_bridge.CommandLedger'
local Views=require 'mod.mcp_bridge.ObservationViews'
local Json=require 'mod.mcp_bridge.Json'

local ledger_commands=tonumber(arg[1]) or 1000000
local view_cycles=tonumber(arg[2]) or 10000

-- Command receipts stay bounded over a long session.
local ledger=Ledger.new{max_retained=256,byte_budget=4194304}
local ledger_started=os.clock()
for i=1,ledger_commands do
    local id='cmd-'..i
    ledger:accept(id,'fp-'..i,{status='queued'})
    ledger:release(i)
end
local ledger_elapsed=os.clock()-ledger_started

-- Frozen views stay bounded and evict the oldest cursor.
local views=Views.new{max_views=4,byte_budget=4194304}
local items={}
for i=1,40 do items[i]={id='item-'..i,text=string.rep('x',64)} end
local view_started=os.clock()
local evicted=0
for i=1,view_cycles do
    local page=views:capture{collection='inventory',items=items,complete=true,
        context={session_id='s',level_instance_id='l',connection_generation=1},revision=i,page_size=16}
    assert(page and page.returned_count==16 and page.has_more==true)
    local next_page=views:nextPage(page.next_cursor,16)
    assert(next_page and next_page.returned_count==16)
    if views.order[1] and not views.views[views.order[1]] then evicted=evicted+1 end
end
local view_elapsed=os.clock()-view_started

local report={
    ledger={commands=ledger_commands,last_accepted_seq=ledger.H,evicted_through_seq=ledger.W,
        retained_count=#ledger.order,bytes=ledger.bytes,max_retained=ledger.max_retained,
        byte_budget=ledger.byte_budget,elapsed_seconds=ledger_elapsed,
        bounded=(#ledger.order<=ledger.max_retained and ledger.bytes<=ledger.byte_budget)},
    views={cycles=view_cycles,retained_views=#views.order,max_views=views.max_views,
        bytes=views.bytes,byte_budget=views.byte_budget,elapsed_seconds=view_elapsed,
        bounded=(#views.order<=views.max_views and views.bytes<=views.byte_budget)},
}
assert(report.ledger.bounded and report.views.bounded)
print(Json.encode(report))
