# 3. The runtime

CET Lua plus Codeware's `DynamicEntitySystem`, and that is all. No native code, no `.scene`, no
quest facts.

A working reference module is in [`snippets/holostudio.lua`](snippets/holostudio.lua) — read this
chapter for *why*, that file for *shape*.

---

## 1. Build it as a service

Build this as a service with a handful of entry points, even when the first caller is a debug panel.
Two panels driving two copies of the recipe is how you end up tuning numbers the shipping path
cannot consume.

```lua
Studio.Start(who, opts) -> Bool     -- spawn subject + room + camera; opts.onReady(ok, why)
Studio.Stop()                       -- the teardown contract, in order. Safe to call twice
Studio.OnSessionEnd()               -- FORGET ONLY. Never call the engine here (§8.3)
Studio.SubjectId() / IsUp()         -- the body's EntityID, and liveness
Studio.InUse() -> (busy, why)       -- what the studio is doing, as a phrase for a refusal line
Studio.Reframe(shotName)            -- respawn the lens for a different framing
```

`Start` returns false only on an *immediate* refusal — a missing dependency, a studio already up, a
spawn the engine rejected on the spot, a duplicate name. Everything slower reports through the
callback instead.

**`opts.onReady` must fire exactly once** — when the picture is actually watchable (subject spawned
*and* camera streamed *and* enabled), or when it never will be. Two rules came out of real bugs
there. Success is final and a failure is not: the spawn machinery can call `onFailed` *after*
`onSpawned`, so a late "not ready" arriving over a working call has to be swallowed. Latch the
failure as well, though, and a later rescue becomes unreachable — a reframe that succeeds after a
first lens timed out — and the call then stays voice-only for its whole life with a live, correctly
framed picture nobody shows. The other rule is about ordering inside `Start`: a `Start` that returns
false must not overwrite the live studio's callback, so take the claim as the *last* refusal and
assign `_ready` below every earlier one.

---

## 2. One studio, and the flag that says so

Ask whether the studio is **in use**, not whether a body is standing in it.

`IsUp()` is false for the whole window between `Start` committing and the subject streaming in, and
that window is where a competing spawn does the most damage, because the studio is spawning the same
person into it. Set the busy flag the moment the claim is taken, and clear it beside the claim in
both `Stop` and `OnSessionEnd`.

```lua
local _use     -- nil = free; otherwise a phrase: 'a holo call', 'a picture'
function Studio.InUse() return _use ~= nil, _use end
```

Then make your NPC spawn helper refuse while it is set, **above** any "delete the old copy" step.
That order is the difference between "the summon did not work" and "the call lost its actor": a call
and a photo each spawn a body, pin it, drive its face and delete it on a schedule, and a second
spawn landing in the middle is usually the *same person*. The studio's own subject passes an opt-out
flag — it is the one caller allowed to spawn into its own claim.

A studio module that cannot be loaded is **no studio**, not a busy one. "Could not ask" must never
become "refuse every spawn for the session".

---

## 3. The camera

### 3.1 A shot is four numbers, and the distance is solved

Vanilla frames a holocall by placement. Its camera is a fixed world node that never moves for the
whole call, and the body is teleported onto an authored spot in a known pose so that it cannot leave
frame. Copy that shape: solve once, hold, and let a slow guard report drift large enough to see.

CDPR's own rig, read out of the studio sector (camera node 573 and lookat 572, measured against the
AI spot 570):

```
ground distance 0.675 m | lens 1.6525 m above the subject's feet | orbit +20.4 deg off their facing
camera pitch -0.67 deg (level) | fov 35
```

So express a shot as: how tall a slice of them to frame, at what height, from which side, on what
lens — and solve the distance.

```lua
dist = (frameH * 0.5) / math.tan(math.rad(fov * 0.5))
```

Changing the lens then *reframes* the shot instead of re-cropping it, and putting the lens at the
frame's own centre height keeps the camera level, so nobody is shot up the nose. (Vanilla's −0.67°
is level to within a rounding error.)

