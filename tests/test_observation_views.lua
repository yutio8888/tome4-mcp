-- Frozen collection view tests (spec OBS-01..08, T-OBS-01..08).
-- Pure store: no engine, no game source.
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
local Views=require 'mod.mcp_bridge.ObservationViews'
local Json=require 'mod.mcp_bridge.Json'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

local now=1000
local function store(options)
    options=options or {}
    options.clock=function() return now end
    return Views.new(options)
end
local function items(n) local out={} for i=1,n do out[i]={id='item-'..i,value=i} end return out end
local function collect(store,first)
    local all,page= {},first
    while page do
        for _,item in ipairs(page.items) do all[#all+1]=item.id end
        if page.next_cursor==Json.null or page.next_cursor==nil then break end
        local next_page,code=store:nextPage(page.next_cursor,page.returned_count)
        check(code==nil,'next page should not fail: '..tostring(code))
        page=next_page
    end
    return all
end

-- T-OBS-01/02: complete enumeration across pages, no duplicates.
local s=store()
local page,code=s:capture{collection='inventory',items=items(100),complete=true,context={session_id='s1',level_instance_id='l1'},revision=5}
check(page and code==nil and page.returned_count==32 and page.total_count==100,'first page is bounded and reports the total')
check(page.capture_complete==true and page.has_more==true and page.historical==false,'first page marks completeness and continuation')
local all=collect(s,page)
check(#all==100 and all[1]=='item-1' and all[100]=='item-100','pagination union equals the allowed set in order')
local seen={}
for _,id in ipairs(all) do check(not seen[id],'no duplicate item: '..id);seen[id]=true end

-- T-OBS-04: the same cursor returns identical items and next cursor.
local s2=store()
local p2=s2:capture{collection='actors',items=items(70),complete=true,context={session_id='s1',level_instance_id='l1'},revision=3}
local again=s2:nextPage(p2.next_cursor,32)
local again_b=s2:nextPage(p2.next_cursor,32)
check(again.items[1].id==again_b.items[1].id and again.next_cursor==again_b.next_cursor,'re-reading a cursor is stable')

-- T-OBS-03: a normal revision change makes a page historical but not invalid.
s2:setRevision(9)
local hist=s2:nextPage(again.next_cursor,32)
check(hist.historical==true and hist.captured_revision==3 and hist.current_revision==9,'a revision change is historical, not expired')

-- T-OBS-05: TTL expiry invalidates the cursor.
local s3=store()
local p3=s3:capture{collection='talents',items=items(5),complete=true,context={session_id='s1',level_instance_id='l1'},revision=1}
now=now+120001
local expired,expired_code=s3:nextPage(p3.next_cursor,32)
check(expired==nil and expired_code=='cursor_expired','an expired view returns cursor_expired')

-- T-OBS-06: capacity eviction invalidates the oldest cursor.
now=now+10
local s4=store{max_views=2}
local p4=s4:capture{collection='inventory',items=items(3),complete=true,context={session_id='s1',level_instance_id='l1'},revision=1}
s4:capture{collection='actors',items=items(3),complete=true,context={session_id='s1',level_instance_id='l1'},revision=1}
s4:capture{collection='effects',items=items(3),complete=true,context={session_id='s1',level_instance_id='l1'},revision=1}
local gone,gone_code=s4:nextPage(p4.next_cursor,32)
check(gone==nil and gone_code=='cursor_expired','capacity eviction expires the oldest cursor')

-- T-OBS-07: byte budget advances the cursor without gaps or empty pages.
local s5=store{page_bytes=25000}
local big={}
for i=1,6 do big[i]={id='big-'..i,text=string.rep('x',10000)} end
local p5=s5:capture{collection='inventory',items=big,complete=true,context={session_id='s1',level_instance_id='l1'},revision=1}
check(p5.returned_count==2 and p5.has_more,'byte budget returns at least one and fewer than the count limit')
local all_big=collect(s5,p5)
check(#all_big==6 and all_big[6]=='big-6','byte-limited pages still cover every item once')

-- T-OBS-03b: a single item larger than the page budget is explicit, not an
-- infinite empty page.
local s6=store{page_bytes=50}
local too_big,too_big_code=s6:capture{collection='inventory',items={{id='huge',text=string.rep('x',500)}},complete=true,context={session_id='s1',level_instance_id='l1'},revision=1}
check(too_big==nil and too_big_code=='item_projection_too_large','an oversized item is reported, not looped')

-- T-OBS-08: over item capacity is a clear error, never a fake complete view.
local s7=store{max_items=10}
local capped,capped_code=s7:capture{collection='inventory',items=items(11),complete=true,context={session_id='s1',level_instance_id='l1'},revision=1}
check(capped==nil and capped_code=='collection_limit_exceeded','item capacity is enforced')

-- T-OBS-11: an incomplete capture never claims completeness.
local s8=store()
local partial=s8:capture{collection='inventory',items=items(5),complete=false,context={session_id='s1',level_instance_id='l1'},revision=1}
check(partial.capture_complete==false and partial.total_count==5,'capture_complete reflects the caller, not the page count')

-- T-OBS-05b: a context change invalidates old cursors.
local s9=store()
local p9=s9:capture{collection='actors',items=items(40),complete=true,context={session_id='s1',level_instance_id='l1',connection_generation=1},revision=1}
s9:invalidateContext{session_id='s1',level_instance_id='l1',connection_generation=2}
local ctx,ctx_code=s9:nextPage(p9.next_cursor,32)
check(ctx==nil and ctx_code=='cursor_expired','a connection generation change expires the cursor')

-- Cursor shape is opaque ASCII and a malformed cursor is expired, not crash.
check(Views.parseCursor(p9.next_cursor)==nil or type(Views.parseCursor(p9.next_cursor)=='string'),'cursor shape stays opaque')
local bad,bad_code=s9:nextPage('not-a-cursor',32)
check(bad==nil and bad_code=='cursor_expired','malformed cursor is cursor_expired')

print('Observation views: '..checks..' checks passed')
