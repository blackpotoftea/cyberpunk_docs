# A follower who rides the elevator with you

V walks into a lift with a companion behind them, picks a floor, and the cabin leaves. Out of the
box, the companion stays where they were. The floor rises and their world coordinate does not:
they are left on the floor you boarded at, or floating in an empty shaft, until some follow catch-up
teleports them back.

This guide is the fix. It uses the mechanism the game itself uses for quest NPCs in lifts, and once
the NPC is aboard it costs nothing per frame. It runs from CET Lua alone: no RED4ext, no archive, no
redscript.

**MEASURED** in game (2026-09-14, megabuilding lifts, one and two followers, up and down, a second
leg picked from inside the cabin). **Untested:** three or more riders at once, loading a save made
inside a stopped cabin, dying or loading from the menu mid-ride. They are listed in §8.

```
  V crosses the cabin's trigger      every 0.25 s while V is inside       the cabin has MOVED
  ────────────────────────────►      ───────────────────────────────►     and is now STOPPED
  LiftDevice.OnAreaEnter              teleport follower into the cabin     ──────────────────►
  (self = the lift device)            then Mount(npc → lift, no slot)      Unmount(npc)
                                      the engine carries them              (V still inside)
                                                                                  │
                                                       V leaves the cabin         ▼
                                                       ──────────────────►  warp behind V,
                                                       OnAreaExit/OnDetach  give follow back
```

---

## 1. Why the follower gets left behind

The engine carries the **player** on a moving platform: `IsOnMovingPlatform()` is a method of
`StateGameScriptInterface`, the player state machine's physics interface. A puppet has no such path.
Its position comes from AI locomotion, and the platform's motion is not an input to it. So a puppet
merely *standing* on a lift floor is not moved by it.

You cannot fix that by making them walk in, either. Every traversable device in the game opens its
off-mesh link both ways, calling `EnableOffMeshConnection()` (for AI) and `EnableForPlayer()` (for
V). The lift is the one device that calls only `EnableForPlayer()` (`lift.swift`, the
`OffMeshConnectionComponent` enable block). An NPC **cannot path into a cabin** at any distance. A
follower standing outside the doors is not running late. They are stuck. The follow AI will report
"no route" and stand there.

## 2. What the game does: it mounts them to the lift

CDPR never routes an NPC into a cabin. It walks them in on an authored spline and then **attaches
them to the lift entity**, through a quest node that appears nowhere in the decompiled scripts:
`questElevator_ManageNPCAttachment_NodeType`. You only see it by extracting the `.scene` files from
the archive (WolvenKit CLI).

The Konpeki Plaza lobby in The Heist (`q005_03_entrance.scene`), in flow order:

| node | what it does |
|---|---|
| `questElevator_ManageNPCAttachment` | `action: Attach`, `npcRef: #jackie`, `elevatorRef: #q004_dvc_yorinobu_elevator`, **`slotName: None`** |
| pause on `questCharacterMount_ConditionType` | waits for **`OnMount`**: the same condition vehicle seats use |
| interactive object manager | operates the elevator terminal |
| pause on `LiftControllerPS.IsMoving` | |
| pause on `LiftControllerPS.IsAtFloor(1)` | |
| `questElevator_ManageNPCAttachment` | `action: Detach` |
| pause on `questCharacterMount_ConditionType` | waits for **`OnUnmount`** |

This isn't a Jackie special case. A sweep of all 7067 base-game `.scene` files finds **23 scenes and 47
attach/detach calls** (Jackie, Takemura, Rogue, Kerry, Judy, Johnny and others) and **`slotName` is
`None` in every one**.

The lift entity is built to receive it. `base\gameplay\devices\elevators\base\lift_base.ent` carries
a `gameMovingPlatformMountableComponent` and an `OccupantSlotComponent` with **no slots at all**
(same shape on `neomilitary_lift.ent` and `platform_lift.ent`). Nothing needs a slot, because the
shipped path mounts without one.

Three rules follow, and the design below keeps all three:

1. **It is a real mount**, in the mounting facility, not a per-frame transform trick.
2. **Attach before the lift moves, detach after it arrives.**
3. **No slot.**

## 3. The API, from CET

`IMountingFacility` is scripted and reachable: `Game.GetMountingFacility()`.

