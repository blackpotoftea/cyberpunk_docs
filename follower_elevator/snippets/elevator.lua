--[[
elevator.lua -- followers ride the lift with V, by mounting them to the lift entity.

Reference implementation for ../README.md. Distilled from a working build; syntax-checked only in
this form. Port it, do not paste it.

Wire-up:
    local Elevator = require('elevator')
    Elevator.Init{
        followers    = function() return { [id] = npc, ... } end,  -- who is following V now
        stopFollow   = function(npc) return cleared end,  -- take them off follow; true if the role went
        resumeFollow = function(npc, cleared) end,        -- give it back (only if `cleared`)
        warpBehindV  = function(npc) end,                 -- behind V, at V's Z
        canRide      = function(npc, id) return nil end,  -- a refusal string, or nil (README §6)
        isLive       = function() return true end,        -- your "gameplay is up" gate
    }
    Elevator.registerHooks()           -- in onInit
    Elevator.Tick(dt)                  -- in onUpdate, behind your session gate
    Elevator.Forget()                  -- on session end; touches no engine
]]

local Elevator = {}

local SWEEP_S     = 0.25   -- boarding is a window, not an edge
local WITH_V_M    = 25.0   -- "travelling with V" while the doors are open
local IN_CABIN_M  = 3.0    -- once it moves: only somebody already in the cabin
local STEP_IN_M   = 0.75   -- from V towards the cabin centre
local SPREAD_M    = 0.55   -- lateral spacing between riders

local deps = {}
-- Entity ids only, never handles: a stored handle can outlive its world (README §7).
local riders = {}          -- id -> { eid, liftEid, cleared, phase, moved, unmounted }
local inside, liftEid = false, nil
local sweepIn, closed = 0.0, false
local failed, said = {}, {}

function Elevator.Init(d) for k, v in pairs(d or {}) do deps[k] = v end end

local function eidKey(e)
    local s
    pcall(function() s = tostring(e:GetEntityID().hash):gsub('ULL$', '') end)
    return s
end

local function resolve(eid)
    if not eid then return nil end
    local e
    pcall(function() e = Game.FindEntityByID(eid) end)
    if IsDefined(e) then return e end
    return nil
end

local function mountInfo(npc, lift)
    local info    = MountingInfo.new()
    info.childId  = npc:GetEntityID()
    info.parentId = lift:GetEntityID()
    info.slotId   = MountingSlotId.new()          -- no slot: all 47 vanilla attachments pass None
    return info
end

local function mount(npc, lift)
    local ok, err = pcall(function()
        local req = MountingRequest.new()
        req.lowLevelMountingInfo = mountInfo(npc, lift)
        req.preservePositionAfterMounting = true
        Game.GetMountingFacility():Mount(req)
    end)
    if not ok then print('[lift] mount would not send: ' .. tostring(err)) end
    return ok
end

local function unmount(npc, lift)
    local ok, err = pcall(function()
        local req = UnmountingRequest.new()
        req.lowLevelMountingInfo = mountInfo(npc, lift)
        Game.GetMountingFacility():Unmount(req)
    end)
    if not ok then print('[lift] unmount would not send: ' .. tostring(err)) end
    return ok
end

-- (mounted, known): a failed read is not "not mounted".
local function isMounted(npc)
    local on
    local ok = pcall(function() on = Game.GetMountingFacility():IsMountedToAnything(npc:GetEntityID()) end)
    if not ok or on == nil then return false, false end
    return on == true, true
end

local function teleport(npc, pos, yaw)
    local cmd = AITeleportCommand.new()
    cmd.position, cmd.rotation = pos, yaw
    cmd.doNavTest = false                         -- the cabin floor has no navmesh
    npc:GetAIControllerComponent():SendCommand(cmd)
end

-- Step from V towards the lift's own position (the cabin centre), spread sideways by slot index.
local function spotInCabin(pp, lift, index)
    local dest, yaw
    pcall(function()
        local c = lift:GetWorldPosition()
        local dx, dy = c.x - pp.x, c.y - pp.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 0.1 then dx, dy, len = 1.0, 0.0, 1.0 end
        local ux, uy = dx / len, dy / len
        local side = ((index - 1) % 2 == 0) and 1 or -1
        local lat  = side * SPREAD_M * (math.floor((index - 1) / 2) + 1)
        dest = Vector4.new(pp.x + ux * STEP_IN_M - uy * lat, pp.y + uy * STEP_IN_M + ux * lat, pp.z, 1.0)
        yaw  = math.deg(math.atan2(-(pp.x - dest.x), pp.y - dest.y))   -- facing V; 0 = +Y. LuaJIT atan2
    end)
    return dest, yaw
end

local function refuse(id, why)
    if said[id] ~= why then said[id] = why; print(('[lift] %s not riding -- %s'):format(id, why)) end
end

local function tryBoard(id, npc, lift, pp, index, moving)
    if failed[id] then return false end
    local why = deps.canRide and deps.canRide(npc, id)
    if why then refuse(id, why); return false end

    local far
    local ok = pcall(function()
        local p = npc:GetWorldPosition()
        local dx, dy, dz = p.x - pp.x, p.y - pp.y, p.z - pp.z
        far = math.sqrt(dx * dx + dy * dy + dz * dz) > (moving and IN_CABIN_M or WITH_V_M)   -- 3D
    end)
    if not ok or far == nil then refuse(id, 'could not read where they are'); return false end
    if far then refuse(id, moving and 'not in the cabin, and it has left' or 'too far away'); return false end

    local cleared = deps.stopFollow(npc)
    local dest, yaw = spotInCabin(pp, lift, index)
    if dest then pcall(teleport, npc, dest, yaw) end   -- place first: after the mount it fights it

    if not mount(npc, lift) then
        deps.resumeFollow(npc, cleared)
        failed[id] = true                         -- once per visit, not at 4 Hz
        return false
    end
    riders[id] = { eid = npc:GetEntityID(), liftEid = lift:GetEntityID(), cleared = cleared,
                   phase = 'mounting', moved = false, unmounted = false }
    said[id] = nil
    print(('[lift] %s riding with V.'):format(id))
    return true
