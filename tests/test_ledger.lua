-- Pure command-ledger tests (spec LED-01..09, T-LED-01..16 ledger parts).
-- No engine and no game source: the ledger is game independent by M2 design.
local root=(arg[0]:match('^(.*)/tests/[^/]+$') or 'game/addons/tome-mcp-bridge')
package.path=root..'/overload/?.lua;'..package.path
local Ledger=require 'mod.mcp_bridge.CommandLedger'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- Canonical id formatting/parsing (LED-01/02).
local l=Ledger.new()
check(l:nextCommandId()=='cmd-1','first command id is cmd-1')
for _,bad in ipairs{'cmd-0','cmd-01','cmd-1.0','cmd-+1','cmd-','cmd-1e3','uuid-1','cmd- 1','cmd-9007199254740992'} do
    check(Ledger.parseSeq(bad)==nil,'non-canonical id rejected: '..bad)
end
check(Ledger.parseSeq('cmd-9007199254740991')==9007199254740991,'max sequence parses')
check(Ledger.new{initial_h=9007199254740991}:nextCommandId()==nil,'sequence capacity reports null, never wraps')

-- T-LED-01 / T-LED-07: one native entry per identity, replay returns the record.
local a=Ledger.new()
local first=a:accept('cmd-1','fp-1',{status='queued'})
check(a.H==1 and a:history().next_command_id=='cmd-2','accepted command advances H by one')
local state,record=a:classify('cmd-1','fp-1')
check(state=='replay' and record==first,'duplicate identity replays the same record')
first.status='completed';a:release(1)
local state2,record2=a:classify('cmd-1','fp-1')
check(state2=='replay' and record2.status=='completed' and record2.execution_released,
    'a released receipt is still replayable with its result')

-- T-LED-02: same id, different fingerprint.
local state3,_,code3=a:classify('cmd-1','fp-other')
check(state3=='conflict' and code3=='command_conflict','changed request conflicts')

-- T-LED-05: gaps and invalid ids do not consume a sequence.
local g=Ledger.new()
g:accept('cmd-1','fp',{})
local gs,_,gc=g:classify('cmd-3','fp')
check(gs=='gap' and gc=='command_sequence_gap' and g.H==1,'gap is rejected before acceptance')
check(select(1,g:classify('cmd-bad','fp'))=='invalid','invalid id is rejected')
check(select(1,g:classify('cmd-2','fp'))=='accept','H+1 is the only acceptable sequence')

-- Unreleased head blocks prefix eviction (LED-05, INV-02).
local blocked=Ledger.new{max_retained=4}
blocked:accept('cmd-1','fp',{})            -- left unreleased
for i=2,20 do blocked:accept('cmd-'..i,'fp',{});blocked:release(i) end
check(blocked.W==0 and blocked:status(1)=='retained','an unreleased head is never evicted')
check(blocked:history().retained_count==20,'retained may exceed the budget only for the blocked head')
blocked:release(1)
check(blocked.W>=16 and blocked:history().retained_count<=4,'releasing the head drains the budget')

-- T-LED-03 / T-LED-04 / T-LED-06: 100000 commands stay bounded, no holes.
local big=Ledger.new{max_retained=256,byte_budget=4194304}
for i=1,100000 do
    local id='cmd-'..i
    local state,_,seq=big:classify(id,'fp-'..i)
    check(state=='accept','large run accepts the next sequence')
    big:accept(id,'fp-'..i,{status='queued'})
    big:release(i)
    if i%25000==0 then
        check(big.H==i and big:history().retained_count<=256 and big.bytes<=4194304,
            'ledger stays bounded at '..i)
    end
end
check(big.H==100000 and big.W==100000-big:history().retained_count,
    'evicted prefix plus retained suffix equals H (no holes)')
check(big:status(1)=='expired' and select(1,big:classify('cmd-1','fp-1'))=='expired',
    'an evicted sequence is expired, never re-executed')
check(big:status(100000)=='retained','the newest receipt is retained')
check(big:status(100001)=='not_accepted','an unsubmitted sequence is not accepted')
for seq in pairs(big.records) do
    check(seq>big.W and seq<=big.H,'every retained seq sits above W and at or below H')
end

-- Byte budget alone can force eviction.
local bytes=Ledger.new{max_retained=1000,byte_budget=800}
for i=1,40 do bytes:accept('cmd-'..i,'fp',{},100);bytes:release(i) end
check(bytes.bytes<=800 and bytes.W>=32,'byte budget evicts the released prefix')

-- on_evict lets the owner drop references (LED-05).
local dropped=0
local cb=Ledger.new{max_retained=2,on_evict=function() dropped=dropped+1 end}
for i=1,10 do cb:accept('cmd-'..i,'fp',{});cb:release(i) end
check(dropped==8,'on_evict fires once per evicted receipt')

print('Command ledger: '..checks..' checks passed')