```lua
local SHOTS = {
  -- vanilla's own rig, reproduced from its numbers: 0.43 m of frame at fov 35 solves to 0.682 m
  -- against the 0.675 CDPR authored, and 1.65 is their lens height to three decimals.
  FACE = { frameH = 0.43,  aimZ = 1.650, orbit = 20.4, fov = 35.0 },   -- 0.68 m
  BUST = { frameH = 1.05,  aimZ = 1.320, orbit = 20.4, fov = 35.0 },   -- 1.67 m
  PAIR = { frameH = 1.40,  aimZ = 1.250, orbit = 20.4, fov = 35.0 },   -- 2.22 m, two people
  BODY = { frameH = 2.05,  aimZ = 0.980, orbit = 20.4, fov = 45.0 },   -- 2.47 m, head to floor
  FLAT = { frameH = 0.545, aimZ = 1.620, orbit =  0.0, fov = 32.0 },   -- 0.95 m, the control
}
```

Three things about that table:

- **ORBIT IS MEASURED OFF THEIR FACING**, not off a world axis. 0 is dead in front of them.
- **The lens must stay inside the room.** Measure your walls' clearance from the subject (ours was
  3.1 m) and check that every shot solves to less than that. It is what sets the wider lens on the
  wide shots — a whole figure at fov 35 puts the camera at 3.25 m, which is *in a wall*, and a lens
  in a wall renders the same black rectangle a dead camera does.
- **Keep a FLAT control row.** Dead front, no orbit, known-good numbers. When an angled shot comes up
  black, one press on FLAT separates a bad placement from a dead camera. Worth a table row on its
  own.

Default to FACE. A holocall is a face, and the FACE row *is* vanilla's rig — matching it is what
makes your call read as the same kind of thing rather than as a video feed of somebody standing in a
room. BODY is the right default only while the studio is a lab and the questions are "did the body
spawn, is it lit, is it animating"; at 2.47 m out, a face is a handful of pixels in a 300 px card.

### 3.2 Solving the lens

```lua
local function solve(shot, feet, facingYaw)
    local dist    = (shot.frameH * 0.5) / math.tan(math.rad(shot.fov * 0.5))
    local bearing = facingYaw + shot.orbit
    local br      = math.rad(bearing)
    return {
        x = feet.x - math.sin(br) * dist,
        y = feet.y + math.cos(br) * dist,
        z = feet.z + shot.aimZ,
        yaw   = bearing + 180.0,      -- looking back down the bearing it stands on
        pitch = shot.pitch or 0.0,    -- level: the lens already sits at the frame's centre height
        fov   = shot.fov, dist = dist,
    }
end
```

**The engine's yaw convention: forward at yaw t is (−sin t, cos t)**, so pointing at a delta is
`atan2(-dx, dy)`. Read off vanilla directly — their camera node carries yaw 68.01° and stands at
(+0.627, −0.248) from the subject's spot, and only this convention turns that quaternion towards her.

`+ 180` rather than a re-derived `atan2` because the two are identically the same angle and this one
cannot lose a sign. **A wrong-signed yaw is sufficient on its own to explain every black feed**, and
it looks exactly like a broken camera.

### 3.3 Spawning the lens, already aimed

```lua
local spec = DynamicEntitySpec.new()
spec.templatePath  = ResRef.FromName('mymod\\holo\\camera.ent')
spec.position      = Vector4.new(rig.x, rig.y, rig.z, 1.0)
spec.orientation   = EulerAngles.new(0.0, rig.pitch, rig.yaw):ToQuat()
spec.persistState  = false
spec.persistSpawn  = false
spec.alwaysSpawned = true
spec.spawnInView   = true
spec.active        = true
spec.tags          = { CName.new(TAG), CName.new(CAM_TAG) }
local camId = Game.GetDynamicEntitySystem():CreateEntity(spec)
```