```lua
local info    = MountingInfo.new()
info.childId  = npc:GetEntityID()
info.parentId = lift:GetEntityID()
info.slotId   = MountingSlotId.new()          -- `id` left empty: no slot

local req = MountingRequest.new()
req.lowLevelMountingInfo = info
req.preservePositionAfterMounting = true      -- attach them where they stand
Game.GetMountingFacility():Mount(req)         -- mountData is optional; leave it nil
```

Unmount is the same `MountingInfo` in an `UnmountingRequest`. `IsMountedToAnything(entityId)` tells
you when the facility has actually taken them.

**MEASURED:** all three structs construct from CET, and the facility accepts an empty `slotId` from a
scripted caller just as it does from the native quest node. This was the one open question the
archive could not answer, and no script in the game makes this call. It was settled with a
one-button probe that builds the request and mounts nobody. That probe is worth keeping in your
debug UI.

`preservePositionAfterMounting = true` is what vanilla uses for an NPC taking a vehicle seat
(`vehicleComponent.swift`).

## 4. Knowing V is in a cabin: hook it, do not poll it

`LiftDevice.OnAreaEnter` and `OnAreaExit` are scripted callbacks, fired when anything crosses a
cabin's trigger volume. The useful detail is that **`self` is the lift device**, which is exactly
the handle `Mount` needs.

```lua
Observe('LiftDevice', 'OnAreaEnter', function(self, trigger)
    local who = EntityGameInterface.GetEntity(trigger.activator)
    Elevator.OnEnter(self, who)
end)
Observe('LiftDevice', 'OnAreaExit', function(self, trigger)
    local who = EntityGameInterface.GetEntity(trigger.activator)
    Elevator.OnExit(self, who, false)
end)
-- The cabin streaming out with V inside reads to the engine as V leaving, and has no activator.
Observe('LiftDevice', 'OnDetach', function(self)
    Elevator.OnExit(self, nil, true)
end)
```

- **The `IsPlayer()` check is yours to make.** The volume fires for every pedestrian. Vanilla does
  the same test before touching its blackboard.
- **Gate the hooks on session state.** An area edge arriving mid-load is the world being torn down,
  not V walking. A raw `Observe` that touches entities then is a crash. Wrap each callback in
  whatever "is gameplay live" check your mod has.
- **`OnDetach` passes an explicit flag; do not infer V from a nil activator.** The unwrap can leave
  the activator nil because it threw, too. If you treat nil as "V", any pedestrian with a failed
  unwrap ends the visit and unmounts every rider halfway up the shaft.

With the hooks in place, the common case costs nothing: if V is not in a lift and nobody is riding,
the tick returns without a single game call. While V is inside, the cabin itself answers whether it
is moving:

```lua
local mode = lift:GetMovingMode()   -- 0 stopped, 1 up, -1 down, 2 other
```

(`LiftDevice.IsPlayerInsideElevator` and `GetCurrentElevator` exist as statics, but both read the
player blackboard, so they are not an independent source.)

## 5. The machine

| step | when | what |
|---|---|---|
| **BOARD** | V is inside; sweep every 0.25 s | for each follower who passes §6's refusals: stop following, **teleport into a spot in the cabin**, then `Mount`. Phase `mounting` |
| **RIDE** | `IsMountedToAnything` is true | phase `riding`. Then **nothing**. The engine carries them |
| **ARRIVE** | the cabin **has moved** and is **now stopped** | `Unmount`. Do **not** resume following yet |
| **AGAIN** | unmounted, and the cabin moves again | `Mount` again. V picked another floor from inside |
| **EXIT** | `OnAreaExit` / `OnDetach`, or the lift handle is dead | warp them behind V on V's own floor height, give the follow role back, re-issue follow |

### 5.1 Boarding is a teleport, then a mount, in that order

- **They cannot walk in (§1), so the teleport *is* the boarding.** Without it, the only way anyone
  gets aboard is your follow catch-up happening to fire. Measured: two followers standing together
  boarded five seconds apart, each exactly when its catch-up warp fired.
- **Mounting is not placing.** `preservePositionAfterMounting` attaches them wherever they stand.
  Measured: riders piled into one spot, and a follower beside the doors rode the whole trip attached
  **outside** the cabin.
