--[[
holostudio.lua -- a minimal, dependency-free holo studio service for CET.

The recipe from ../03-the-runtime.md in one file, with no framework around it: a timer, a spawn, a
solved camera, a look-at, a guard, a teardown. Needs CET, Codeware (for DynamicEntitySystem /
DynamicEntitySpec) and the three archives from ../02-bake-the-assets.md.

It is distilled from a shipping implementation and has never been run in this form. Treat it as a
shape to port -- syntax-check it in your own project, and expect to add your own logging, your own
copy registry and your own facial driver. Every measured number is commented where it appears.

WIRING (init.lua):

    local Studio = require('holostudio')
    registerForEvent('onUpdate', function(dt) Studio.Update(dt) end)
    registerForEvent('onShutdown', function() Studio.OnSessionEnd() end)
    -- ...and call Studio.OnSessionEnd() from your session-end / pre-load hook too.

USE:

    Studio.Start('panam', {
        record = 'Character.Panam', appearance = 'panam_default',
        shot = 'FACE',
        onReady = function(ok, why) print('studio ready=' .. tostring(ok) .. ' ' .. tostring(why)) end,
    })
    ...
    Studio.Stop()
]]

local Studio = {}

-- ============================================================================ configuration

local CFG = {
    -- Your baked depot paths (../02-bake-the-assets.md).
    roomEnt   = 'mymod\\holo\\room.ent',
    cameraEnt = 'mymod\\holo\\camera.ent',
    -- The component name the camera .ent instantiates under. Vanilla's is this; a copy keeps it.
    camComp   = 'RenderToTextureCamera',

    -- WHERE THE STUDIO IS. Out of bounds, and clear of CDPR's own studio at (5894.69, 6133.51)
    -- so a real vanilla holocall can never overlap yours. The light bake is authored around
    -- `subject` -- moving either means re-baking the lights.
    studio    = { x = 5914.686, y = 6133.506, z = 0.0 },   -- the room's FLOOR CENTRE
    subject   = { x = 5915.0,   y = 6134.0,   z = 1.1 },   -- where they stand (per-room offset!)

    -- Tags. Everything we spawn wears `tag`; the lens also wears `camTag` so a reframe can drop
    -- the lens without the room.
    tag       = 'mymod_studio',
    camTag    = 'mymod_studio_cam',
    copyTag   = 'mymod_copy',

    -- How long the lens stands after it stops drawing, in frames. NOT a settled number: toggling
    -- a camera off and freeing it in the same frame is a render-thread crash (../06-pitfalls.md).
    freeFrames = 30,

    camTimeout = 5.0,     -- stream-in patience for the lens
    guardEvery = 1.0,     -- the slow ticker
    gazeEvery  = 5.0,     -- the engine drops stale look-ats; re-request on a cycle
    gazeRetry  = 1.0,     -- ...but a request that never went out retries on the next tick
    driftFrac  = 0.25,    -- fraction of frameH before drift is worth a log line
}

-- ============================================================================ the shots
--
-- A shot is four numbers and the DISTANCE IS SOLVED, never authored:
--     dist = (frameH / 2) / tan(fov / 2)
-- The lens sits at the frame's own centre height, so the camera is level.
-- ORBIT IS MEASURED OFF THEIR FACING: 0 is dead in front of them.
--
-- FACE reproduces vanilla's own holocall rig from CDPR's authored camera node: 0.43 m of frame at
-- fov 35 solves to 0.682 m against their 0.675, and 1.65 is their lens height to three decimals.
--
-- EVERY SHOT MUST SOLVE TO LESS THAN YOUR WALL CLEARANCE (ours: 3.1 m). That is what sets the
-- wider lens on the wide shots -- a whole figure at fov 35 wants 3.25 m, i.e. the lens in a wall.
local SHOTS = {
    FACE = { frameH = 0.43,  aimZ = 1.650, orbit = 20.4, fov = 35.0 },   -- 0.68 m
    BUST = { frameH = 1.05,  aimZ = 1.320, orbit = 20.4, fov = 35.0 },   -- 1.67 m
    PAIR = { frameH = 1.40,  aimZ = 1.250, orbit = 20.4, fov = 35.0 },   -- 2.22 m
    BODY = { frameH = 2.05,  aimZ = 0.980, orbit = 20.4, fov = 45.0 },   -- 2.47 m
    -- THE CONTROL. Dead front, known-good numbers: when an angled shot is black, one press on
    -- FLAT separates a bad placement from a dead camera.
    FLAT = { frameH = 0.545, aimZ = 1.620, orbit =  0.0, fov = 32.0 },   -- 0.95 m
}
local SHOT_ORDER = { 'FACE', 'BUST', 'PAIR', 'BODY', 'FLAT' }
local _defaultShot = 'FACE'