**`spec.orientation` wants the INSTANCE form** — `EulerAngles.new(...):ToQuat()`. The singleton form
throws, leaves the rotation unset, and logs nothing; the entity then points down its own axis, which
for a light is a wall and for a camera is the far side of the room.

**ID 0 is a refusal, and it is the one that lies.** `CreateEntity` returns a zero id when it rejects
the point outright, i.e. when the point is outside the streamed world. Walk past it and your
stream-in poll waits five seconds and then blames the archive for a position problem:

```lua
local hash; pcall(function() hash = tostring(camId.hash) end)
if hash == '0' or hash == '0ULL' then
    print(('lens REFUSED (id 0) at (%.2f, %.2f, %.2f) -- that point is outside the streamed world')
          :format(rig.x, rig.y, rig.z))
    return false
end
```

Two tags, not one: a service tag on everything, plus a camera-only tag so a reframe can drop the lens
without the room.

### 3.4 Aim at spawn, or aim at runtime?

Both work. Runtime aiming via `SetLocalOrientation` is real — a rig that spawned at identity and was
aimed only by that call rendered correctly. (Two earlier runs that "proved" a lens cannot be turned
were both aiming with a wrong-signed yaw, §3.2.)

Putting the aim in the spec and respawning to reframe is still the better default. It is the path
with a clean on-screen measurement behind it, and it is the shape vanilla is: a fixed camera node
that never moves. It also keeps the guard honest — the guard corrects nothing and *reports* drift as
a number, rather than quietly chasing a subject around the room.

If you do respawn to reframe, give each replaced lens its own delete key. A shared key makes every
reframe cancel the previous one's deferred free.

### 3.5 Waiting for it, and switching it on

```lua
-- poll at 0.1 s, give up at 5 s
if des:IsSpawned(camId) then
    local e = des:GetEntity(camId)
    local comp = e:FindComponentByName('RenderToTextureCamera')
    comp:Toggle(true)          -- the METHOD. Writing isEnabled is silently dead
    comp.fov = rig.fov         -- AFTER the enable, never before
end
```

**`fov` must be written LATE.** `Toggle(true)` re-initialises the component from its authored values,
so an fov written before it is discarded and you get the stock wide lens (measured: FACE numbers, no
zoom). Everything else about the rig rides in the spawn transform, so this is the only late write.

Write the 5 s timeout to say *"camera never streamed in — is the archive mounted?"*. A missing
archive and a bad position otherwise produce the same silence.

---

## 4. The subject

### 4.1 The spawn

```lua
local spec = DynamicEntitySpec.new()
spec.recordID       = TweakDBID.new('Character.Panam')   -- a record NAME, always (see below)
spec.appearanceName = CName.new('panam_default')
spec.position       = Vector4.new(at.x, at.y, at.z, 1.0)
spec.orientation    = EulerAngles.new(0, 0, yaw):ToQuat()
spec.persistState   = false
spec.persistSpawn   = false      -- TRANSIENT: gone on save/load, so nothing accumulates
spec.alwaysSpawned  = true       -- exists AND DRAWS at range        <- the lever
spec.spawnInView    = true       -- false hides the pop-in, at the cost of a wait
spec.active         = true
spec.tags           = { CName.new(COPY_TAG), CName.new(COPY_TAG .. '_' .. key) }
```

**Pass a record NAME, not a raw `TweakDBID` object.** Passing the ID for a record that does not
stringify is accepted by `CreateEntity` and even renders — and then the puppet has no record, and
the engine dies on a null a few seconds later. Three crash dumps, one address. Resolve a name or
refuse.

Check for id 0 here too, and check it **before** you write the id into any registry. A spawn rejected
outright otherwise leaves a zero id filed under the character's key, and every later lookup hands it
out as though it were a body.

### 4.2 The calls that make it real at range

```lua
-- in the spawn callback, once you have the EntityID:
Game.GetAnimationSystem():SetForcedVisible(id, true)     -- releases anim-graph culling
MyPlugin.ForceHighestLod(id, true)                        -- your RED4ext native: ScheduleEntitySetLOD(0x20)
```

