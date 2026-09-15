-- GPL-3.0-or-later. Coroutine ownership is process-local, never actor save data.
local M={}
local MAIN={}
local contexts={}
local roots={}
local listener
local function thread() return coroutine.running() or MAIN end
local function pack(...) return {n=select('#',...),...} end
local function changed(root) if listener then listener(root) end end

function M.reset(callback)
    contexts={};roots={};listener=callback
end
function M.current() return contexts[thread()] end
function M.forCoroutine(co) return contexts[co] end
function M.root(node) return node and node.root end

function M.error(root,message)
    if not root or root.error then return end
    root.error=tostring(message):sub(1,2048)
    changed(root)
end

function M.scope(node,fn,...)
    local key=thread()
    local previous=contexts[key]
    contexts[key]=node
    local result=pack(pcall(fn,...))
    contexts[key]=previous
    if not result[1] then
        M.error(node and node.root,result[2])
        error(result[2],0)
    end
    return unpack(result,2,result.n)
end

local function finish(node,ret,err)
    if node.done then return end
    node.done=true;node.result=ret and true or false
    if node.item_call then node.result=node.item_used==true end
    local root=node.root
    root.pending=root.pending-1
    if root.primary==node then root.native_return=node.result end
    if err then M.error(root,err) end
    root.done=root.entry_done and root.pending==0 or false
    changed(root)
end

-- Called only by the generated native useTalent seam, for its BODY coroutine.
-- The native wrapper coroutine and every native resume call remain unchanged.
function M.createBody(fn)
    local node=M.current()
    if not node then return coroutine.create(fn) end
    node.has_body=true
    local co=coroutine.create(function(...)
        local args=pack(...)
        local result=pack(xpcall(function() return fn(unpack(args,1,args.n)) end,debug.traceback))
        if result[1] then finish(node,result[2]) else finish(node,false,result[2]) end
        contexts[coroutine.running()]=nil
        if not result[1] then error(result[2],0) end
        return unpack(result,2,result.n)
    end)
    contexts[co]=node
    return co
end

function M.call(player,id,fn,...)
    local parent=M.current()
    if not parent then return fn(player,id,...) end
    local root=parent.root
    local node={root=root,parent=parent,player=player,talent_id=id}
    -- The native item coroutine has no talent ID and returns nil on success;
    -- playerUseObject supplies its authoritative used result separately.
    if id==false then node.item_call=true;node.item_used=false end
    root.done=false
    root.pending=root.pending+1
    root.primary=root.primary or node
    local args=pack(...)
    local result=pack(pcall(M.scope,node,fn,player,id,unpack(args,1,args.n)))
    -- Cooldown rejection (or an invalid mode) returns before creating a body.
    if not node.has_body then finish(node,result[1] and result[2],not result[1] and result[2] or nil) end
    if not result[1] then error(result[2],0) end
    return unpack(result,2,result.n)
end

function M.itemResult(player,result)
    local node=M.current()
    if node and node.item_call and node.player==player then node.item_used=result and result.used and true or false end
end
function M.callItem(player,fn,...) return M.call(player,false,fn,...) end

local function start(g,command,fn,talent)
    local root={game=g,player=g.player,level=g.level,command=command,pending=0,done=false,
        result_from_talent=talent or false}
    root.root=root
    roots[root]=true
    command.invocation=root
    changed(root)
    local result=pack(pcall(M.scope,root,fn))
    root.entry_done=true
    root.done=root.pending==0
    if talent and not root.primary then
        M.error(root,result[1] and 'Native talent lifecycle was not entered.' or result[2])
    end
    if not result[1] then M.error(root,result[2]);error(result[2],0) end
    return root,unpack(result,2,result.n)
end

function M.startAction(g,command,fn) return start(g,command,fn,false) end
function M.start(g,command,fn)
    local owner=M.current()
    if owner and owner.root.command==command then
        local root=owner.root
        root.result_from_talent=true
        return root,fn()
    end
    return start(g,command,fn,true)
end

-- Native tick-end scheduling still decides order, deduplication and rescheduling.
-- Ownership follows only callbacks registered inside this command's native call.
-- Readiness already waits for that native queue to drain before releasing a root.
function M.callback(g,fn,owner)
    owner=owner or M.current()
    if not owner or owner.root.game~=g then return fn end
    local level=g.level
    return function(...)
        local root=owner.root
        if not root.command or root.player~=g.player or level~=g.level
            or root.level~=g.level and not root.transitioning then return fn(...) end
        return M.scope(owner,fn,...)
    end
end

function M.release(root)
    roots[root]=nil
    for key,node in pairs(contexts) do if node.root==root then contexts[key]=nil end end
    root.player,root.level,root.game,root.command,root.primary=nil,nil,nil,nil,nil
end
return M
