-- V2-4: composed component risk (self/friendly/projectile/ground).
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
local Risk=require 'mod.auto_combat.EffectRisk'
local checks=0
local function check(value,message) checks=checks+1;assert(value,message) end

-- Normalization --------------------------------------------------------------
check(Risk.flag(true)==100 and Risk.flag(false)==0,'booleans normalize to 0/100')
check(Risk.flag(37)==37,'finite percentages are preserved')
check(Risk.flag(150)==100 and Risk.flag(-4)==0,'percentages are clamped')
check(Risk.flag('unknown')=='unknown' and Risk.flag(nil)=='unknown','unknown stays unknown')
check(Risk.flag(0/0)=='unknown','non-finite values are unknown')

local function comp(overrides)
    local c={id='c',phase='instant',delivery='project',selffire=100,friendlyfire=100}
    for k,v in pairs(overrides or {}) do c[k]=v end
    return c
end
local function membership(overrides)
    local m={self=false,friendlies=0,player_override=false}
    for k,v in pairs(overrides or {}) do m[k]=v end
    return m
end

-- Self requires containment AND both filters ---------------------------------
check(Risk.component(comp(),membership{self=true})~=nil,'self in footprint with defaults is risk')
check(Risk.component(comp(),membership{self=true,friendlies=0},nil)~=nil,'self risk is reported')
check(Risk.component(comp{selffire=0},membership{self=true})==nil,'selffire=0 removes self risk')
check(Risk.component(comp{friendlyfire=0},membership{self=true})==nil,'friendlyfire=0 removes self risk')
check(Risk.component(comp(),membership{self=false})==nil,'self outside the footprint is safe')
local unknownSelf=Risk.component(comp(),membership{self='unknown'})
check(unknownSelf~=nil and unknownSelf.risk=='self','unknown containment fails closed when filters are positive')

-- Friendly requires only friendlyfire ----------------------------------------
local ally=Risk.component(comp(),membership{friendlies=1})
check(ally~=nil and ally.risk=='friendly','an ally in an FF-positive footprint is risk')
check(Risk.component(comp{friendlyfire=0},membership{friendlies=1})==nil,'FF=0 protects allies')
check(Risk.component(comp(),membership{friendlies='unknown'})~=nil,'unknown friendly occupancy fails closed')

-- Projectile self opt-in is projectile-only ----------------------------------
local projectile=comp{phase='projectile',delivery='projectile',player_selffire=false}
check(Risk.component(projectile,membership{self=true,player_override=false})==nil,
    'a player projectile without the opt-in cannot self-hit')
check(Risk.component(projectile,membership{self=true,player_override=true})~=nil,
    'the player opt-in restores the projectile self-hit')
check(Risk.component(projectile,membership{friendlies=1,player_override=false})~=nil,
    'the projectile opt-in does not protect allies')
-- A direct projection ignores the projectile opt-in.
check(Risk.component(comp{delivery='project'},membership{self=true,player_override=false})~=nil,
    'direct projections ignore the player self opt-in')

-- Persistent ground is future risk even when currently empty ------------------
local ground=comp{phase='ground',delivery='map_effect'}
local detail=Risk.component(ground,membership{self=false,friendlies=0})
check(detail~=nil and detail.phase=='ground' and detail.risk=='self',
    'a positive-SF ground zone rejects even with an empty footprint')
check(Risk.component(comp{phase='ground',delivery='map_effect',selffire=0,friendlyfire=0},membership{})==nil,
    'a fully safe ground zone passes')
check(Risk.component(comp{phase='ground',delivery='map_effect',selffire=100,friendlyfire=0},membership{})==nil,
    'a ground zone with SF=100/FF=0 is safe for self and allies')
check(Risk.component(comp{phase='ground',delivery='map_effect',selffire=0},membership{})~=nil,
    'a positive-FF ground zone rejects even with an empty footprint')
check(Risk.component(comp{phase='ground',delivery='map_effect',selffire='unknown'},membership{})~=nil,
    'an unknown-SF ground zone rejects')
check(Risk.component(comp{phase='ground',delivery='map_effect',selffire=0,friendlyfire='unknown'},membership{})~=nil,
    'an unknown-FF ground zone rejects')

-- Cursor components never add damage risk; melee skips projection filters.
check(Risk.component(comp{phase='cursor'},membership{self=true,friendlies=5})==nil,
    'a cursor component carries no damage risk')
check(Risk.component(comp{phase='melee',delivery='attackTarget'},membership{self=true,friendlies=5})==nil,
    'a melee component skips the projection filters')

-- Whole-list evaluation ------------------------------------------------------
do
    local components={comp{id='a',selffire=0,friendlyfire=0},comp{id='b',phase='ground',selffire='unknown'}}
    local memberships={a=membership{self=true},b=membership{}}
    local safe,why=Risk.evaluate(components,memberships)
    check(safe==nil and why.phase=='ground','evaluation reports the persistent ground risk')
    local ok=Risk.evaluate({comp{id='safe',selffire=0,friendlyfire=0}},{safe=membership{self=true,friendlies=3}})
    check(ok==true,'evaluation passes a fully safe component list')
end

-- Composition of a player projectile and a ground component ------------------
do
    local components={
        comp{id='shot',phase='projectile',delivery='projectile',player_selffire=false,selffire=100,friendlyfire=0},
        comp{id='zone',phase='ground',delivery='map_effect',selffire=0,friendlyfire=100},
    }
    local safe,why=Risk.evaluate(components,{shot=membership{self=true,player_override=false},zone=membership{}})
    check(safe==nil and why.component=='zone','the ground component still rejects after the projectile is safe')
end

print('Effect risk: '..checks..' checks passed')