`alwaysSpawned` keeps it existing and drawing; `SetForcedVisible` makes it move. Without the second
the subject stands frozen. **Pair it with `(id, false)` at teardown** — a leaked forced-visible flag
outlives the delete.

The third holds the body at its highest LOD, which is what keeps cloth whole and a
`compiledEntityLODFlags = 0` character from coming out as its faceless stand-in. It is the half of a
scene's `forceMaxVisibility` that script cannot reach: [01 §6](01-engine-primitives.md) has the engine
call and the RED4ext code. Call it **once per body** — and again from your guard tick until it reports
held, because a body can arrive before its runtime scene exists — and clear it **once** at teardown,
while the body still answers. A body that arrives after its shoot was stopped must not claim it.

### 4.3 Pin it against the duplicate watcher

If your mod (or another) runs any "one body per character" reconciliation, the studio's copy has to
be exempt from it. Ours was not, at first: a community body of the same character materialised 21 m
from the studio the moment the player arrived, and the duplicate handover deleted the filmed subject
twice before a pin went in.

Whatever the mechanism, the rule is that the body in front of the lens is not a candidate for
anything. Mark it, and make the handover refuse marked keys.

### 4.4 Marking the body as a prop

A body you spawned to be filmed is not a person in the room. If anything in your mod broadcasts world
events off animation or workspot mounts, declare the studio body **before** you mount its pose — the
mount is what announces it. Otherwise the call pose emits "X started on a call" into the event
channel, and a follower standing next to the player, 8 km from the body, is handed it as something
they witnessed and says so out loud.

### 4.5 The pose

Optional, and a refusal should come out as a plain idle rather than as a failed call. Two routes:

| route | how |
|---|---|
| **workspot host** | spawn an invisible device `.ent` carrying workspot resources at the subject's spot, then `Game.GetWorkspotSystem():PlayInDeviceSimple(host, npc, false, CName.new(slot), nil, CName.new('None'), slide, 1, host)`. The authored workspot drives entries, idles and variations — no clip names needed |
| **AI command** | build a `workspotNode` AI command and `SendCommand` it through the puppet's `AIControllerComponent` — needs a real spot node in the world |

Two things the host route taught, both expensive:

- **Pre-warm the host while the subject streams in.** The mount waits on the host (~1 s), and paying
  that *after* the body attaches is a visible first-call jerk: the feed comes up on a free-standing
  body that snaps into the pose a beat later. Spawn the host **at the subject's position** — a host
  0.25 m away is not reused, and a host spawned at "the usual studio spot" while the subject stands
  somewhere else makes the world's singleton host churn twice and buys nothing.
- **Mount ONCE.** If your spawn callback can be re-entered — a poll that re-runs until it returns
  true — a `Perform`-style call inside it will delete and respawn the anim host every tick. We
  measured ~15 hosts in 5 s, no mount ever surviving streaming, and the body then left workspot-less
  for ambient AI to walk away with. Return "done" from the callback.

---

## 5. Where the shoot happens

`opts.at` defaults to the studio spot. A caller that passes a real world position is asking for a
body standing somewhere real instead — a photo with a world behind it rather than a lit box. Skip the
room spawn in that case; the point of standing somewhere real is not to put a grey box around it.

It has to be near the player. The render target holds only what the streaming system is holding, so a
placement across the city renders an empty room's worth of nothing. That is a property of the engine,
not of your code ([01 §5](01-engine-primitives.md)).

---

## 6. Making them look alive

At studio range the game's facial animgraph never evaluates: the subject does not blink, and no
look-at moves their eyes. Head motion still works, because that is the look-at layer rather than the
facial graph.

### 6.1 The look-at

`LookAtAddEvent`, queued on the puppet, with its `ReactionManager` component holding the handle:

