-- GPL-3.0-or-later. Canonical command ledger (spec LED-01..09).
--
-- Pure bookkeeping: no game, UI, coroutine or socket dependency. Command ids
-- are cmd-<seq>; the ledger keeps the highest accepted sequence H, the evicted
-- prefix W and a bounded set of released receipts. H/W never reset inside a
-- game session, and a write whose seq <= W must never run again.
local M = {}
local Ledger = {}
Ledger.__index = Ledger
local MAX_SEQ = 9007199254740991
M.MAX_SEQ = MAX_SEQ

-- Exact decimal formatting: tostring uses %.14g on LuaJIT and would emit an
-- exponent form, which the protocol forbids.
local function formatSeq(n)
    local digits = ''
    repeat
        digits = string.char(48 + (n % 10)) .. digits
        n = math.floor(n / 10)
    until n == 0
    return digits
end

local function parseSeq(command_id)
    if type(command_id) ~= 'string' then return nil end
    local digits = command_id:match('^cmd%-(%d+)$')
    if not digits then return nil end
    if #digits > 16 or (#digits > 1 and digits:sub(1, 1) == '0') then return nil end
    local seq = tonumber(digits)
    if not seq or seq % 1 ~= 0 or seq < 1 or seq > MAX_SEQ then return nil end
    -- Reject values that the double formatter cannot round-trip.
    if formatSeq(seq) ~= digits then return nil end
    return seq
end
M.parseSeq = parseSeq

function M.new(options)
    options = options or {}
    return setmetatable({
        H = options.initial_h or 0,
        W = options.initial_w or 0,
        records = {},
        order = {},
        bytes = 0,
        max_retained = options.max_retained or 256,
        byte_budget = options.byte_budget or 4194304,
        on_evict = options.on_evict,
    }, Ledger)
end

function Ledger:nextCommandId()
    if self.H >= MAX_SEQ then return nil end
    return 'cmd-' .. formatSeq(self.H + 1)
end

function Ledger:history()
    return {
        last_accepted_seq = self.H,
        evicted_through_seq = self.W,
        retained_count = #self.order,
        next_command_id = self:nextCommandId(),
        dedup_scope = 'game_session',
    }
end

function Ledger:get(seq) return self.records[seq] end

-- Classification precedes any lease/revision check (LED-03 step 2/3/4).
-- Returns a state, the retained record when one applies, and a code.
function Ledger:classify(command_id, fingerprint)
    local seq = parseSeq(command_id)
    if not seq then return 'invalid', nil, 'invalid_command_id' end
    if seq <= self.W then return 'expired', nil, 'command_history_expired' end
    local record = self.records[seq]
    if record then
        if fingerprint ~= nil and record.fingerprint ~= fingerprint then
            return 'conflict', record, 'command_conflict'
        end
        return 'replay', record
    end
    if seq > self.H + 1 then return 'gap', nil, 'command_sequence_gap' end
    if seq <= self.H then return 'invariant', nil, 'command_ledger_hole' end
    return 'accept', nil, seq
end

function Ledger:accept(command_id, fingerprint, record, bytes)
    local seq = assert(parseSeq(command_id), 'accept expects a canonical command id')
    assert(seq == self.H + 1, 'accept only the next canonical sequence')
    record = record or {}
    record.command_id = command_id
    record.seq = seq
    record.fingerprint = fingerprint
    record.execution_released = record.execution_released == true
    record._bytes = bytes or (#command_id + #tostring(fingerprint or '') + 64)
    self.records[seq] = record
    self.order[#self.order + 1] = seq
    self.H = seq
    self.bytes = self.bytes + record._bytes
    self:evict()
    return record
end

function Ledger:touch(seq, bytes)
    local record = self.records[seq]
    if not record then return end
    if bytes then
        self.bytes = self.bytes + (bytes - record._bytes)
        record._bytes = bytes
    end
    self:evict()
end

function Ledger:release(seq)
    local record = self.records[seq]
    if record then record.execution_released = true end
    self:evict()
end

-- Evict only a contiguous, already released prefix (LED-05). An unreleased
-- head blocks eviction; there is at most one such command by INV-02.
function Ledger:evict()
    while (#self.order > self.max_retained) or (self.bytes > self.byte_budget) do
        local seq = self.order[1]
        local record = seq and self.records[seq]
        if not record or not record.execution_released then break end
        table.remove(self.order, 1)
        self.records[seq] = nil
        self.bytes = self.bytes - record._bytes
        self.W = seq
        if self.on_evict then self.on_evict(record) end
    end
end

function Ledger:status(seq)
    if type(seq) ~= 'number' then return 'invalid' end
    if seq <= self.W then return 'expired' end
    if self.records[seq] then return 'retained' end
    if seq > self.H then return 'not_accepted' end
    return 'invariant'
end

return M
