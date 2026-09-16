-- GPL-3.0-or-later. Read-only native explored-map projection (tome.map).
--
-- Mirrors the player's level-map rendering: remembered or safely visible
-- terrain, plus identified traps and items. It never renders out-of-sight
-- actors, never imports the bridge's own window memory, and never calls dynamic
-- getters, target/combat functions or markup. Terrain under a remembered cell is
-- the current native terrain, exactly as the map UI draws it.
local Json=require 'mod.mcp_bridge.Json'
local Observer=require 'mod.mcp_bridge.Observer'
local Details=require 'mod.mcp_bridge.ObservationDetails'
local M={}

-- Normalized, documented alphabet. Returned to clients as `legend`.
M.LEGEND={
    ['?']='unknown or not authorized (not remembered and not safely visible)',
    ['.']='passable terrain',
    ['#']='blocked terrain',
    ['+']='known door',
    ['>']='known exit (change level/zone label is visible)',
    [':']='terrain whose static block status is unknown',
    ['%']='item on the cell',
    ['!']='identified trap',
}
-- Vanilla maximum is sandworm-lair 350x50=17500 (wilderness 170x100=17000,
-- towns 196x80=15680). Larger maps are returned partially and marked truncated.
M.MAX_MAP_CELLS=17500
M.MAX_REGION_CELLS=64

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
local function integer(n,lo,hi) return finite(n) and n%1==0 and n>=lo and n<=hi end
local function active(v) return v~=nil and v~=false and v~=0 end

-- Trap knowledge without invoking an overridable method: the native
-- Trap:knownBy returns `all_know or known_by[actor]`.
local function trapKnown(trap,p)
    if type(trap)~='table' then return false end
    if trap.all_know then return true end
    local known=trap.known_by
    if type(known)~='table' then return false end
    return known[p] and true or false
end

-- One normalized character for a cell, following the agreed priority:
-- exit > door > trap > item > blocked/passable/unknown.
local function charAt(g,p,map,x,y,remembered)
    if not (remembered or Observer.terrainVisible(g,p,map,x,y)) then return '?' end
    local cell=map.map and map.map[x+y*map.w]
    if type(cell)~='table' then return '?' end
    local terrain=cell[map.TERRAIN or 1]
    local state=type(terrain)=='table' and Details.terrain(terrain,p) or {}
    if state.is_exit then return '>' end
    if state.door then return '+' end
    if trapKnown(cell[map.TRAP or 4],p) then return '!' end
    if cell[map.OBJECT or 7] then return '%' end
    if state.blocked==true then return '#' end
    if state.blocked==false then return '.' end
    return ':'
end

local function mapContext(g)
    local p=g and g.player
    local map=g and g.level and g.level.map
    if not p or not map or not finite(p.x) or not finite(p.y) then return nil end
    if not (integer(map.w,1,100000) and integer(map.h,1,100000)) then return nil end
    return p,map
end

