-- GPL-3.0-or-later. Native-equivalent effect footprints for the v2 manifest.
--
-- Two backends share one interface:
--
--   * `M.model` is a pure, engine-free grid expansion used by unit tests and
--     by headless dry fixtures. It follows the documented T-Engine semantics:
--     a line starts after the origin, a bolt stops on the first blocking grid,
--     a beam collects every traversed grid, a ball is the radius around the
--     stop/radius center, a widebeam is the union of radius circles around the
--     travelled path, and a cone is the apex wedge.
--   * `M.native` mirrors `ActorProject:project`'s grid collection exactly and
--     delegates the radius/line geometry to the audited native `core.fov`
--     helpers. It never installs a damage projector and never calls an action
--     entrypoint; the probe validates it against a real `project` recording.
--
-- Coverage is deliberately limited to the audited native shapes. Anything else
-- returns `nil` and the caller fails closed.
local Distance=require 'mod.mcp_bridge.Distance'
local M={}

local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end

-- A grid set is `{[x]={[y]=true}}`. `M.at(hits,x,y)` is the membership test.
function M.newSet()
    local set={}
    local function add(x,y)
        if not finite(x) or not finite(y) then return end
        local column=set[x]
        if not column then column={};set[x]=column end
        column[y]=true
    end
    return set,add
end

function M.at(set,x,y)
    return set~=nil and set[x]~=nil and set[x][y]==true
end

function M.count(set)
    local total=0
    for _,column in pairs(set or {}) do
        for _ in pairs(column) do total=total+1 end
    end
    return total
end

