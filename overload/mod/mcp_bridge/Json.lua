-- GPL-3.0-or-later. Strict, bounded JSON for Lua 5.1; never evaluates Lua.
local M = { MAX_DEPTH = 64 }
local array_mt = { __mcp_json_array = true }
M.null = setmetatable({}, { __tostring = function() return 'json.null' end })
function M.array(value) return setmetatable(value or {}, array_mt) end
-- The project's ONE dense/closed array validator (AGENTS.md checklist A): a
-- caller-supplied array is only usable with `#`/`ipairs` once every key is a
-- positive integer, there are no holes, and no keys beyond the dense end.
-- Rejects non-integer/zero/negative keys and holes; on success returns the
-- dense length. Kept dependency-free here so every ingress can share it.
function M.denseArray(list, minLength)
    if type(list) ~= 'table' or list == M.null then return false, 'not_array' end
    local maxKey, count = 0, 0
    for key in pairs(list) do
        if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then return false, 'non_integer_key' end
        if key > maxKey then maxKey = key end
        count = count + 1
    end
    if maxKey ~= count then return false, 'hole' end
    for i = 1, maxKey do if list[i] == nil then return false, 'hole' end end
    if minLength and maxKey < minLength then return false, 'too_short' end
    return true, maxKey
end
-- Diagnostic refinement for a caller array that already FAILED M.denseArray:
-- returns `nil` when no density fault can be named (dense, empty or a
-- non-table), otherwise a typed cause plus the offending key, matching the
-- AGENTS.md checklist-A shape taxonomy (non-integer key, hole, key beyond the
-- dense end). Deterministic for ALL key types (XPS1-REV-04): the SMALLEST
-- offending key in a documented total order wins — numeric keys first in
-- ascending numeric order, then string keys in ascending byte order, then any
-- exotic key type (not JSON-encodable) by `tostring`, best-effort (two exotic
-- keys can share a `tostring`, and their rendering is process-dependent; the
-- deterministic contract covers the JSON-encodable number/string universe).
-- Pure inspection; like `denseArray` it only READS the caller table.
function M.denseFault(list)
    if type(list) ~= 'table' or list == M.null then return nil end
    -- XPS1-REV-04: the offending key is chosen by a total order over ALL key
    -- types (see the header comment), so the fault no longer depends on the
    -- `pairs` traversal order of a particular LuaJIT process.
    local function rank(key)
        local kind = type(key)
        if kind == 'number' then return 1 end
        if kind == 'string' then return 2 end
        return 3
    end
    local function offendingLess(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        if ra == 1 then return a < b end
        return tostring(a) < tostring(b)
    end
    local maxKey, count = 0, 0
    local badKey = nil
    for key in pairs(list) do
        local integral = type(key) == 'number' and key % 1 == 0 and key >= 1
        if not integral then
            if badKey == nil or offendingLess(key, badKey) then badKey = key end
        else
            if key > maxKey then maxKey = key end
            count = count + 1
        end
    end
    if badKey ~= nil then return 'non_integer_key', badKey end
    if maxKey == count then return nil end
    -- Largest p such that 1..p are all present (the dense prefix end).
    local prefix = 0
    for i = 1, maxKey do
        if list[i] == nil then break end
        prefix = i
    end
    -- Exactly one key beyond the dense prefix (with the dense 1..p run before
    -- it) is the checklist-A 'key beyond the dense end' shape; anything else is
    -- a hole at the first missing index.
    local beyond, beyondCount = nil, 0
    for key in pairs(list) do
        if key > prefix then
            beyondCount = beyondCount + 1
            if beyond == nil or key < beyond then beyond = key end
        end
    end
    if beyondCount == 1 and count == prefix + 1 then
        return 'key_beyond_dense_end', beyond
    end
    return 'hole', prefix + 1
end
local function fail(message) error('JSON: '..message, 0) end
local function finite(n) return n == n and n > -math.huge and n < math.huge end

local function utf8_valid(s)
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local count, lower, upper = 0, 128, 191
        if b < 128 then count = 0
        elseif b >= 194 and b <= 223 then count = 1
        elseif b >= 224 and b <= 239 then
            count = 2
            if b == 224 then lower = 160 elseif b == 237 then upper = 159 end
        elseif b >= 240 and b <= 244 then
            count = 3
            if b == 240 then lower = 144 elseif b == 244 then upper = 143 end
        else return false end
        if count > 0 then
            local nextbyte = s:byte(i + 1)
            if not nextbyte or nextbyte < lower or nextbyte > upper then return false end
            for j = 2, count do
                local tail = s:byte(i + j)
                if not tail or tail < 128 or tail > 191 then return false end
            end
        end
        i = i + count + 1
    end
    return true
end
local escapes = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
local function quote(s)
    if not utf8_valid(s) then fail('invalid UTF-8') end
    return '"'..s:gsub('[%z\1-\31\\"]', function(c)
        return escapes[c] or ('\\u%04x'):format(c:byte())
    end)..'"'
end
function M.encode(value)
    local seen = {}
    local function emit(v, depth)
        if depth > M.MAX_DEPTH then fail('maximum depth exceeded') end
        if v == M.null or v == nil then return 'null' end
        local kind = type(v)
        if kind == 'string' then return quote(v)
        elseif kind == 'boolean' then return v and 'true' or 'false'
        elseif kind == 'number' then
            if not finite(v) then fail('non-finite number') end
            -- Lua's %.17g retains double precision, including fractional energy.
            return (('%.17g'):format(v):gsub(',', '.'))
        elseif kind ~= 'table' then fail('unsupported '..kind) end
        if seen[v] then fail('cyclic table') end
        seen[v] = true
        local numeric, strings, count, highest = false, false, 0, 0
        for k in pairs(v) do
            count = count + 1
            if type(k) == 'number' and k >= 1 and k % 1 == 0 then
                numeric = true; highest = math.max(highest, k)
            elseif type(k) == 'string' then strings = true
            else fail('invalid object key') end
        end
        local is_array = getmetatable(v) == array_mt or numeric
        if is_array and (strings or highest ~= count) then fail('mixed or sparse array') end
        local parts = {}
        if is_array then
            for i = 1, count do parts[i] = emit(v[i], depth + 1) end
        else
            local keys = {}; for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do parts[#parts + 1] = quote(k)..':'..emit(v[k], depth + 1) end
        end
        seen[v] = nil
        return (is_array and '[' or '{')..table.concat(parts, ',')..(is_array and ']' or '}')
    end
    return emit(value, 0)
end
local function utf8(cp)
    if cp < 128 then return string.char(cp)
    elseif cp < 2048 then return string.char(192 + math.floor(cp/64), 128 + cp%64)
    elseif cp < 65536 then return string.char(224 + math.floor(cp/4096), 128 + math.floor(cp/64)%64, 128 + cp%64)
    else return string.char(240 + math.floor(cp/262144), 128 + math.floor(cp/4096)%64, 128 + math.floor(cp/64)%64, 128 + cp%64) end
end
function M.decode(source)
    if type(source) ~= 'string' then fail('input must be a string') end
    local pos, len = 1, #source
    local function skip()
        while pos <= len do
            local b = source:byte(pos)
            if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 then break end
            pos = pos + 1
        end
    end
    local function hex4()
        local raw = source:sub(pos, pos + 3)
        if #raw ~= 4 or raw:find('[^0-9a-fA-F]') then fail('invalid unicode escape') end
        pos = pos + 4
        return tonumber(raw, 16)
    end
    local decode_escapes = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
    local function parse_string()
        pos = pos + 1
        local parts, start = {}, pos
        while pos <= len do
            local b = source:byte(pos)
            if b == 34 then
                parts[#parts + 1] = source:sub(start, pos - 1)
                pos = pos + 1
                local value = table.concat(parts)
                if not utf8_valid(value) then fail('invalid UTF-8') end
                return value
            elseif b == 92 then
                parts[#parts + 1] = source:sub(start, pos - 1)
                pos = pos + 1
                local escape = source:sub(pos, pos)
                pos = pos + 1
                if escape == 'u' then
                    local cp = hex4()
                    if cp >= 55296 and cp <= 56319 then
                        if source:sub(pos, pos + 1) ~= '\\u' then fail('missing low surrogate') end
                        pos = pos + 2
                        local low = hex4()
                        if low < 56320 or low > 57343 then fail('invalid low surrogate') end
                        cp = 65536 + (cp - 55296)*1024 + low - 56320
                    elseif cp >= 56320 and cp <= 57343 then fail('unpaired low surrogate') end
                    parts[#parts + 1] = utf8(cp)
                elseif decode_escapes[escape] then parts[#parts + 1] = decode_escapes[escape]
                else fail('invalid string escape') end
                start = pos
            elseif b < 32 then fail('unescaped control character')
            else pos = pos + 1 end
        end
        fail('unterminated string')
    end
    local parse
    parse = function(depth)
        if depth > M.MAX_DEPTH then fail('maximum depth exceeded') end
        skip()
        local char = source:sub(pos, pos)
        if char == '"' then return parse_string() end
        if char == '{' or char == '[' then
            local is_array = char == '['
            local result, keys = is_array and M.array() or {}, {}
            local ending = is_array and ']' or '}'
            pos = pos + 1; skip()
            if source:sub(pos, pos) == ending then pos = pos + 1; return result end
            while true do
                local key
                if not is_array then
                    if source:sub(pos, pos) ~= '"' then fail('object key must be a string') end
                    key = parse_string()
                    if keys[key] then fail('duplicate object key') end
                    keys[key] = true; skip()
                    if source:sub(pos, pos) ~= ':' then fail('missing colon') end
                    pos = pos + 1
                end
                local value = parse(depth + 1)
                if is_array then result[#result + 1] = value else result[key] = value end
                skip(); local nextchar = source:sub(pos, pos)
                pos = pos + 1
                if nextchar == ending then return result end
                if nextchar ~= ',' then fail('missing separator') end
                skip()
            end
        end
        for literal, value in pairs({ ['true']=true, ['false']=false, ['null']=M.null }) do
            if source:sub(pos, pos + #literal - 1) == literal then pos = pos + #literal; return value end
        end
        local start = pos
        if char == '-' then pos = pos + 1 end
        local first = source:sub(pos, pos)
        if first == '0' then pos = pos + 1
        elseif first:match('^[1-9]$') then
            repeat pos = pos + 1 until not source:sub(pos, pos):match('^%d$')
        else fail('invalid value') end
        if source:sub(pos, pos) == '.' then
            pos = pos + 1
            if not source:sub(pos, pos):match('^%d$') then fail('invalid fraction') end
            repeat pos = pos + 1 until not source:sub(pos, pos):match('^%d$')
        end
        if source:sub(pos, pos):match('^[eE]$') then
            pos = pos + 1
            if source:sub(pos, pos):match('^[+-]$') then pos = pos + 1 end
            if not source:sub(pos, pos):match('^%d$') then fail('invalid exponent') end
            repeat pos = pos + 1 until not source:sub(pos, pos):match('^%d$')
        end
        local value = tonumber(source:sub(start, pos - 1))
        if not value or not finite(value) then fail('non-finite number') end
        return value
    end
    local value = parse(0)
    skip()
    if pos <= len then fail('trailing data') end
    return value
end
return M
