-- GPL-3.0-or-later. Bounded, deterministic auto-combat event log.
--
-- The log answers "why did the plugin do that" without keeping unbounded state:
-- a fixed-size ring of the most recent events, each tagged with the running
-- policy hash and the controller generation. No engine access.
local M={}

function M.new(limit)
    limit=limit or 256
    if type(limit)~='number' or limit<1 then limit=256 end
    return {limit=math.floor(limit),entries={},next_seq=1,total=0}
end

function M.add(log,event)
    if type(event)~='table' then return nil end
    local entry={seq=log.next_seq,kind=event.kind or 'event',reason=event.reason,
        rule=event.rule,talent=event.talent,target=event.target,
        generation=event.generation,policy_hash=event.policy_hash}
    log.next_seq=log.next_seq+1
    log.total=log.total+1
    log.entries[#log.entries+1]=entry
    if #log.entries>log.limit then table.remove(log.entries,1) end
    return entry
end

-- Most recent first, bounded by `limit`.
function M.tail(log,limit)
    limit=limit or 32
    local out={}
    for index=#log.entries,1,-1 do
        if #out>=limit then break end
        out[#out+1]=log.entries[index]
    end
    return out
end

function M.status(log)
    return {count=#log.entries,limit=log.limit,total=log.total,
        first_seq=log.entries[1] and log.entries[1].seq,
        last_seq=log.entries[#log.entries] and log.entries[#log.entries].seq}
end
return M