```lua
local stim = npc:FindComponentByName('ReactionManager')   -- find by NAME; this is the call that works
stim:DeactiveLookAt()                                     -- or requests stack

local ev = LookAtAddEvent.new()
ev:SetEntityTarget(cameraEntity, '', Vector4.new(0,0,0,0))
ev:SetStyle(animLookAtStyle.Normal)
ev.request.limits.softLimitDegrees  = 360.0
ev.request.limits.hardLimitDegrees  = 270.0
ev.request.limits.hardLimitDistance = 1000000.0
ev.request.limits.backLimitDegrees  = 210.0
ev.request.calculatePositionInParentSpace = true   -- NOT settled: see below
ev.request.transitionSpeed          = 80.0   -- vanilla's holocall preset
ev.bodyPart = 'Eyes'
ev:SetAdditionalPartsArray(parts)            -- see below
npc:QueueEvent(ev)
stim.lookatEvent = ev                        -- DeactiveLookAt needs the handle
```

`calculatePositionInParentSpace` is the one field in that block nobody has settled. Nothing in the
decompile says which space the target resolves in, CDPR sets it from a TweakDB preset, and every
in-script `SetEntityTarget` passes an empty offset — so no vanilla call site tells the two apart. It
became the prime suspect the day a studio subject turned her head onto the lens and the gaze still
landed *to the side*, which is what a world-space target resolved in some parent's frame looks like.
Keep it a variable rather than a constant: it is the first thing to A/B when the head is right and
the eyes are not.

The target is the camera **entity**, and the camera's origin IS its lens — so a plain look-at with no
offset is already correct at every shot. (Vanilla parks a marker 0.088 m in front of its lens for
exactly this.)

Do not "improve" it by aiming at eye height. The picture is rendered *from* the lens, so a gaze meets
the viewer's eyes only if its ray passes *through* the lens. Lifting the target to eye height aims
11.8° above the lens on a bust shot and 15.6° on a body shot — most of the way to the top of a 45°
frame — and renders as looking over the viewer's head. Looking *down* at a low-mounted camera is what
a person does, and it is what puts their pupils on the viewer.

**`ev.bodyPart` only names which part LEADS.** It grants no authority to override an animation. That
authority is `suppress`, and it exists only on a `LookAtPartRequest` — so with Head and Chest listed
and Eyes absent, the head comes round onto the target while the eyes stay wherever the playing clip
put them. Measured with the lens 20.4° off the subject's facing: her head was correct and her gaze
missed by exactly that 20°. A dead-front shot looks right only because there the error is zero.

```lua
local r = LookAtPartRequest.new()
r.partName = 'Eyes'
r.weight   = 1.0      -- on Eyes this is blendWeight: 0.0 blends NOTHING in
r.suppress = 1.0
r.mode     = 0
```

**The scalar means the opposite thing on Eyes.** Every other part treats `weight` as stiffness, where
0.0 is a hard lock; the Eyes part of the facial graph exposes `blendWeight`, which is how much of the
look to blend *in*. The 0.0 that locks a head is a guaranteed no-op on eyes.

The array holds exactly two (`StaticArray<anim::LookAtPartRequest, 2> additionalParts`) — a third
entry is at best dropped. Priority: Eyes > Head > Chest.

For the head itself, weight ~0.05: a near-lock rather than the dead-eyed 0.00. Call workspots animate
their own look-arounds, and at face zoom a head drifting off with the pose reads as "not looking at
camera".

Re-request on a cycle. The engine drops stale look-ats; every ~5 s is enough, with a 1 s retry when a
request could not go out at all. That last case is the *normal* first tick — the lens streams in on a
0.1 s poll while the subject is still coming up.

### 6.2 Blink and eye aim

The look-at layer will not blink for you at range. Blinking and precise eye aim want a per-frame
facial contribution, which in practice means a small RED4ext native that takes an npcId, a head
orientation and a direction, and pushes an additive eye/lid pose. Out of scope here. What is in
scope is the geometry that native has to be given:

