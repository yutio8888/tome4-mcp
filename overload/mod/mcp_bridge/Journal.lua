-- A bounded journal of lines already displayed to the player. No log callbacks,
-- actor lookups or perception checks run here. Cursors are session-local.
local Json=require 'mod.mcp_bridge.Json'
local M={LIMIT=256,PAGE=16,TEXT_LIMIT=512}
local current,display,entries,sequence,next_line
function M.reset()
    current={};display=nil;entries={};sequence=0;next_line=0
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
        display=logdisplay;current={}
    end
    local present={}
    -- LogDisplay stores the newest line first; publish new lines oldest first.
    for i=math.min(#logdisplay.log,512),1,-1 do
        local row=logdisplay.log[i]
        if type(row)=='table' and type(row.str)=='string' and row.str~='' then
            local existing=current[row]
            local text=boundedText(row.str)
            if not existing then
                next_line=next_line+1
                existing={id=next_line,text=text}
                append{op='append',line_id=existing.id,text=text,observed_world_tick=g.turn or 0,
                    text_truncated=#row.str>#text}
            elseif text~=existing.text then
                existing.text=text
                append{op='update',line_id=existing.id,text=text,observed_world_tick=g.turn or 0,
                    text_truncated=#row.str>#text}
            end
            present[row]=existing
        end
    end
    -- Rollback, clearing and history eviction are observable log changes.
    -- They do not imply that a previous game action was undone.
    local removed={}
    for row,line in pairs(current) do
        if not present[row] then removed[#removed+1]=line.id end
    end
    table.sort(removed)
    for _,id in ipairs(removed) do append{op='remove',line_id=id,reason='no_longer_in_visible_log'} end
    current=present
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
