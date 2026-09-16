-- GPL-3.0-or-later. Single audited grid-distance definition (spec QRY-08).
--
-- Query and execution must use the same distance rule. The engine primitive
-- core.fov.distance is used when present; tests and headless fixtures fall back
-- to the documented Chebyshev grid distance. No caller may define its own.
local M={}
function M.grid(ax,ay,bx,by)
    if core and core.fov and type(core.fov.distance)=='function' then
        return core.fov.distance(ax,ay,bx,by)
    end
    return math.max(math.abs(ax-bx),math.abs(ay-by))
end
return M
