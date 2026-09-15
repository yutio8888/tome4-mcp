local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Journal=require 'mod.mcp_bridge.Journal'
local count=0
local function check(value,message) count=count+1;assert(value,message) end
local a,b={str='Player hits rat for 5 damage.'},{str='Player killed rat!'}
local g={turn=10,uiset={logdisplay={log={b,a}}}}
local first=Journal.capture(g,0)
check(#first.entries==2 and first.entries[1].text==a.str and first.entries[2].text==b.str,'existing player log read chronologically')
check(first.cursor==2 and not first.gap and not first.has_more,'initial cursor')
check(#Journal.capture(g,2).entries==0 and g.turn==10,'unchanged log preserves cursor and game')
g.uiset.logdisplay.log={a}
local rollback=Journal.capture(g,2)
check(#rollback.entries==1 and rollback.entries[1].op=='remove' and rollback.entries[1].line_id==2,'rollback publishes removal')
a.str='Corrected visible damage.'
local update=Journal.capture(g,3)
check(update.entries[1].op=='update' and update.entries[1].line_id==1,'in-place log update')
g.uiset.logdisplay={log={{str='new UI'}}}
local replaced=Journal.capture(g,4)
check(replaced.entries[1].op=='reset' and replaced.entries[2].op=='append','log replacement resets line window without reusing cursors')
for i=1,300 do table.insert(g.uiset.logdisplay.log,1,{str='message '..i}) end
local overflow=Journal.capture(g,0)
check(overflow.gap and #overflow.entries==16 and overflow.has_more,'bounded backlog reports gap and paging')
local cursor=overflow.cursor;local pages=1
while overflow.has_more do
    overflow=Journal.capture(g,cursor)
    check(overflow.cursor>cursor,'pages advance without duplicates')
    cursor=overflow.cursor;pages=pages+1
end
check(cursor==overflow.head_cursor and pages==16,'retained journal drained in finite pages')
local tail=Journal.capture(g)
check(#tail.entries==12 and not tail.has_more,'default snapshot returns compact recent tail')
local future=Journal.capture(g,cursor+100)
check(future.cursor_ahead and future.cursor==cursor,'foreign or future cursors reported')
Journal.reset()
check(Journal.capture({}).head_cursor==0,'new session resets cursors')
local huge={turn=20,uiset={logdisplay={log={{str=string.rep('a',9000)}}}}}
local bounded=Journal.capture(huge,0)
check(#bounded.entries[1].text==512 and bounded.entries[1].text_truncated,'individual log text bounded')
Journal.reset()
local utf8=Journal.capture({uiset={logdisplay={log={{str=string.rep('界',900)}}}}},0)
check(#utf8.entries[1].text%3==0 and #utf8.entries[1].text<512,'truncation preserves complete UTF-8 characters')
Journal.reset()
local control=Journal.capture({uiset={logdisplay={log={{str=string.rep(string.char(1),1000)..'visible'}}}}},0)
check(control.entries[1].text=='visible','non-display control bytes do not inflate JSON')
print('Journal: '..count..' checks passed')
