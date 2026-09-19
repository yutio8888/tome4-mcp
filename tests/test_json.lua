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
package.path = root..'/overload/?.lua;'..package.path
local Json = require 'mod.mcp_bridge.Json'
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local function rejects(source) check(not pcall(Json.decode, source), 'accepted invalid JSON: '..source) end
local value = Json.decode('{"a":[true,false,null,-1.25,2e3],"empty":{},"text":"中文\\n\\uD83D\\uDE80"}')
check(value.a[1] == true and value.a[2] == false and value.a[3] == Json.null, 'boolean/null array')
check(value.a[4] == -1.25 and value.a[5] == 2000, 'numbers')
check(value.text == '中文\n🚀', 'unicode')
check(Json.encode(value.empty) == '{}', 'empty object')
check(Json.encode(Json.decode('[]')) == '[]', 'empty decoded array')
check(Json.encode(Json.array()) == '[]', 'empty constructed array')
check(Json.encode({}) == '{}', 'default object')
check(Json.encode({b=2,a=1}) == '{"a":1,"b":2}', 'stable object ordering')
check(select('#', Json.encode(1.5)) == 1, 'scalar encode returns one value')
check(Json.decode(Json.encode({text='\0\1\b\t\n\f\r"\\/中文🚀'})).text == '\0\1\b\t\n\f\r"\\/中文🚀', 'string roundtrip')
check(Json.decode('"\\u0000"') == '\0', 'escaped NUL')
check(Json.decode('"\\uFFFF"') == '\239\191\191', 'BMP boundary')
check(Json.decode('"\\uDBFF\\uDFFF"') == '\244\143\191\191', 'unicode maximum')
check(Json.decode(' -0.0125e+2 \t\r\n') == -1.25, 'fraction exponent whitespace')
for _, source in ipairs({'',' ', '+1','01','-01','.1','1.','1e','1e+','1e999','NaN','Infinity','-Infinity',
    'true false','{}x','null0','[1,]','{"a":1,}','{a:1}',"{'a':1}",'/*x*/{}','{"a":1,"a":2}',
    '{"a":null,"a":null}','{"a":1,"\\u0061":2}','"\\x20"','"\\uD800"','"\\uDC00"',
    '"\\uD800\\u0041"','"\\u123"','"unterminated','"a\nb"','"\0"',
    '"\192\128"','"\237\160\128"','"\244\144\128\128"','"\240\128\128\128"','"\128"','"\226\130"'}) do rejects(source) end
rejects(string.rep('[', Json.MAX_DEPTH + 2)..'0'..string.rep(']', Json.MAX_DEPTH + 2))
for _, v in ipairs({math.huge, -math.huge, 0/0, function() end, {[2]='gap'}, {[1]='a', b='mixed'}, '\255'}) do
    check(not pcall(Json.encode, v), 'encoded invalid value')
end
local cycle = {}; cycle.self = cycle; check(not pcall(Json.encode, cycle), 'cycle rejected')
local deep = {}; local tail = deep
for _ = 1, Json.MAX_DEPTH + 2 do tail.child = {}; tail = tail.child end
check(not pcall(Json.encode, deep), 'deep encoding rejected')
-- Checklist A: the one shared dense/closed validator.
do
    local ok,count=Json.denseArray({1,2,3},1)
    check(ok==true and count==3,'a dense array is accepted with its length')
    local emptyOk,emptyCount=Json.denseArray({})
    check(emptyOk==true and emptyCount==0,'an empty array is dense (length 0)')
    local hole,holeCause=Json.denseArray({[1]='a',[3]='c'},1)
    check(hole==false and holeCause=='hole','a hole is rejected')
    local holeNil,holeNilCause=Json.denseArray({[1]='a',[2]=nil,[3]='c'},1)
    check(holeNil==false and holeNilCause=='hole','an explicit nil hole is rejected')
    local frac,fracCause=Json.denseArray({[1]='a',[1.5]='b'},1)
    check(frac==false and fracCause=='non_integer_key','a non-integer key is rejected')
    local str,strCause=Json.denseArray({[1]='a',oops='b'},1)
    check(str==false and strCause=='non_integer_key','a string key is rejected')
    local zero,zeroCause=Json.denseArray({[0]='a',[1]='b'},1)
    check(zero==false and zeroCause=='non_integer_key','a zero key is rejected')
    local negative,negativeCause=Json.denseArray({[-1]='a'},1)
    check(negative==false and negativeCause=='non_integer_key','a negative key is rejected')
    local short,shortCause=Json.denseArray({},1)
    check(short==false and shortCause=='too_short','a min-length violation is too_short')
    local nullOk,nullCause=Json.denseArray(Json.null,1)
    check(nullOk==false and nullCause=='not_array','json.null is not an array')
    local scalarOk,scalarCause=Json.denseArray('x',1)
    check(scalarOk==false and scalarCause=='not_array','a scalar is not an array')
end
print(('json: %d checks passed'):format(checks))