-- ============================================================================ tiny timer
-- Replace with your project's Cron if you have one. The requirement is that every timer is in the
-- TABLE, so the session boundary can drop the lot: an untracked callback fires on a world that has
-- been torn down, and an engine call from there access-violates where pcall catches nothing. Most
-- timers are also individually haltable through a handle; the two deferred entity frees below
-- deliberately are not, and their comments say why.
--
-- `_timerN` ONLY EVER INCREMENTS. Never reset it -- not here, not in OnSessionEnd, however tidy
-- that looks. Handles are compared against a live table and several call sites halt a timer that
-- may already be gone; that is only harmless because a handle can never be recycled onto somebody
-- else's timer. Set `_timerN = 0` at a session boundary and a stale `_bodyT = 3` carried across it
-- deletes the NEW session's third timer, which is the guard tick.
local _timers, _timerN = {}, 0

local function every(sec, fn)
    _timerN = _timerN + 1
    _timers[_timerN] = { t = sec, period = sec, fn = fn }
    return _timerN
end

local function halt(h)
    if h then _timers[h] = nil end
end

function Studio.Update(dt)
    -- DUE TIMERS ARE COLLECTED FIRST. A callback halts timers and starts new ones, and adding a
    -- key to a table you are traversing with pairs() is undefined behaviour in Lua.
    local due
    for h, tm in pairs(_timers) do
        tm.t = tm.t - dt
        if tm.t <= 0.0 then
            due = due or {}
            due[#due + 1] = h
        end
    end
    if not due then return end
    for i = 1, #due do
        local h = due[i]
        local tm = _timers[h]
        if tm then
            -- Every timer repeats; there is no one-shot kind. A callback that wants to run once
            -- halts itself, and `every(0.0, fn)` is the per-frame idiom the deferred frees count
            -- their frames on.
            if tm.period <= 0.0 then
                tm.t = 0.0
            else
                tm.t = tm.t + tm.period
            end
            local ok, err = pcall(tm.fn)
            if not ok then print('[studio] timer error: ' .. tostring(err)) end
        end
    end
end

-- ============================================================================ state

local _use                    -- nil = free; otherwise a phrase for a refusal line
local _subjectKey             -- who is up (nil = down)
local _subjectId              -- their EntityID
local _subjectAt, _subjectYaw -- where this shoot placed them, and which way they face
local _roomId, _camId, _camEnt, _camComp
local _shot, _shotName, _rig  -- the SHOTS row, its name, and the lens transform it solved to
local _ready                  -- Start's once-only readiness callback
local _pollT, _bodyT, _guardT -- the three live timers
local _gazeSent = false

-- ============================================================================ helpers

local function log(s) print('[studio] ' .. s) end

local function des()
    local ok, d = pcall(function() return Game.GetDynamicEntitySystem() end)
    return ok and d or nil
end

--- CreateEntity returns a ZERO id when it rejects a point outright (outside the streamed world).
--- Walking past it leaves a poll waiting five seconds and then blaming the archive.
local function isZeroId(id)
    if id == nil then return true end
    local h
    pcall(function() h = tostring(id.hash) end)
    return h == '0' or h == '0ULL' or h == nil
end

--- THE ENGINE'S YAW CONVENTION. Forward at yaw t is (-sin t, cos t), so pointing at a delta is
--- atan2(-dx, dy) -- NOT atan2(dx, dy). Invisible at orbit 0, wrong at every other angle, and a
--- wrong-signed yaw alone explains every black feed.
---
--- `math.atan2` is LuaJIT (5.1), which is what the game runs. A 5.3+ harness will not have it --
--- use `math.atan(-dx, dy)` there, and do not "fix" it in the shipped file.
local function yawTo(dx, dy)
    return math.deg(math.atan2(-dx, dy))
end

--- Where the lens stands and how it points. Pure arithmetic -- the same solve runs in a test.
local function solve(shot, feet, facingYaw)
    local dist    = (shot.frameH * 0.5) / math.tan(math.rad(shot.fov * 0.5))
    local bearing = facingYaw + shot.orbit
    local br      = math.rad(bearing)
    return {
        x = feet.x - math.sin(br) * dist,
        y = feet.y + math.cos(br) * dist,
        z = feet.z + shot.aimZ,
        -- Looking back down the bearing it stands on. `+ 180` rather than a re-derived atan2:
        -- identically the same angle, and this one cannot lose a sign.
        yaw   = bearing + 180.0,
        pitch = shot.pitch or 0.0,     -- level: the lens is already at the frame's centre height
        fov   = shot.fov,
        dist  = dist,
    }
end

local function unforce(id)
    if id == nil then return end
    pcall(function() Game.GetAnimationSystem():SetForcedVisible(id, false) end)
end

-- ============================================================================ spawning

local function createRoom()
    local d = des()
    if not d then return false end
    local spec = DynamicEntitySpec.new()
    spec.templatePath  = ResRef.FromName(CFG.roomEnt)
    spec.position      = Vector4.new(CFG.studio.x, CFG.studio.y, CFG.studio.z, 1.0)
    spec.persistState  = false
    spec.persistSpawn  = false
    spec.alwaysSpawned = true
    spec.spawnInView   = true
    spec.active        = true
    spec.tags          = { CName.new(CFG.tag) }
    pcall(function() _roomId = d:CreateEntity(spec) end)
    if isZeroId(_roomId) then
        _roomId = nil
        log('room REFUSED -- is your room archive mounted? (.archive needs a FULL restart)')
        return false
    end
    return true
end

--- Put a lens in the world at `rig`, ALREADY AIMED. The orientation here is the only aim this
--- camera will have: reframing respawns it (see Reframe).
local function createCamera(rig)
    local d = des()
    if not d then return false end
    local spec = DynamicEntitySpec.new()
    spec.templatePath  = ResRef.FromName(CFG.cameraEnt)
    spec.position      = Vector4.new(rig.x, rig.y, rig.z, 1.0)
    -- THE INSTANCE FORM. The singleton EulerAngles.ToQuat throws, leaves the rotation unset and
    -- logs nothing -- the entity then points down its own axis.
    spec.orientation   = EulerAngles.new(0.0, rig.pitch, rig.yaw):ToQuat()
    spec.persistState  = false
    spec.persistSpawn  = false
    spec.alwaysSpawned = true
    spec.spawnInView   = true
    spec.active        = true
    spec.tags          = { CName.new(CFG.tag), CName.new(CFG.camTag) }
    pcall(function() _camId = d:CreateEntity(spec) end)
    if isZeroId(_camId) then
        _camId = nil
        log(('lens REFUSED (id 0) at (%.2f, %.2f, %.2f) -- that point is outside the streamed '
             .. 'world, so nothing will stream in'):format(rig.x, rig.y, rig.z))
        return false
    end
    return true
end

--- Wait for the lens to stream in, then switch it on. `onUp(ok, why)` fires exactly once.
local function awaitCamera(rig, onUp)
    local d = des()
    if not d then onUp(false, 'no DynamicEntitySystem (Codeware missing?)'); return end
    halt(_pollT)
    local waited = 0.0
    _pollT = every(0.1, function()
        waited = waited + 0.1
        local e
        pcall(function() if d:IsSpawned(_camId) then e = d:GetEntity(_camId) end end)
        if not IsDefined(e) then
            if waited >= CFG.camTimeout then
                halt(_pollT); _pollT = nil
                onUp(false, 'camera never streamed in -- is the camera archive mounted?')
            end
            return
        end
        halt(_pollT); _pollT = nil
        _camEnt = e
        pcall(function() _camComp = e:FindComponentByName(CFG.camComp) end)
        if _camComp == nil then onUp(false, 'no ' .. CFG.camComp .. ' on the camera ent'); return end
        -- THE METHOD, not the property: writing isEnabled is silently dead.
        pcall(function() _camComp:Toggle(true) end)
        -- ...and the lens AFTER the enable. Toggle re-initialises the component from its authored
        -- values, so an fov written first is discarded and you get the stock wide lens.
        pcall(function() _camComp.fov = rig.fov end)
        log(('lens up: %s at (%.2f, %.2f, %.2f) yaw %.1f pitch %.1f dist %.2f fov %.1f '
             .. '-- frames %.2fm centred %.2f above their feet')
            :format(_shotName, rig.x, rig.y, rig.z, rig.yaw, rig.pitch, rig.dist, rig.fov,
                    _shot.frameH, _shot.aimZ))
        onUp(true)
    end)
end

-- ============================================================================ gaze

--- Look at the LENS. The camera entity's origin IS its lens, so a plain look-at with no offset is
--- correct at every shot -- and lifting the target to eye height aims 12-16 degrees ABOVE the
--- lens, which renders as looking over the viewer's head.
local function lookAtLens(body, target)
    if not (IsDefined(body) and IsDefined(target)) then return false, 'no body or no lens' end
    local stim
    pcall(function() stim = body:FindComponentByName('ReactionManager') end)
    if not stim then return false, 'no ReactionManager component' end
    local ok, err = pcall(function()
        stim:DeactiveLookAt()                     -- or requests stack
        local ev = LookAtAddEvent.new()
        ev:SetEntityTarget(target, '', Vector4.new(0, 0, 0, 0))
        ev:SetStyle(animLookAtStyle.Normal)
        ev.request.limits.softLimitDegrees  = 360.0
        ev.request.limits.hardLimitDegrees  = 270.0
        ev.request.limits.hardLimitDistance = 1000000.0
        ev.request.limits.backLimitDegrees  = 210.0
        -- WHICH SPACE IS THE TARGET RESOLVED IN? Not settled. Nothing in the decompile says, CDPR
        -- sets it from a TweakDB preset, and every in-script SetEntityTarget passes an empty
        -- offset -- so no vanilla call site distinguishes the two. It is the prime suspect when a
        -- studio subject turns her HEAD onto the lens and the gaze still lands "to the side": that
        -- is what resolving a world-space target in some parent's frame looks like. A flag rather
        -- than a constant, so the two can be A/B'd in one session instead of one restart a guess.
        ev.request.calculatePositionInParentSpace = true
        -- 80 = vanilla's holocall preset: the gaze outruns an idle's look-around clips, which is
        -- what keeps the head LOCKED on camera instead of drifting off with the pose.
        ev.request.transitionSpeed = 80.0
        ev.bodyPart = 'Eyes'                      -- names which part LEADS; grants no authority

        -- THE ARRAY HOLDS EXACTLY TWO (StaticArray<LookAtPartRequest, 2>). Priority Eyes > Head.
        -- EYES NEEDS ITS OWN PART REQUEST: `suppress` -- the authority to override the animation
        -- -- exists only here, so with Head listed and Eyes absent the head comes round and the
        -- eyes stay in the clip, missing by exactly the orbit angle.
        local eyes = LookAtPartRequest.new()
        eyes.partName = 'Eyes'
        -- ON EYES THE SCALAR IS blendWeight, not stiffness: the 0.0 that hard-locks a head blends
        -- NOTHING in and is a guaranteed no-op.
        eyes.weight   = 1.0
        eyes.suppress = 1.0
        eyes.mode     = 0

        local head = LookAtPartRequest.new()
        head.partName = 'Head'
        -- Stiffness AGAINST the look-at: 0.00 is a hard lock, the default glance is 0.10. Lower
        -- than a glance because at face zoom a head drifting with the pose reads as "not looking
        -- at camera"; not 0.00, which is dead-eyed.
        head.weight   = 0.05
        head.suppress = 1.0
        head.mode     = 0

        ev:SetAdditionalPartsArray({ eyes, head })
        body:QueueEvent(ev)
        stim.lookatEvent = ev                     -- DeactiveLookAt needs the handle
    end)
    if not ok then return false, 'LookAtAddEvent failed: ' .. tostring(err) end
    return true
end

local function stopLookAt(body)
    if not IsDefined(body) then return end
    pcall(function()
        local stim = body:FindComponentByName('ReactionManager')
        if stim then stim:DeactiveLookAt() end
    end)
end

-- ============================================================================ the guard

--- Where the body actually is, in the shot's own terms. nil while it streams, so a caller keeps
--- its previous answer rather than acting on a zero.
local function readSubject()
    local body, feet, fyaw
    pcall(function()
        body = Game.FindEntityByID(_subjectId)
        if not IsDefined(body) then return end
        local p = body:GetWorldPosition()
        feet = { x = p.x, y = p.y, z = p.z }
        local f = body:GetWorldForward()
        if f and (math.abs(f.x) + math.abs(f.y)) > 0.01 then fyaw = yawTo(f.x, f.y) end
    end)
    return body, feet, fyaw
end

--- The one slow ticker: re-pin the gaze, and REPORT drift. It deliberately corrects nothing --
--- measuring drift is what turns "she looks off-centre" into a number that says whether the pose
--- walked, the shot is mis-solved, or nothing moved at all. Reframe respawns.
local function startGuard()
    halt(_guardT)
    local gazeIn, drifted, lastWhy = 0.0, false, nil
    _guardT = every(CFG.guardEvery, function()
        local body, feet, fyaw = readSubject()

        if feet and _rig and _shot then
            local want = solve(_shot, feet, fyaw or 0.0)
            local off = math.abs(want.x - _rig.x) + math.abs(want.y - _rig.y)
                      + math.abs(want.z - _rig.z)
            if off >= _shot.frameH * CFG.driftFrac then
                if not drifted then
                    drifted = true
                    log(('DRIFT on %s: they are at (%.2f, %.2f, %.2f) facing %.1f -- the lens '
                         .. 'wants to be %.2fm from where it was spawned. It cannot move; '
                         .. 'REFRAME to respawn it.')
                        :format(_shotName, feet.x, feet.y, feet.z, fyaw or 0.0, off))
                end
            elseif drifted then
                drifted = false
                log('back in frame on ' .. tostring(_shotName))
            end
        end

        gazeIn = gazeIn - CFG.guardEvery
        if gazeIn > 0.0 then return end
        -- THE BUDGET IS SPENT ONLY ON A REQUEST THAT WENT OUT. Resetting it before the attempt
        -- costs a whole cycle to the FIRST tick, which normally finds no body yet -- and that is
        -- exactly the window where "she doesn't look into camera" is most visible.
        gazeIn = CFG.gazeRetry
        local ok, why = lookAtLens(body, _camEnt)
        if ok then
            gazeIn = CFG.gazeEvery
            if not _gazeSent then _gazeSent = true; log('gaze: on the lens') end
        elseif why ~= lastWhy then
            -- Latched on the reason: a working gaze stays silent, a broken one says which of
            -- never-asked / asked-and-refused it is, once.
            lastWhy = why
            log('gaze: NOT sent -- ' .. tostring(why))
        end
    end)
end

-- ============================================================================ public API

function Studio.ShotNames()   return SHOT_ORDER end
function Studio.Shot()        return _shotName end
function Studio.DefaultShot() return _defaultShot end
function Studio.SubjectId()   return _subjectId end
function Studio.Rig()         return _rig end
function Studio.IsUp()        return _subjectKey ~= nil and _subjectId ~= nil end

--- ASK THIS, NOT IsUp(). IsUp answers "is a body standing in the studio", which is false for the
--- whole window between Start committing and the subject streaming in -- and that window is where
--- a competing spawn does the most damage, because it is usually the SAME person.
function Studio.InUse() return _use ~= nil, _use end

function Studio.SetDefaultShot(name)
    if SHOTS[name] then _defaultShot = name; return true end
    return false   -- an unknown name is ignored, never stored
end

--- Spawn the subject, the room and an already-aimed lens; switch the lens on.
---
--- opts.record      TweakDB record NAME, e.g. 'Character.Panam'   (a NAME, never a raw TweakDBID)
--- opts.appearance  appearance name, optional
--- opts.shot        a SHOTS key; unknown names fall back and SAY SO
--- opts.at, opts.yaw  where they stand (defaults to the studio spot, facing +Y)
--- opts.room        false to skip the room (a shoot placed in the real world)
--- opts.use         the phrase InUse() reports, e.g. 'a holo call'
--- opts.onReady(ok, why)  fires EXACTLY ONCE when the picture is watchable, or never will be
function Studio.Start(who, opts)
    opts = opts or {}
    if type(who) ~= 'string' or who == '' then return false end
    if _subjectKey or _use then return false end          -- one studio; Stop() first
    local d = des()
    if not d then return false end
    local record = opts.record
    if type(record) ~= 'string' or record == '' then
        log('cannot start: no record name for "' .. who .. '"')
        return false
    end

    -- ONCE, and success is final while a failure is not: the spawn machinery can report failure
    -- AFTER a successful spawn, and latching the failure would swallow a later rescue.
    local reported = nil
    local function ready(ok, why)
        ok = ok == true
        if reported == true then return end
        if reported == false and not ok then return end
        reported = ok
        if opts.onReady then pcall(opts.onReady, ok, why) end
    end
    _ready = ready

    -- IN USE FROM HERE, not from whenever the subject finishes streaming in.
    _use = opts.use or 'the studio'
    _gazeSent = false

    _shotName = opts.shot or _defaultShot
    _shot = SHOTS[_shotName]
    if not _shot then
        log(('no shot "%s" -- falling back to %s'):format(tostring(_shotName), _defaultShot))
        _shotName, _shot = _defaultShot, SHOTS[_defaultShot]
    end

    local at  = opts.at or CFG.subject
    local yaw = tonumber(opts.yaw) or 0.0
    _subjectAt, _subjectYaw = { x = at.x, y = at.y, z = at.z }, yaw

    -- The room. Skipped when the caller placed the body in the real world -- the point of standing
    -- somewhere real is not to put a grey box around it.
    if opts.room ~= false then createRoom() end

    -- The lens, spawned already aimed. Because it will not be turned afterwards, this solve is the
    -- framing for the whole shoot.
    _rig = solve(_shot, at, yaw)
    if not createCamera(_rig) then Studio.Stop(); return false end

    -- The subject.
    local rot = EulerAngles.new(0, 0, yaw):ToQuat()
    local spec = DynamicEntitySpec.new()
    -- A RECORD NAME, ALWAYS. A raw TweakDBID for a record that does not stringify is accepted by
    -- CreateEntity and even renders -- and the puppet has no record, and the engine dies on a null
    -- a few seconds later.
    spec.recordID = TweakDBID.new(record)
    if type(opts.appearance) == 'string' and opts.appearance ~= '' then
        spec.appearanceName = CName.new(opts.appearance)
    end
    spec.position      = Vector4.new(at.x, at.y, at.z, 1.0)
    spec.orientation   = rot
    spec.persistState  = false
    spec.persistSpawn  = false          -- transient: gone on save/load, so nothing accumulates
    spec.alwaysSpawned = true           -- EXISTS AND DRAWS at range          <- the lever
    spec.spawnInView   = true
    spec.active        = true
    spec.tags          = { CName.new(CFG.copyTag), CName.new(CFG.copyTag .. '_' .. who:lower()) }

    local subjId
    pcall(function() subjId = d:CreateEntity(spec) end)
    if isZeroId(subjId) then
        log(('subject REFUSED at (%.2f, %.2f, %.2f) -- CreateEntity gave id 0; that point is '
             .. 'outside the streamed world'):format(at.x, at.y, at.z))
        Studio.Stop()
        return false
    end
    -- BEFORE THE POLL IS CREATED, and that ordering is load-bearing. Stop() deletes the body by
    -- this key; set it inside the poll instead and a Stop landing in the streaming window halts the
    -- poll, leaves the key nil, and leaks an alwaysSpawned, always-drawn body for the session.
    _subjectKey = who:lower()

    -- Wait for the body, then release anim culling. WITHOUT THIS SHE STANDS FROZEN at range.
    local waited = 0.0
    -- TRACKED, because it outlives the Start that scheduled it. An untracked poll survives Stop,
    -- then writes _subjectId, forces visibility on a body being deleted, and fires ready(true)
    -- over a torn-down studio.
    halt(_bodyT)
    _bodyT = every(0.25, function()
        waited = waited + 0.25
        local e
        pcall(function() if d:IsSpawned(subjId) then e = d:GetEntity(subjId) end end)
        if IsDefined(e) then
            halt(_bodyT); _bodyT = nil
            pcall(function() _subjectId = e:GetEntityID() end)
            pcall(function() Game.GetAnimationSystem():SetForcedVisible(_subjectId, true) end)
            -- (Mount your pose here -- ONCE. A mount inside a poll that re-runs respawns the anim
            --  host every tick and no mount ever survives streaming.)
            if _camComp then ready(true) end
        elseif waited >= 10.0 then
            halt(_bodyT); _bodyT = nil
            ready(false, 'the subject never streamed in')
        end
    end)

    awaitCamera(_rig, function(okCam, whyCam)
        if not okCam then ready(false, whyCam); return end
        startGuard()
        if _subjectId then ready(true) end     -- the subject beat the camera; the picture is live
    end)
    return true
end

--- Reframe by RESPAWNING the lens. Runtime aiming does work (SetLocalOrientation), but the spawn
--- path is the one with a clean on-screen measurement behind it, and it is the shape vanilla is.
function Studio.Reframe(shotName)
    if not _subjectKey then return false end
    local shot = SHOTS[shotName]
    if not shot then return false end
    -- THEIR LIVE POSITION, BUT THE SPAWN'S FACING. `readSubject` returns a yaw and it is
    -- deliberately discarded: Start solves against the yaw the subject was SPAWNED at, and the
    -- baked lights are authored in world space around that axis. Orbiting off a live facing swings
    -- the lens onto the unlit side, and makes reframing onto the SAME shot a move rather than a
    -- no-op.
    local _, feet = readSubject()
    feet = feet or _subjectAt

    -- The old lens goes first, and its delete WAITS (see Stop). Each reframe needs its own delete
    -- key: a shared one makes each reframe cancel the previous one's free.
    local d, oldComp, oldId = des(), _camComp, _camId
    if oldComp then pcall(function() oldComp:Toggle(false) end) end
    if d and oldId then
        local n = 0
        local t
        t = every(0.0, function()
            n = n + 1
            if n >= CFG.freeFrames then halt(t); pcall(function() d:DeleteEntity(oldId) end) end
        end)
    end
    _camComp, _camEnt, _camId = nil, nil, nil

    _shotName, _shot = shotName, shot
    _rig = solve(shot, feet, _subjectYaw or 0.0)
    if not createCamera(_rig) then return false end
    awaitCamera(_rig, function(ok, why)
        if ok then startGuard() end
        -- UNCONDITIONALLY, and this is the point of the latch in Start: the advertised recovery
        -- ("the feed is black -> REFRAME onto FLAT") hands back a picture, and a Reframe that only
        -- ever reported failure left the caller's video tier un-attached forever -- a live,
        -- correctly framed feed with nobody looking at it.
        if _ready then _ready(ok, why) end
    end)
    return true
end

--- THE TEARDOWN CONTRACT, in order, from every LIVE-WORLD exit. Safe to call twice.
--- The session boundary is NOT one of these -- see OnSessionEnd.
function Studio.Stop()
    halt(_pollT);  _pollT = nil
    halt(_bodyT);  _bodyT = nil
    halt(_guardT); _guardT = nil
    _gazeSent = false

    -- 0. the look-at goes first, while the body still exists to release
    if _subjectId then
        local body
        pcall(function() body = Game.FindEntityByID(_subjectId) end)
        stopLookAt(body)
    end
    -- 1. forced-visible OFF before the ids are dropped: a leaked flag outlives the delete
    unforce(_subjectId)
    -- 2. camera off before it goes: a live remote render with nobody watching is a crash suspect
    if _camComp then pcall(function() _camComp:Toggle(false) end) end

    local d = des()
    if d then
        -- 3. the bodies and the room go NOW, so nothing observes a half-dead studio...
        if _subjectKey then
            pcall(function() d:DeleteTagged(CName.new(CFG.copyTag .. '_' .. _subjectKey)) end)
        end
        if _roomId then pcall(function() d:DeleteEntity(_roomId) end) end
        -- 4. ...but THE LENS WAITS. Toggling a camera off and freeing it in the same frame is a
        --    render-thread crash: Toggle(false) is a request, not a barrier, and IsEnabled() goes
        --    false on the first poll after it regardless.
        local camId = _camId
        if camId then
            local n = 0
            local t
            t = every(0.0, function()
                n = n + 1
                if n >= CFG.freeFrames then
                    halt(t)
                    pcall(function() d:DeleteEntity(camId) end)
                end
            end)
        end
    end

    _use, _subjectKey, _subjectId = nil, nil, nil
    _subjectAt, _subjectYaw = nil, nil
    _roomId, _camId, _camEnt, _camComp = nil, nil, nil, nil
    _shot, _shotName, _rig, _ready = nil, nil, nil, nil
end

--- FORGET ONLY. A dying world takes NO engine calls: every Game.GetXxxSystem() stub reads the
--- world pointer off the GameInstance and access-violates once it is null, and pcall catches none
--- of it. Entities, forced-visible flags and per-session systems die with their world, so there is
--- nothing to undo -- only state to drop.
function Studio.OnSessionEnd()
    _timers = {}            -- ...but NOT _timerN; see its declaration
    _pollT, _bodyT, _guardT = nil, nil, nil
    _use, _subjectKey, _subjectId = nil, nil, nil
    _subjectAt, _subjectYaw = nil, nil
    _roomId, _camId, _camEnt, _camComp = nil, nil, nil, nil
    _shot, _shotName, _rig, _ready = nil, nil, nil, nil
    _gazeSent = false
end

return Studio