- **Step from V towards the lift's own position.** The lift entity's position is the centre of the
  box, so a step from V towards it lands inside whichever wall V is against. A fixed offset from V's
  facing does not: if V faces a wall, "behind V" is through it. Spread riders laterally by a slot
  index (0.55 m per rank, alternating sides), and **count riders already aboard**, or a late arrival
  is given the first rider's spot. Set yaw once, facing V.
- **Place first, then mount.** A teleport after the mount fights the attachment.
- The teleport is an `AITeleportCommand` sent through the AI controller with `doNavTest = false`.
  The cabin floor has no navmesh, so a nav-tested teleport is refused.

### 5.2 Boarding is a window, not an edge

V crosses the trigger volume a pace or two ahead of whoever follows. An edge-only check runs on the
one frame when the follower is still outside the doors (measured). So sweep on the edge, then every 0.25 s
for as long as V is inside, and do not let one rider aboard stop the next from boarding.

### 5.3 Who counts as "with V"

- **3D distance, not flat.** A lift shaft is the one place where 2D distance fails: somebody left on
  the floor below is directly under V and reads zero metres away.
- **A wide range while the doors are open, and a tight one once the cabin moves.** About 25 m is a
  reasonable "travelling with V" radius at the floor. Leave it active during the trip and anyone who
  drifts within 25 m in 3D, several storeys away through the shaft, gets teleported into a moving
  lift. Once `moving`, drop to about 3 m: only somebody already in the cabin comes along.
- **Do not refuse just because the cabin is moving.** That check refused *every* boarding in play.
  The enter edge does not always mean the doors are closing. Turn the feature on mid-ride and you
  arrive moving, which is still a fine time to pick up somebody standing in the cabin.

### 5.4 Arrival needs both halves

**Release on "has moved, and is now stopped", never on "stopped".** A cabin V has just entered is
stopped. If you release on `not moving` alone, you unmount them the frame the mount lands and strand
them on the boarding floor. That brings back the original bug from the other end. CDPR's graph has
the same two gates in the same order (`IsMoving`, then `IsAtFloor`). Keep a `moved` latch per rider.

### 5.5 Unmount at the floor, but resume following only once V is out

CDPR detaches at the floor and walks the NPC out on a spline. You have no spline, and a body
released in a cabin is standing on a floor with **no navmesh connected to the world** (§1). A follow
command issued there cannot path.

So split the two: **unmount when the cabin arrives** (the body is then free before anything else
wants to move it), and **resume following only when V leaves the cabin**. Do it in this order:

1. warp them behind V **at V's Z**, not their own: their own Z is the cabin floor you are trying to
   get them off,
2. give the follow role back,
3. re-issue the follow command, and retry it once or twice over the next few seconds. A teleport
   is an AI command and can replace the follow command instead of running alongside it.

### 5.6 Suspend following for the whole ride

Whatever re-issues the follow command on a timer will fight a mount just as it fights a teleport.
Take the follower out of it for the ride, and give your "is this body busy" check a
"riding" answer that holds through **both** unmounted windows: phase `mounting`, and after the
arrival unmount while the rider waits for V's next floor. `IsMountedToAnything` is false in both,
so asking the facility alone is not enough.

When you take the follow role away, go through the engine's own role-change sequence
(`AIControllerComponent:OnAIRoleChanged(AINoRole.new(), currentRole)`). Calling `SetAIRole` directly
leaves the follower role's gameplay package applied. And **never clear the role on a crowd-record
body** (`npc:IsCrowd()`): a crowd puppet has no senses component, and the role-change path
dereferences it. The result is an instant native access violation, and no TweakDB edit adds the component.
For a crowd body, stop the follow command and leave the role alone.

## 6. Who must not be mounted

Each of these is a body you must not hand to the mounting facility:

- **A body a quest scene is driving.** If the scene system already owns the puppet, mounting it is a
  crash. Read the NPC's community or owner by whatever means you have. **An unreadable answer is a
  refusal, not a pass.** That one check is the whole defence.
- **Somebody told to wait.** Asking them to stay and then carrying them up three floors is the wrong
  answer.
- **A copy, when the real one is present.** If you spawn copies of story NPCs, never mount your copy
  into a lift that may be carrying the game's own.