- **the head bone's world transform**, read off the puppet's `entSlotComponent` — and that
  component is found **by class, not by name**. The idiom everywhere else in this guide is
  `FindComponentByName`; reach for it here and you get nothing, because the body carries five
  `entSlotComponent`s and none of them is called `SlotComponent`. Iterate `GetComponents()` and match
  on `GetClassName()`. (`Head` itself resolves on the `Item_Attachment_Slot` component and is live.)
  Then:
  `c:GetSlotTransform(CName.new('Head'))`. `WorldPosition` is fixed-point — `.x` is a struct until
  `WorldPosition.ToVector4(pos)` converts it;
- **which local axis of that bone is "forward" cannot be derived offline**, and getting it wrong is
  not subtle: the real forward lands in the pitch term, pitch saturates, and the eyes roll down and
  stay there — which on screen reads as *eyes closed*, not as a bad aim. Measure it instead. The
  engine's head look-at already has them roughly on the lens, so the right basis leaves a small
  residual (~10°) and every wrong one reports 70–160°. Take the smallest, refuse a candidate that is
  not upright (a residual cannot tell a basis from its mirror), and log which you took;
- **do not aim until the basis is measured.** The scan needs the body streamed, so it lands ~1.5 s
  after the bind; aiming through a default guess for that 1.5 s slams the eyes into a corner at the
  start of every call. Centred eyes are the better wrong answer;
- the basis is a property of the **head rig**, which is the same for every NPC, so it is one scan per
  session and not one per subject.

### 6.3 Knowing when the subject has actually arrived

This is the bug worth the most to prevent. The two halves of a gaze land on different clocks:

| half | when |
|---|---|
| head look-at | the guard's first tick with a body — under 1 s |
| eye aim | after the head-basis scan (1.5 s on the first subject of a session) **and then the next tick** |

So a photograph taken on a fixed 1 s timer is taken before the eyes were aimed at anything. What you
get is a correct file of somebody staring into the middle distance, with nothing about it that looks
broken. On a call the same rig looks fine, for no better reason than that a call lasts seconds.

Expose `Settled() -> (ok, why)` that names the missing half — *"no eye aim has been pushed yet"* and
*"mid-aversion"* have different fixes and look identical on screen — and have any shutter wait on it
with a bounded ceiling (4 s, then shoot anyway and say what never landed).

### 6.4 Present in one call

A caller made to run face-bind, then wardrobe, then emotion, then gaze, then wait a fixed second will
get the order wrong. Give them one call:

```lua
Studio.Present{ npc = 'panam', look = 'lens', gaze = 'intimate',
                emotion = { name = 'joy', weight = 0.6 },
                wear = 'relaxed' }
```

Three rules inside it:

- **the face bind precedes the expression.** An emotion call keyed on an npcId needs the bind that
  ties that id to this body. A wrong order is silent: the picture arrives, the face is just not the
  one asked for;
- **every axis fails soft.** A wardrobe that refuses, an emotion the solver drops, a gaze that is
  refused — each of those is a plainer picture, never a failed shoot. Report, do not refuse;
- **it does not own the pose.** A workspot is chosen *with* the body, so the pose stays in the spawn
  recipe.

---

## 7. The guard tick

One slow ticker at 1 s that does two things and corrects nothing:

1. **re-pins the gaze** onto the lens (§6.1);
2. **measures framing drift**: solve where the lens *would* stand for this shot given where the
   subject actually is now, and compare against where it was spawned. Report once per excursion, not
   once per tick.

```lua
local want = solve(_shot, feet, fyaw)
local off  = math.abs(want.x-_rig.x) + math.abs(want.y-_rig.y) + math.abs(want.z-_rig.z)
if off >= _shot.frameH * 0.25 then ... end     -- a quarter of the frame is worth a log line
```

Measuring beats chasing because "she looks off-centre" has three causes — the pose walked, the shot
is mis-solved, or nothing moved at all and the fault is elsewhere — and a number tells them apart. A
reframe is then a deliberate respawn rather than a per-frame correction.