-- Row-chunk projection of the whole explored level.
function M.capture(g,meta,options)
    local p,map=mapContext(g)
    if not p then return nil,'map_unavailable' end
    local w,h=map.w,map.h
    local total=w*h
    -- Vanilla-sized maps are returned whole. A larger (modded) map is returned
    -- as a band around the player and explicitly marked truncated.
    local truncated,y0,y1=false,0,h-1
    if total>M.MAX_MAP_CELLS then
        truncated=true
        local max_rows=math.max(1,math.min(h,math.floor(M.MAX_MAP_CELLS/w)))
        y0=math.max(0,math.min(h-max_rows,math.floor(p.y-max_rows/2)))
        y1=math.min(h-1,y0+max_rows-1)
    end
    local rows,explored=Json.array(),0
    local known={}
    for y=y0,y1 do
        local parts={}
        for x=0,w-1 do
            local index=x+y*w
            local remembered=active(map.remembers and map.remembers[index])
            local char=charAt(g,p,map,x,y,remembered)
            if char~='?' then explored=explored+1;known[index]=true end
            parts[#parts+1]=char
        end
        rows[#rows+1]={y=y,x_start=0,text=table.concat(parts)}
    end
    -- Frontier = unknown cells adjacent to a known cell: the useful "where can I
    -- still explore" signal that avoids oscillation between two far cells.
    local frontier=0
    for y=math.max(0,y0-1),math.min(h-1,y1+1) do
        for x=0,w-1 do
            local index=x+y*w
            if not known[index] then
                local adjacent=false
                for dx=-1,1 do
                    for dy=-1,1 do
                        if not (dx==0 and dy==0) then
                            local nx,ny=x+dx,y+dy
                            if nx>=0 and ny>=0 and nx<w and ny<h and known[nx+ny*w] then adjacent=true end
                        end
                    end
                end
                if adjacent then frontier=frontier+1 end
            end
        end
    end
    return {session_id=meta.session_id,level_instance_id=meta.level_instance_id,
        captured_revision=meta.revision,current_revision=meta.revision,historical=false,
        source='native_map',format='rows',w=w,h=h,origin={x=0,y=0},player={x=p.x,y=p.y},
        explored_count=explored,frontier_count=frontier,
        frontier_scope='unknown cells adjacent to a known cell; the frontier is the useful exploration target',
        terrain_scope='remembered or safely visible terrain plus identified traps and items; '
            ..'no actors, destinations, attributes or callbacks',
        legend=M.LEGEND,rows=rows,returned_rows=#rows,
        coverage={x_min=0,x_max=w-1,y_min=y0,y_max=y1},
        capture_complete=not truncated,
        truncated=truncated or nil,
        truncation_reason=truncated and 'map_scan_limit' or nil,
        omitted_rows=truncated and (h-(y1-y0+1)) or nil}
end

-- Bounded rectangle of detailed terrain cells (at most MAX_REGION_CELLS).
function M.region(g,meta,request)
    local p,map=mapContext(g)
    if not p then return nil,'map_unavailable' end
    local x,y,w,h=request.x,request.y,request.width,request.height
    if not (integer(x,0,2147483647) and integer(y,0,2147483647)
        and integer(w,1,M.MAX_REGION_CELLS) and integer(h,1,M.MAX_REGION_CELLS)) then
        return nil,'invalid_region'
    end
    if w*h>M.MAX_REGION_CELLS then return nil,'region_too_large' end
    if x+w>map.w or y+h>map.h then return nil,'region_out_of_bounds' end
    local cells=Json.array()
    for yy=y,y+h-1 do
        for xx=x,x+w-1 do
            local index=xx+yy*map.w
            local remembered=active(map.remembers and map.remembers[index])
            local visible=Observer.terrainVisible(g,p,map,xx,yy)
            local cell=map.map and map.map[index]
            local entry={x=xx,y=yy,remembered=remembered,visible=visible}
            if (remembered or visible) and type(cell)=='table' then
                local terrain=cell[map.TERRAIN or 1]
                local state=type(terrain)=='table' and Details.terrain(terrain,p) or nil
                if state then for k,v in pairs(state) do entry[k]=v end end
                entry.char=charAt(g,p,map,xx,yy,remembered)
                entry.known_trap=trapKnown(cell[map.TRAP or 4],p) or nil
                entry.item=cell[map.OBJECT or 7] and true or nil
            end
            cells[#cells+1]=entry
        end
    end
    return {session_id=meta.session_id,level_instance_id=meta.level_instance_id,
        captured_revision=meta.revision,current_revision=meta.revision,historical=false,
        source='native_map',format='region',cells=cells,returned_cells=#cells,
        terrain_scope='remembered or safely visible terrain plus identified traps and items; '
            ..'no actors, destinations, attributes or callbacks',
        legend=M.LEGEND,capture_complete=true}
end
return M