- **Anyone already mounted to something else** (a car seat). A body cannot be in a car and a lift
  at once.
- **Do not refuse on combat.** V leaving a fight by lift is the same request as leaving by car. Only
  mount a body already within range, though. Never drag somebody across a firefight.

## 7. Every way out has to reach the unmount, or nothing

Nothing times out a mount. Every exit (V walking out, the lift streaming out, the body dying, a
session boundary) has to either unmount or prove that it does not need to. Two teardowns, and
they are not interchangeable:

| teardown | when | does |
|---|---|---|
| **release all** | a live world: a debug button, switching the feature off mid-ride | unmount, warp behind V, give follow back. **Then latch the visit closed** so the next sweep does not re-board the people you just released (V is still inside, so the sweep would) |
| **forget** | a session ending: load, quit to menu | clear your rows and **touch no engine at all**. An engine call on a body in a world being destroyed is the worst call at the worst time. Nothing leaks, because the mount is runtime state on two entities that are both being freed |

Smaller traps, each of them hit in play:

- **Compare cabins by entity ID, never by handle.** CET returns a fresh Lua wrapper per call, so
  `held ~= lift` is true for the *same* cabin every time. Measured: `OnAreaExit` returned early on
  every exit, and a rider was never released. If either ID is unreadable, **end the visit**. A
  mistaken release costs a warp; a mistaken hold strands somebody mounted for the session.
- **A failed read is not "V left".** If `GetMovingMode` throws, return *unknown* and do nothing that
  tick. Reading it as "not inside" unmounts every rider mid-shaft, onto a floor with no navmesh.
- **A failed mount must not be retried at 4 Hz.** The retry is not the cheap part: stopping follow,
  clearing a role and sending a teleport four times a second, on a live body. Skip that NPC for the
  rest of this visit, and clear the skip on the next `OnAreaEnter`.
- **Do not store a raw entity handle in a module table across sessions.** Entity slots are reused,
  so a stale handle passes `IsDefined` and points at somebody else's memory, and an RTTI call on it
  is an uncatchable crash. Store the entity ID and re-resolve, or invalidate every stored handle at
  session teardown.
- **Anything else that positions your followers has to stand down for riders.** A conversation
  system holding people at world slots will chase the cabin down the shaft, then answer the
  release with a follow command the rider cannot path. Measured. It has to ask "is this body
  riding?" and leave it alone if so.
- **The "V is inside" flag is an edge, not persistent truth.** Never save it. After loading a save
  made in a stopped cabin, you are inside only if the trigger volume re-fires `OnAreaEnter`.
  (Mid-*travel* is not a case: the game will not save while the platform moves,
  `gameSaveLockReason.PlayerOnMovingPlatform`.)
- **Log a refusal once per reason, not once per sweep.** At 4 Hz for a whole ride, a repeated line
  buries the one that changed. Log both outcomes of the exit hook as well: a silent hook hid the
  handle-comparison bug above for a whole ride.

## 8. What has not been run

| case | expectation |
|---|---|
| three or more riders | the lateral spread is the only thing that decides capacity; the engine counts nothing (the occupant slots are empty) |
| load a save made in a stopped cabin | either the volume re-fires and boarding works, or you are blind until V steps out and back in. Both are safe; which one happens is unknown |
| a menu load or V's death mid-ride | the *forget* teardown should leave nothing filed as riding |
| pointing it at a scene-owned body | the refusal line, not a crash. The refusal exists because the crash has been seen elsewhere |
| open moving platforms (`PlatformDevice`) | out of scope; they record the player on their own device state, not via `LiftDevice`. `platform_lift.ent` carries the same mountable component, so the mount itself should extend |

## Reference

[`snippets/elevator.lua`](snippets/elevator.lua): the whole machine in one file. You inject your
party list and four follow hooks. It is distilled from a working implementation, and it is
syntax-checked only in this form: port it, don't paste it.

Ground truth used throughout: CDPR's decompiled redscript (`lift.swift`, `vehicleComponent.swift`,
`aiComponent.swift`, the orphans dump for `IMountingFacility` / `MountingRequest` / `MountingInfo`),
and the base-game `.scene` and `.ent` files extracted with the WolvenKit CLI.
