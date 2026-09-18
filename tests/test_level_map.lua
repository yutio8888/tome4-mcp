-- Native explored-map projection tests (tome.map / level_map).
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
package.path=root..'/overload/?.lua;'..package.path
local LevelMap=require 'mod.mcp_bridge.LevelMap'
local Observer=require 'mod.mcp_bridge.Observer'
local Json=require 'mod.mcp_bridge.Json'
local count=0
local function check(value,message) count=count+1;assert(value,message) end

local nativeGrid=assert(loadstring('return function() return true end','@/mod/class/Grid.lua'))()

local function terrain(spec)
    local t={name=spec.name or 'floor',display=spec.display or '.',block_move=spec.block_move}
    if spec.change_level then t.change_level=true end
    if spec.change_zone then t.change_zone=true end
    if spec.door then t.block_move=nativeGrid;t.door_opened=true end
    return t
end
-- 5x5 dungeon. remembers/seens/infovs/lites are set per case.
local function fixture(w,h)
    w,h=w or 5,h or 5
    local map={w=w,h=h,TERRAIN=1,OBJECT=7,TRAP=4,ACTOR=3,
        map={},seens={},infovs={},lites={},remembers={},effects={}}
    for i=0,w*h-1 do map.map[i]={[1]=terrain{name='grass',block_move=false}} end
    local p={uid=1,x=2,y=2,blind=nil,open_door=true}
    local g={player=p,level={map=map},zone={wilderness=false}}
    return g,p,map
end
local meta={session_id='s1',level_instance_id='level-1',revision=7}

-- 1. remembered blocked terrain is projected even though it is not visible.
local g,p,map=fixture()
map.map[0+0*5][1]=terrain{name='tree',block_move=true}
map.remembers[0]=true
local cap=LevelMap.capture(g,meta,{})
check(cap.source=='native_map' and cap.w==5 and cap.h==5 and cap.format=='rows','rows capture exposes level metadata')
check(cap.rows[1].text:sub(1,1)=='#' and cap.coverage.y_min==0 and cap.capture_complete,'remembered blocked terrain is projected')
-- 2. an unremembered and unseen cell stays unknown.
check(cap.rows[5].text:sub(5,5)=='?','unexplored terrain stays unknown')
check(cap.explored_count==1,'explored count counts authorized cells')
check(cap.frontier_count>=1,'frontier counts unknown cells adjacent to known terrain')

-- 3. ESP-only seens does not disclose terrain (no infovs).
g,p,map=fixture()
map.seens[6]=true  -- x=1,y=1
check(LevelMap.capture(g,meta,{}).rows[2].text:sub(2,2)=='?','ESP-only seens does not reveal terrain')
-- 4. current safe visibility discloses terrain without native memory.
map.infovs[6]=true;map.lites[6]=true
check(LevelMap.capture(g,meta,{}).rows[2].text:sub(2,2)=='.','safely visible terrain is projected')

-- 5. known trap overrides terrain; an unknown trap does not.
g,p,map=fixture()
map.remembers[12]=true
map.map[12][4]={all_know=false,known_by={}}
check(LevelMap.capture(g,meta,{}).rows[3].text:sub(3,3)=='.','an unknown trap is not drawn')
map.map[12][4].known_by[p]=true
check(LevelMap.capture(g,meta,{}).rows[3].text:sub(3,3)=='!','an identified trap is drawn')

-- 6. items are drawn on remembered cells; actors are never drawn.
g,p,map=fixture()
map.remembers[12]=true
map.map[12][7]={name='sword'}
check(LevelMap.capture(g,meta,{}).rows[3].text:sub(3,3)=='%','an item is drawn on a remembered cell')
map.map[12][7]=nil
map.map[12][3]={name='orc',x=2,y=2}
check(LevelMap.capture(g,meta,{}).rows[3].text:sub(3,3)=='.','an actor is never drawn')

-- 7. alphabet priority: exit > door > trap > item > blocked/passable/unknown.
g,p,map=fixture()
map.remembers[6]=true
map.map[6][1]=terrain{name='stairs',block_move=true,change_level=true}
check(LevelMap.capture(g,meta,{}).rows[2].text:sub(2,2)=='>','an exit wins over a blocked cell')
map.map[6][1]=terrain{name='door',door=true}
check(LevelMap.capture(g,meta,{}).rows[2].text:sub(2,2)=='+','a known door is drawn')
map.map[6][7]={name='ring'}
check(LevelMap.capture(g,meta,{}).rows[2].text:sub(2,2)=='+','a door wins over an item')
map.map[6][1]=terrain{name='mystery'}
check(LevelMap.capture(g,meta,{}).rows[2].text:sub(2,2)=='%','an item wins over unknown terrain')
map.map[6][7]=nil;map.map[6][4]={known_by={[p]=true}}
check(LevelMap.capture(g,meta,{}).rows[2].text:sub(2,2)=='!','a trap wins over unknown terrain')
check(LevelMap.capture(g,meta,{}).legend['%']~=nil,'the alphabet legend is returned')

-- 8. a larger-than-vanilla map is returned partially and marked truncated.
g,p,map=fixture(200,100)
local big=LevelMap.capture(g,meta,{})
check(big.truncated and not big.capture_complete and big.truncation_reason=='map_scan_limit'
    and big.omitted_rows>0,'an oversized map is truncated with a reason')
check(big.coverage.y_min<=p.y and p.y<=big.coverage.y_max,'truncation keeps a band around the player')

-- 9. region detail: bounded rectangle with the full terrain projection.
g,p,map=fixture()
map.remembers[0]=true
local reg=LevelMap.region(g,meta,{x=0,y=0,width=2,height=2})
check(reg and #reg.cells==4 and reg.cells[1].x==0 and reg.cells[1].y==0,'region returns the requested rectangle')
check(reg.cells[1].remembered==true and reg.cells[4].remembered==false,'region reports per-cell knowledge')
local _,code=LevelMap.region(g,meta,{x=0,y=0,width=9,height=9})
check(code=='region_too_large','a region above the cell cap is rejected')
local _,code2=LevelMap.region(g,meta,{x=4,y=4,width=2,height=2})
check(code2=='region_out_of_bounds','an out-of-bounds region is rejected')

print('Level map: '..count..' checks passed')