With a group, measure against the **anchor**, not the lead. The lead deliberately stands half a
spacing off it, so comparing the two reports a 0.65 m excursion on every group shot and asks for a
reframe that would frame the lead alone and crop everybody else out.

---

## 8. Teardown — the part to build first

### 8.1 The order

One function, this order, reachable from **every live-world exit** (panel close, rebuild, hang-up,
photo taken):

1. `Gaze.StopLookAt(body)` — while the body still exists to release;
2. `Game.GetAnimationSystem():SetForcedVisible(id, false)` — **never leak a forced-visible body**;
3. clear any per-body marks (service-body, pin, facial registration) — a stale entry misclassifies
   whatever the engine puts in that key next;
4. camera component `Toggle(false)` and close the widget;
5. delete the subject(s), then the room, then the lens;
6. clear facts/canaries if you used a quest route.

Steps 1–4 run for **every** extra body too, not just the lead. None of the lead's calls can see them.

### 8.2 The lens delete waits

**Toggling the lens off and freeing it in the same frame crashed two calls** — inside
`DynamicBuffer::ResizeBuffer`, with no mod frames on the stack, because the fault is on the render
thread, still holding that camera's target.

`Toggle(false)` is a request rather than a barrier, and `IsEnabled()` goes false on the first poll
after it, so all it tells you is that the toggle was *recorded*. It says nothing about the render
thread letting go. What stands between "stop drawing" and "free the entity" is a frame count. Ours is
30, against an in-house default of 12 for other spawns; treat it as a measurement in progress rather
than a settled number. Everything else tears down immediately, so nothing observes a half-dead studio.

### 8.3 The session boundary is NOT one of the exits

**Every `Game.GetXxxSystem()` stub reads the world pointer off the GameInstance and access-violates
once it is null, and `pcall` catches none of it.** Two confirmed CTDs were a teardown's
`GetAnimationSystem` running from the player-gone path of a broken load.

At a session boundary, forget instead: halt timers, drop ids, put the panel back to "not built".
Entities, forced-visible flags and per-session systems die with the world, so there is nothing to
undo.

Wire it to whatever your framework gives you for session end / pre-load, and make it a *different
function* from `Stop` so that nobody can accidentally route one into the other.

### 8.4 Save / load

The subject is transient (`persistSpawn = false`), so after a load the body is gone while your state
still points at it. A load hook has to reset the studio to "not built".

### 8.5 Sweep at activation

Tag everything, and sweep those tags when a world comes up. Anything still wearing a studio tag at
that moment is debris a crash left behind — the two crashes in §8.2 each leaked a subject and a lens,
and
without a sweep they would still be out there, drawn, forever.

### 8.6 The unattended render

One render-thread AV (D3D12, wild pointer 4 GB below a live buffer, no mod frames) after ~3.5 minutes
of an unattended forced-visible remote render. Unproven as a cause — nobody reproduced it. But the
mitigation costs nothing and is correct on its own terms: let the feed and the forced-visible flag
live exactly as long as somebody is looking at the picture, and no longer.

---

## 9. What the log has to say

Every one of these came out of a session that would have been shorter with the line in it:

| print | why |
|---|---|
| the solved rig: `shot, position, yaw, pitch, dist, fov, frameH, aimZ` | half of "the framing is wrong" is a wrong-signed yaw you can read straight off this |
| `CreateEntity -> id=<hash>` for every spawn | id 0 vs a real id is the difference between "rejected" and "slow" |
| **why** a gaze did not go out: no module / no body / refused | "she isn't looking at us" otherwise has three indistinguishable causes and no log line about any of them |
| which pose was asked for and how far it got | "she is in the default idle" is undiagnosable without it, and a `Perform` returning true means *accepted*, not mounted |
| the drift number, once per excursion | see §7 |
| the eye basis taken **and the runner-up** | proves the scan discriminated rather than picked the first row |
