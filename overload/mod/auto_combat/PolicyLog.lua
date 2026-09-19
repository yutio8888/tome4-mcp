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

local function bounded(value,limit)
    if type(value)~='table' then return value end
    local out={}
    for index=1,math.min(#value,limit) do out[index]=value[index] end
    return out
end

-- MFT-REV-07: bounded, redaction-friendly projection for the movement
-- annotation and the guard risk detail. Scalars and small nested tables only;
-- depth and key counts are capped so a hostile policy cannot grow the ring.
local function boundedObject(value,depth)
    if type(value)~='table' then return nil end
    if depth>3 then return nil end
    local out={}
    local count=0
    for key,item in pairs(value) do
        count=count+1
        if count>24 then break end
        if type(item)=='table' then
            local nested=boundedObject(item,depth+1)
            if nested~=nil then out[key]=nested end
        elseif type(item)=='string' or type(item)=='number' or type(item)=='boolean' then
            out[key]=item
        end
    end
    return out
end

local function boundedString(value,limit)
    if type(value)~='string' then return nil end
    if #value<=limit then return value end
    return value:sub(1,limit)
end

-- D-2: bounded projection of the structured `missing` array carried by a native
-- refusal, so the client-visible policy log has the same cooldown detail the
-- command path returns.
local function boundedMissing(value)
    if type(value)~='table' then return nil end
    local out={}
    for index=1,math.min(#value,8) do
        local entry=value[index]
        if type(entry)=='table' then
            local copy={}
            for _,key in ipairs{'kind','talent','remaining','required','stat','special','level'} do
                local item=entry[key]
                if type(item)=='string' and #item<=128 then copy[key]=item
                elseif type(item)=='number' and item==item then copy[key]=item end
            end
            if next(copy)~=nil then out[index]=copy end
        end
    end
    if #out==0 then return nil end
    return out
end

function M.add(log,event)
    if type(event)~='table' then return nil end
    local entry={seq=log.next_seq,kind=event.kind or 'event',reason=event.reason,
        rule=event.rule,talent=event.talent,target=event.target,native_result=event.native_result,
        action=event.action,
        -- P3-c: `landing` is only ever a bounded string produced by the movement
        -- retry path; guard the type so a hostile policy cannot grow the ring.
        landing=boundedString(event.landing,64),
        missing=boundedMissing(event.missing),hint=boundedString(event.hint,256),
        native_message=boundedString(event.native_message,512),
        elapsed_ticks=event.elapsed_ticks,
        elapsed_frames=event.elapsed_frames,
        movement=boundedObject(event.movement,0),risk=boundedObject(event.risk,0),
        -- S2 ordered prompt-response queue evidence: the observed native prompt
        -- sequence (bounded) and the reduced-trailing-optional marker. The typed
        -- deviation reaches the log as a `paused` event whose bounded `detail`
        -- carries expected/observed/index/reason.
        target_sequence=bounded(event.target_sequence,8),
        reduced=event.reduced==true or nil,reduced_reason=boundedString(event.reduced_reason,64),
        detail=boundedObject(event.detail,0),
        tick=event.tick,revision=event.revision,level_instance_id=event.level_instance_id,
        rule_results=bounded(event.rule_results,32),rejections=bounded(event.rejections,8),
        resources_before=event.resources_before,resources_after=event.resources_after,
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

-- Ascending, cursor-based slice for replay/export. Bounded by `limit`; entries
-- with seq > after_seq, oldest first, so a client can page a whole run.
function M.slice(log,after_seq,limit)
    limit=limit or 64
    after_seq=after_seq or 0
    local out={}
    for index=1,#log.entries do
        local entry=log.entries[index]
        if entry.seq>after_seq then
            out[#out+1]=entry
            if #out>=limit then break end
        end
    end
    return out
end

-- Ring extent plus the exact window metadata for a returned tail/slice. The
-- caller-supplied `limit` bounds the returned events, so the ring extent
-- (`first_seq`/`last_seq`/`total`) and the returned window can legitimately
-- differ. `window` makes that difference explicit instead of letting a client
-- mistake the ring's oldest sequence for the oldest returned event (round
-- anor-reg-01 D-4).
-- R-2 (round anor-reg-01 fix2): the window is order-aware. `log`/`status` return
-- a newest-first tail while `replay` returns an oldest-first slice; computing
-- the extent from the min/max sequence keeps `first_seq <= last_seq` (oldest
-- and newest returned event) for both orders.
function M.window(entries)
    entries=entries or {}
    local first,last
    for _,entry in ipairs(entries) do
        local seq=entry and entry.seq
        if seq~=nil then
            if first==nil or seq<first then first=seq end
            if last==nil or seq>last then last=seq end
        end
    end
    return {count=#entries,first_seq=first,last_seq=last}
end

function M.status(log,entries)
    local status={count=#log.entries,limit=log.limit,total=log.total,
        first_seq=log.entries[1] and log.entries[1].seq,
        last_seq=log.entries[#log.entries] and log.entries[#log.entries].seq,
        semantics='first_seq/last_seq/count/limit describe the retained ring; '
            ..'total is the lifetime event count (it can exceed count after '
            ..'eviction); the returned window is window.* (bounded by the request '
            ..'limit, first_seq/last_seq are the oldest/newest returned seq '
            ..'regardless of the returned event order)'}
    if entries~=nil then status.window=M.window(entries) end
    return status
end
return M
