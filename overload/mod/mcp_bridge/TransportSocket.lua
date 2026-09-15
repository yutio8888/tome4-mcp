-- GPL-3.0-or-later. A single loopback client; bounded work per display frame.
local Json = require 'mod.mcp_bridge.Json'
local M = {}
local Transport = {}; Transport.__index = Transport
local DEFAULTS = { max_message=65536, max_queue=524288, max_queued_messages=64,
    read_budget=32768, write_budget=65536, message_budget=8, accept_budget=4 }
local function close(socket) if socket then pcall(socket.close, socket) end end
function M.new(options)
    options = options or {}
    if options.host and options.host ~= '127.0.0.1' then return nil, 'loopback_host_required' end
    if type(options.port) ~= 'number' or options.port < 1 or options.port > 65535 or options.port % 1 ~= 0 then
        return nil, 'invalid_port'
    end
    local socket = options.socket
    if not socket then
        local ok, value = pcall(require, 'socket')
        if not ok then return nil, 'socket_unavailable' end
        socket = value
    end
    local listener, err = socket.tcp()
    if not listener then return nil, err end
    local ok
    ok, err = listener:settimeout(0)
    if ok then ok, err = listener:setoption('reuseaddr', true) end
    if ok then ok, err = listener:bind('127.0.0.1', options.port) end
    if ok then ok, err = listener:listen(2) end
    if not ok then close(listener); return nil, err end
    local self = setmetatable({listener=listener, onRequest=options.onRequest,
        onDisconnect=options.onDisconnect, input='', output={}, output_bytes=0, output_offset=1}, Transport)
    for name, value in pairs(DEFAULTS) do
        local chosen = options[name] or value
        if type(chosen) ~= 'number' or chosen < 1 or chosen % 1 ~= 0 then close(listener); return nil, 'invalid_limit' end
        self[name] = chosen
    end
    return self
end
function Transport:disconnectClient(reason)
    local previous = self.client
    self.client, self.input, self.output, self.output_bytes, self.output_offset = nil, '', {}, 0, 1
    close(previous)
    -- Clear state before calling Runtime, so its cleanup may safely call stop.
    if previous and self.onDisconnect then pcall(self.onDisconnect, reason or 'disconnected') end
end
function Transport:close()
    local listener = self.listener; self.listener = nil
    close(listener)
    self:disconnectClient('closed')
end
function Transport:send(value)
    if not self.client then return nil, 'not_connected' end
    local ok, encoded = pcall(Json.encode, value)
    if not ok then return nil, 'encode_error' end
    encoded = encoded..'\n'
    if #encoded > self.max_message or self.output_bytes + #encoded > self.max_queue or #self.output >= self.max_queued_messages then
        self:disconnectClient('output_limit'); return nil, 'output_limit'
    end
    self.output[#self.output + 1] = encoded
    self.output_bytes = self.output_bytes + #encoded
    return true
end
function Transport:poll()
    if not self.listener or self.polling then return end
    self.polling = true
    local ok = pcall(function()
        local read = 0
        local function read_input(client)
            while read < self.read_budget do
                local data, err, partial = client:receive(math.min(4096, self.read_budget - read))
                local chunk = data or partial or ''
                read = read + #chunk
                self.input = self.input..chunk
                -- Bound all buffered input, including pipelined complete lines.
                if #self.input > self.max_queue then self:disconnectClient('input_limit'); return end
                if err and err ~= 'timeout' then self:disconnectClient(err); return end
                if err == 'timeout' or #chunk == 0 then break end
            end
        end
        -- Reap an old peer's EOF before accepting a replacement. Otherwise an
        -- immediate reconnect gets rejected as a second client for one frame.
        local existing = self.client
        if existing then read_input(existing) end
        for _ = 1, self.accept_budget do
            if not self.listener then return end
            local incoming, err = self.listener:accept()
            if not incoming then
                if err ~= 'timeout' then self:close() end
                break
            end
            if self.client then close(incoming)
            else
                local ready = incoming:settimeout(0)
                if ready then self.client = incoming else close(incoming) end
            end
        end
        local client = self.client
        if not client then return end
        if client ~= existing then read_input(client) end
        if self.client ~= client then return end
        for _ = 1, self.message_budget do
            local ending = self.input:find('\n', 1, true)
            if not ending then
                if #self.input >= self.max_message then self:disconnectClient('message_limit') end
                break
            end
            if ending > self.max_message then self:disconnectClient('message_limit'); return end
            local line = self.input:sub(1, ending - 1)
            self.input = self.input:sub(ending + 1)
            local parsed, message = pcall(Json.decode, line)
            if not parsed or type(message) ~= 'table' or message == Json.null then self:disconnectClient('invalid_json'); return end
            if self.onRequest then
                local handled = pcall(self.onRequest, message)
                if not handled then self:disconnectClient('request_error'); return end
            end
            if self.client ~= client then return end
        end
        if self.client ~= client then return end
        local written = 0
        while #self.output > 0 and written < self.write_budget do
            local frame, start = self.output[1], self.output_offset
            local ending = math.min(#frame, start + self.write_budget - written - 1)
            local last, err, partial = client:send(frame, start, ending)
            local index = last or partial or start - 1
            if index < start - 1 or index > ending then self:disconnectClient('invalid_send_index'); return end
            local count = index - start + 1
            written = written + count; self.output_bytes = self.output_bytes - count
            self.output_offset = index + 1
            if self.output_offset > #frame then table.remove(self.output, 1); self.output_offset = 1 end
            if err and err ~= 'timeout' then self:disconnectClient(err); return end
            if err == 'timeout' or count == 0 then break end
        end
    end)
    self.polling = false
    if not ok then self:disconnectClient('transport_error') end
end
return M
