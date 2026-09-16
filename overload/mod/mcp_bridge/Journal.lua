-- A bounded journal of lines already displayed to the player. No log callbacks,
-- actor lookups or perception checks run here. Cursors are session-local.
local Json=require 'mod.mcp_bridge.Json'
local M={LIMIT=256,PAGE=16,TEXT_LIMIT=512}
local current,display,entries,sequence,next_line,prev_texts
function M.reset()
    current={};display=nil;entries={};sequence=0;next_line=0;prev_texts={}
end
M.reset()
local function boundedText(value)
    value=value:gsub('[%z\1-\8\11\12\14-\31\127]','')
    if #value<=M.TEXT_LIMIT then return value end
    local finish=M.TEXT_LIMIT
    while finish>0 and value:byte(finish)>=128 and value:byte(finish)<192 do finish=finish-1 end
    if finish>0 and value:byte(finish)>=192 then finish=finish-1 end
    return value:sub(1,finish)
end
local function append(event)
    sequence=sequence+1;event.cursor=sequence
    entries[#entries+1]=event
    while #entries>M.LIMIT do table.remove(entries,1) end
end
function M.update(g)
    local logdisplay=g.uiset and g.uiset.logdisplay
    if not logdisplay or type(logdisplay.log)~='table' then return end
    if display~=logdisplay then
        if display then append{op='reset',reason='log_display_replaced'} end
        display=logdisplay;current={};prev_texts={}
    end
    local present,appended,present_texts={},{},{}
    -- LogDisplay stores the newest line first; publish new lines oldest first.
    for i=math.min(#logdisplay.log,512),1,-1 do
        local row=logdisplay.log[i]
        if type(row)=='table' and type(row.str)=='string' and row.str~='' then
            local text=boundedText(row.str)
            present_texts[#present_texts+1]=text
            local existing=current[row]
            if not existing then
                next_line=next_line+1
                existing={id=next_line,text=text}
                appended[#appended+1]={line=existing,raw=row.str}
            elseif text~=existing.text then
                existing.text=text
                appended[#appended+1]={line=existing,update=true,raw=row.str}
            end
            present[row]=existing
        end
    end
    -- The engine may rebuild every log row object while the visible text is
    -- unchanged (for example after a level change). Re-key without replaying.
    local rerender=#appended>0 and #present_texts==#prev_texts
    if rerender and #prev_texts>0 then
        for i=1,#present_texts do
            if present_texts[i]~=prev_texts[i] then rerender=false;break end
        end
    else
        rerender=false
    end
    if rerender then current=present;prev_texts=present_texts;return end
    for _,item in ipairs(appended) do
        append{op=item.update and 'update' or 'append',line_id=item.line.id,text=item.line.text,
            observed_world_tick=g.turn or 0,text_truncated=#item.raw>#item.line.text}
    end
    -- Rollback, clearing and history eviction are observable log changes.
    -- They do not imply that a previous game action was undone.
    local removed={}
    for row,line in pairs(current) do
        if not present[row] then removed[#removed+1]={id=line.id,text=line.text} end
    end
    table.sort(removed,function(a,b) return a.id<b.id end)
    for _,entry in ipairs(removed) do
        append{op='remove',line_id=entry.id,text=entry.text,reason='no_longer_in_visible_log'}
    end
    current=present;prev_texts=present_texts
end
function M.capture(g,after)
    M.update(g)
    local head=sequence
    local oldest=entries[1] and entries[1].cursor or head+1
    local requested=after
    if requested==nil then requested=math.max(0,head-12) end
    local result={source='player_visible_log',entries=Json.array(),head_cursor=head,
        oldest_cursor=oldest,cursor=math.min(requested,head),gap=requested<oldest-1,
        cursor_ahead=requested>head,has_more=false,
        semantics='Log changes only; remove means rollback, clearing, or history eviction, not game rollback.'}
    for _,entry in ipairs(entries) do
        if entry.cursor>requested then
            if #result.entries>=M.PAGE then result.has_more=true;break end
            result.entries[#result.entries+1]=entry;result.cursor=entry.cursor
        end
    end
    return result
end
return M