-- Integer grid line from (sx,sy) to (tx,ty), excluding the origin. Mirrors a
-- Bresenham walk; a 45-degree tie picks the diagonal step first, matching the
-- engine's cardinal tie-break for the deterministic fixtures below.
function M.line(sx,sy,tx,ty)
    local points={}
    local dx,dy=math.abs(tx-sx),math.abs(ty-sy)
    local x,y=sx,sy
    local n=math.max(dx,dy)
    if n==0 then return points end
    local xinc=sx<tx and 1 or (sx>tx and -1 or 0)
    local yinc=sy<ty and 1 or (sy>ty and -1 or 0)
    local err=dx-dy
    for _=1,n do
        local e2=2*err
        if e2>-dy then err=err-dy;x=x+xinc end
        if e2<dx then err=err+dx;y=y+yinc end
        points[#points+1]={x=x,y=y}
    end
    return points
end

local function blockAt(blockOpts,x,y)
    if blockOpts and blockOpts.blockPath and blockOpts.blockPath(x,y) then return true end
    return false
end

local function walkLine(spec,blockOpts)
    local sx,sy=spec.origin.x,spec.origin.y
    local tx,ty=spec.target.x,spec.target.y
    local stop_x,stop_y=sx,sy
    local collected={}
    local radius_x,radius_y=sx,sy
    for _,point in ipairs(M.line(sx,sy,tx,ty)) do
        if finite(spec.range) and Distance.grid(sx,sy,point.x,point.y)>spec.range then break end
        local blocked=blockAt(blockOpts,point.x,point.y)
        stop_x,stop_y=point.x,point.y
        radius_x,radius_y=point.x,point.y
        collected[#collected+1]=point
        if blocked then break end
    end
    return stop_x,stop_y,radius_x,radius_y,collected
end

local function addCircle(add,center,radius,opts)
    local r=finite(radius) and radius or 0
    if r<=0 then add(center.x,center.y);return end
    local rl=math.floor(r)
    for dx=-rl,rl do
        for dy=-rl,rl do
            local x,y=center.x+dx,center.y+dy
            if Distance.grid(center.x,center.y,x,y)<=r and not (opts.blockRadius and opts.blockRadius(x,y)) then
                add(x,y)
            end
        end
    end
    add(center.x,center.y)
end

-- Pure expansion. `opts.blockPath(x,y)` / `opts.blockRadius(x,y)` return true
-- for a grid that blocks. `origin`/`target` are `{x,y}`. Returns a grid set or
-- nil for an unsupported shape.
function M.model(spec,opts)
    if spec==nil then return nil end
    local set,add=M.newSet()
    local shape=spec.shape
    if shape=='self' or shape=='hit' then
        add(spec.target.x,spec.target.y)
        return set
    end
    -- Melee deliveries never build an ActorProject footprint.
    if shape=='melee' then
        add(spec.target.x,spec.target.y)
        return set
    end
    local stop_x,stop_y,radius_x,radius_y,collected=walkLine(spec,opts or {})
    local single=true
    if (shape=='ball') and finite(spec.radius) and spec.radius>0 then
        single=false
        addCircle(add,{x=radius_x,y=radius_y},spec.radius,opts or {})
        add(stop_x,stop_y)
    end
    if (shape=='beam') then
        single=false
        for _,point in ipairs(collected) do add(point.x,point.y) end
    end
    if (shape=='widebeam') and finite(spec.radius) and spec.radius>0 then
        single=false
        addCircle(add,{x=stop_x,y=stop_y},spec.radius,opts or {})
        local radius=spec.radius
        for _,point in ipairs(collected) do
            addCircle(add,point,radius,opts or {})
        end
        add(stop_x,stop_y)
    end
    if (shape=='cone') and finite(spec.radius) and spec.radius>0 then
        single=false
        local dist=Distance.grid(spec.origin.x,spec.origin.y,stop_x,stop_y)
        local dx,dy=stop_x-spec.origin.x,stop_y-spec.origin.y
        local length=math.sqrt(dx*dx+dy*dy)
        if length>0 then
            local ux,uy=dx/length,dy/length
            local half=math.tan(math.rad(55/2))
            for x=spec.origin.x-spec.radius,spec.origin.x+spec.radius do
                for y=spec.origin.y-spec.radius,spec.origin.y+spec.radius do
                    local px,py=x-spec.origin.x,y-spec.origin.y
                    local len=math.sqrt(px*px+py*py)
                    if len<=spec.radius and (len==0 or (px*ux+py*uy)/len>=1/math.sqrt(1+half*half)) then
                        add(x,y)
                    end
                end
            end
        end
        add(stop_x,stop_y)
        add(spec.origin.x,spec.origin.y)
    end
    if shape=='bolt' then
        single=true
    elseif shape~='ball' and shape~='beam' and shape~='widebeam' and shape~='cone' then
        return nil
    end
    if single then add(stop_x,stop_y) end
    if not finite(stop_x) or not finite(stop_y) then return nil end
    return set
end

-- Native expansion. Mirrors ActorProject:project's grid collection (lines
-- 44-200 of the inspected engine) and delegates radius/line geometry to
-- `core.fov`. `ctx` = {game=, source=}. Never calls a damage projector or a
-- talent/action entrypoint.
local function nativeDeps()
    local ok,Target=pcall(require,'engine.Target')
    if not ok or type(Target)~='table' or type(core)~='table' or type(core.fov)~='table' then return nil end
    return Target
end

function M.native(ctx,spec)
    if type(ctx)~='table' or type(ctx.game)~='table' then return nil end
    local g=ctx.game
    local map=g.level and g.level.map
    local source=ctx.source or (g.player)
    if not map or not source then return nil end
    local Target=nativeDeps()
    if not Target then return nil end
    local typ
    local typeSpec=spec
    if typeSpec.type==nil and typeSpec.shape~=nil then
        typeSpec={}
        for key,value in pairs(spec) do typeSpec[key]=value end
        typeSpec.type=spec.shape
    end
    local ok,value=pcall(Target.getType,Target,typeSpec)
    if not ok or type(value)~='table' then return nil end
    typ=value
    typ.source_actor=source
    typ.start_x=typ.start_x or typ.x or (source and source.x) or 0
    typ.start_y=typ.start_y or typ.y or (source and source.y) or 0
    local tx,ty=spec.target.x,spec.target.y
    local set,add=M.newSet()
    local function addGrid(x,y)
        if typ.filter and not typ.filter(x,y) then return end
        add(x,y)
    end
    local stop_x,stop_y=typ.start_x,typ.start_y
    local stop_radius_x,stop_radius_y=typ.start_x,typ.start_y
    local line,is_corner_blocked
    local line_ok
    if source.lineFOV and source.x and source.y then
        line_ok,line=pcall(source.lineFOV,source,tx,ty,nil,nil,typ.start_x,typ.start_y)
    else
        line_ok,line=pcall(core.fov.line,typ.start_x,typ.start_y,tx,ty)
    end
    if not line_ok or type(line)~='table' then return nil end
    local block_corner
    if typ.block_path then
        block_corner=function(_,bx,by)
            local b,h,hr=typ:block_path(bx,by,true)
            return b and h and not hr
        end
    else
        block_corner=function() return false end
    end
    local set_corner_ok=pcall(function() line:set_corner_block(block_corner) end)
    if not set_corner_ok then return nil end
    local lx,ly,blocked_corner_x,blocked_corner_y=line:step(typ.force_max_range)
    if blocked_corner_x and map:isBound(blocked_corner_x,blocked_corner_y) then
        stop_x,stop_y=blocked_corner_x,blocked_corner_y
        if typ.line then addGrid(blocked_corner_x,blocked_corner_y) end
    else
        while lx and ly do
            local block,hit,hit_radius=false,true,true
            if is_corner_blocked then
                block,hit,hit_radius=true,true,false
                lx=stop_radius_x;ly=stop_radius_y
            elseif typ.block_path then
                block,hit,hit_radius=typ:block_path(lx,ly)
            end
            if hit then
                stop_x,stop_y=lx,ly
                if typ.line then addGrid(lx,ly) end
            end
            if hit_radius then stop_radius_x,stop_radius_y=lx,ly end
            if block then break end
            lx,ly,is_corner_blocked=line:step(typ.force_max_range)
            if typ.force_max_range and core.fov.distance(typ.start_x,typ.start_y,lx,ly)>typ.range then break end
        end
    end
    local single=true
    if typ.ball and typ.ball>0 then
        single=false
        core.fov.calc_circle(stop_radius_x,stop_radius_y,map.w,map.h,typ.ball,
            function(_,px,py) if typ.block_radius and typ:block_radius(px,py) then return true end end,
            function(_,px,py) addGrid(px,py) end,nil)
        addGrid(stop_x,stop_y)
    end
    if typ.triangle then return nil end
    if typ.widebeam and typ.widebeam>0 then
        single=false
        core.fov.calc_wide_beam(stop_radius_x,stop_radius_y,map.w,map.h,typ.start_x,typ.start_y,typ.widebeam,
            function(_,px,py) if typ.block_radius and typ:block_radius(px,py) then return true end end,
            function(_,px,py) addGrid(px,py) end,nil)
        addGrid(stop_x,stop_y)
    end
    if typ.cone and typ.cone>0 then
        single=false
        core.fov.calc_beam_any_angle(stop_radius_x,stop_radius_y,map.w,map.h,typ.cone,typ.cone_angle,
            typ.start_x,typ.start_y,tx-typ.start_x,ty-typ.start_y,
            function(_,px,py) if typ.block_radius and typ:block_radius(px,py) then return true end end,
            function(_,px,py) addGrid(px,py) end,nil)
        addGrid(stop_x,stop_y)
    end
    if typ.wall and typ.wall>0 then return nil end
    if single then addGrid(stop_x,stop_y) end
    if typ.min_range and core.fov.distance(typ.start_x,typ.start_y,stop_x,stop_y)<typ.min_range then
        return M.newSet()
    end
    if typ.grid_exclude then
        for px,columns in pairs(typ.grid_exclude) do
            if set[px] then for py in pairs(columns) do set[px][py]=nil end end
        end
    end
    return set
end

-- Choose the native backend when the engine geometry is available, else the
-- pure model. `opts.native` is the {game=,source=} context.
function M.expand(spec,opts)
    if type(opts)=='table' and opts.native then
        local set=M.native(opts.native,spec)
        if set~=nil then return set,'native' end
    end
    local set=M.model(spec,opts)
    if set~=nil then return set,'model' end
    return nil,'unsupported'
end

return M