end

local function release(id, row, npc)
    local lift = resolve(row.liftEid)
    if not row.unmounted and lift then unmount(npc, lift) end
    deps.warpBehindV(npc)                         -- off the cabin floor, onto V's
    deps.resumeFollow(npc, row.cleared)
    riders[id] = nil
    print(('[lift] %s off the lift -- following again.'):format(id))
end

-- A body this module has filed as riding: your follow upkeep must leave it alone.
function Elevator.IsRiding(id) return riders[id] ~= nil end

function Elevator.OnEnter(lift, who)
    local isPlayer = false
    pcall(function() isPlayer = who:IsPlayer() end)
    if not isPlayer or not IsDefined(lift) then return end
    inside, liftEid, sweepIn, closed = true, lift:GetEntityID(), 0.0, false
    failed, said = {}, {}
end

-- `isDetach` is explicit: a nil activator may be a failed unwrap, not V.
function Elevator.OnExit(lift, who, isDetach)
    local isPlayer = isDetach == true
    if not isPlayer and who ~= nil then pcall(function() isPlayer = who:IsPlayer() end) end
    if not isPlayer then return end
    -- Ids, never handles; only two readable, different ids may ignore the exit.
    local held = resolve(liftEid)
    local a, b = held and eidKey(held), IsDefined(lift) and eidKey(lift)
    if a and b and a ~= b then return end
    print('[lift] V is out of the cabin (' .. (isDetach and 'detach' or 'area exit') .. ')')
    inside, liftEid, said = false, nil, {}
end

-- (inside, moving, lift), or nil for "could not ask" -- never read nil as "V left".
local function state()
    if not inside then return false, false, nil end
    local lift = resolve(liftEid)
    if not lift then return false, false, nil end
    local mode
    if not pcall(function() mode = lift:GetMovingMode() end) or mode == nil then return nil end
    return true, mode ~= 0, lift
end

function Elevator.Tick(dt)
    if not inside and next(riders) == nil then return end   -- the common path: no game call
    local isIn, moving, lift = state()
    if isIn == nil then return end

    if isIn and not closed then
        sweepIn = sweepIn - (tonumber(dt) or 0)
        if sweepIn <= 0 then
            sweepIn = SWEEP_S
            local pp
            if pcall(function() pp = Game.GetPlayer():GetWorldPosition() end) then
                local index = 0
                for _ in pairs(riders) do index = index + 1 end   -- count who is already aboard
                for id, npc in pairs(deps.followers()) do
                    if not riders[id] and tryBoard(id, npc, lift, pp, index + 1, moving) then
                        index = index + 1
                    end
                end
            end
        end
    end

    for id, row in pairs(riders) do
        local npc = resolve(row.eid)
        if not npc then
            riders[id] = nil                       -- body gone; nothing to unmount
        else
            if row.phase == 'mounting' then
                local on, known = isMounted(npc)
                if known and on then row.phase = 'riding' end   -- promote on the facility's answer
            end
            if row.phase == 'riding' then
                if moving then row.moved = true end
                -- HAS MOVED and IS STOPPED: a cabin V just stepped into is stopped too.
                if row.moved and not moving and not row.unmounted then
                    local l = resolve(row.liftEid)
                    if l then row.unmounted = unmount(npc, l) end
                end
                -- V picked another floor from inside the cabin.
                if row.unmounted and moving then
                    local l = resolve(row.liftEid)
                    if l and mount(npc, l) then row.unmounted, row.moved = false, true end
                end
            end
            if not isIn then release(id, row, npc) end   -- follow resumes only once V is out
        end
    end
    if not isIn then inside, liftEid = false, nil end
end

-- Live world: everyone off now, and nobody re-boards this visit.
function Elevator.ReleaseAll()
    for id, row in pairs(riders) do
        local npc = resolve(row.eid)
        if npc then release(id, row, npc) else riders[id] = nil end
    end
    closed, sweepIn, said = true, 0.0, {}
end

-- Session ending: clear state, touch no engine.
function Elevator.Forget()
    riders, inside, liftEid = {}, false, nil
    sweepIn, closed, failed, said = 0.0, false, {}, {}
end

function Elevator.registerHooks()
    local function gated(fn)
        return function(...) if deps.isLive == nil or deps.isLive() then pcall(fn, ...) end end
    end
    local function activator(trigger)
        local e
        pcall(function() e = EntityGameInterface.GetEntity(trigger.activator) end)
        return e
    end
    Observe('LiftDevice', 'OnAreaEnter', gated(function(self, t) Elevator.OnEnter(self, activator(t)) end))
    Observe('LiftDevice', 'OnAreaExit',  gated(function(self, t) Elevator.OnExit(self, activator(t), false) end))
    Observe('LiftDevice', 'OnDetach',    gated(function(self) Elevator.OnExit(self, nil, true) end))
end

return Elevator
