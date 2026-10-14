# 6. Pitfalls

Every row here cost at least a session. Grouped by where you meet them, not by how bad they are.

---

## Baking

| trap | what happens | fix |
|---|---|---|
| **constructing a CR2W node** | CR2W has no "field absent": every field you did not write materialises as a default, so an invented node ships dozens of wrong values | serialize a real cooked donor and mutate only what you mean |
| **patching only `components`, not knowing about the cooked chunks** | the file looks right in JSON. At runtime it **spawns the donor**: a corridor lamp where the room should be | write `components` only; let `deserialize` rebuild `compiledData.Data.Chunks`. Verify counts each component **twice** |
| **hand-writing the chunk list instead** | invalid CR2W; `deserialize` refuses the file | see above |
| **copying a handle instead of resolving it** | `{"HandleRefId": "2"}` is a pointer; writing `halfExtents` onto it writes onto a dict with no such field, silently. Every slab shares the donor's 16 cm box | resolve the real node, give each instance its own inline copy |
| **duplicate `HandleId`s** | thirteen colliders all claiming `"0"` — `deserialize` refuses the whole file | unique per file |
| **patching the first `$type` hit only** | `holocall_camera.ent` has **two** camera components (two appearances); one is yours, one is vanilla | patch every hit |
| **inheriting the donor's `meshAppearance`** | an appearance name a box mesh does not have; the engine substitutes something arbitrary and the floor comes out watery | take the *node's* appearance (`default` for these) |
| **sizing a collider without its pivot** | `q110_black_box.mesh` has its origin in a corner; the box sits half a slab off and every inner wall is walk-through while the shell is solid | `halfExtents` from the size, `localToBody` from the bounding-box centre |
| **no colliders at all** | the room is scenery: you fall through the floor, and so does the subject | one box collider per slab — and check it in game, ours was still reported non-solid |
| **filtering the sector by bounds only** | a Japanese-themed set in the same sector arrives inside your studio as "Chinese ornaments with paper lamps" | filter by mesh name too |
| **assuming z 4.75 is the floor** | it is the **ceiling**. The floor is −1.03 | measure once, write it down |
| **carrying another room's subject offset across** | CDPR's origin is the floor slab's centre and the slab is 0.4 thick; our room's offset is +1.1 | derive the offset per room |
| **leaving `phasePrefabs` in a copied `.questphase`** | a **loop during loading** — saves stall at 75% on reload, and nothing looks wrong until somebody reloads | strip it (01 §4.3.1) |
| **attaching an unconditional phase to the root quest** | the root quest is always running, so your test scaffolding is in every save from the load screen | gate on your own fact, always |
| **`always_loaded` for a test body** | exactly what it says: a second copy of a character in every save, forever, with no off switch | never for scaffolding |
| **forgetting the restart** | `.archive` mounts on a **full game restart** only; redscript recompiles on a full restart only | budget for it; and make a missing archive *say so* in the log |

---

## Spawning

| trap | what happens | fix |
|---|---|---|
| **id 0 treated as an id** | `CreateEntity` returns 0 when it rejects the point outright. Your poll waits its 5 s and reports a timeout, so you go looking for a slow spawn or a missing archive | check `tostring(id.hash) == '0'` (and `'0ULL'`), report the coordinate, bail |
| **writing the id into a registry before that check** | a zero id filed under a character's key; every lookup hands it out as though it were a body | check first, file second |
| **the singleton `EulerAngles:ToQuat()` form** | throws, leaves the rotation unset, logs nothing. The entity then points down its own axis — a wall, for a light | `EulerAngles.new(...):ToQuat()` |
| **passing a raw `TweakDBID` for a record that does not stringify** | accepted, renders, and the engine dies on a null a few seconds later. Three dumps, one address | resolve a record **name**, or refuse |
| **spawning at the world origin** | a spawn at (0,0,0) never streams in, and deleting it arms the next `CreateEntity` for that tag to crash | refuse an unplaced position, and refuse *before* you delete anything |
| **`alwaysSpawned` left false at range** | entity created, never becomes a body; the only symptom is `onFailed` five seconds later | true, for everything at the studio: room, lens, subject, host |
| **no `SetForcedVisible`** | the subject stands frozen at range | one call in the spawn callback; pair with `false` at teardown |
| **no highest-LOD hold** | cloth explodes into shards; a `compiledEntityLODFlags = 0` character is a faceless stand-in. Everyone else looks fine, so it reads as an asset bug | `ScheduleEntitySetLOD(body, 0x20)` from RED4ext, once per body, cleared once at teardown ([01 §6](01-engine-primitives.md)) |
| **per-character asset copies instead** | an `.ent` with the LOD flag raised fixes the stand-in only; cloth converted to a plain skinned mesh stops the shards and freezes the garment in its bind pose; the cloth's own `forceLODLevel` changes nothing | the LOD hold above; no copies |
| **holding the LOD every tick** | the scene holds once and counts its own applies; whether the engine stacks repeated Set calls is not measured | hold once, retry only until it reports held, clear once |
| **re-entrant spawn callbacks** | a pose mounted inside a poll that re-runs deletes and respawns the anim host every tick. Measured: ~15 hosts in 5 s, no mount ever surviving streaming, and the body left workspot-less | return "done" from the callback |
| **pre-warming the host at "the usual spot"** | a host is only reused within 0.25 m. A shoot placed elsewhere steals the world's singleton host to the studio and then respawns it anyway. Two churns, no benefit | pre-warm at the subject's own position |
| **two copies of one character** | a per-character registry slot and tag: the second overwrites the first's id and one teardown takes both bodies | refuse a duplicate key, lower-cased |

---

## Camera and framing

| trap | what happens | fix |
|---|---|---|
| **`atan2(dx, dy)`** | forward at yaw *t* is `(−sin t, cos t)`, so the call is `atan2(-dx, dy)`. Invisible at orbit 0 and wrong at every other angle. A wrong-signed yaw alone explains **every** black feed | read it off vanilla's own camera node and never re-derive it |
| **writing `fov` before `Toggle(true)`** | the enable re-initialises the component from its authored values; you get the stock wide lens and the numbers still look right in a dump | write `fov` after |
| **writing `isEnabled`** | silently dead | `Toggle(Bool)` + `IsEnabled()` |
| **raising `resolutionWidth` to get a bigger picture** | it succeeds, reads back and survives a toggle cycle, and nothing about the picture changes. The target is allocated by the `.dtex` | bake your own resource |
| **framing a whole figure at fov 35** | the solved distance is 3.25 m and your walls are at 3.1, so the lens sits *in a wall*. That renders the same black rectangle a dead camera does | keep every shot inside the measured clearance; widen the lens instead |
| **no dead-front control shot** | a black angled shot and a dead camera are indistinguishable | keep a FLAT row: 0 orbit, known-good numbers |
| **chasing the subject per frame** | the lens is meant to be a fixed node; per-frame correction hides the fact that the pose walked | measure the drift, report it, reframe deliberately |
| **reframing with a shared delete key** | each reframe cancels the previous one's deferred free | one key per reframe |
| **`streamingDistance` as a suspect** | 1 → 200 changes nothing; the mechanism is not distance | raise it anyway to remove it from the list, then look at streaming |

---

## Lights

| trap | what happens | fix |
|---|---|---|
| **spawning light entities** | dynamic lamps are emission-culled at range whatever you do. Intensity 15000 with `SetForcedVisible` on: measured dark | bake static light nodes into an always-loaded sector |
| **leaving `autoHideDistance` at 5** | CDPR's own rig hides itself past five metres; that is the *only* reason their studio lights never show in a feed | raise it (1000), and raise the instance's `UkFloat1` with it |
| **using a vanilla light fixture** | `corridor_light_a` ships `intensity 0` + `turnOnByDefault 0`. It spawns perfectly and lights nothing, and "spawned" in the log reads identically either way | use an emitter that actually emits, or bake the light node |
| **forgetting the fixture mesh** | a purpose-built spotlight entity brings a visible lamp model with it, so you get three lamps standing in your black box | toggle the mesh component off |
| **assuming a light's forward axis** | it is local **+Y** rotated by the quaternion (verified; runners-up miss by 6–66 cm) | verify by asserting the *miss distance* from the subject's axis, not the height |
| **cloning a bust rig for a body shot** | CDPR's three aim at 1.43 / 1.79 / 1.63 m. Below the chest their studio is black | add a figure key, a low fill at half strength, and a rim |
| **matching the fill to the key** | flattens the figure again | half strength |
| **carrying a third-party mod's yaw convention across** | a spotlight entity may use `(sin yaw, cos yaw)` where the lens uses `atan2(-dx, dy)` | derive each from its own ground truth |
| **rebasing CDPR's rig by 180°** | their subject faces yaw −132°, not −180°; the 48° error puts their cross-key on your camera's own side and the feed reads flat | know which rebase you shipped |

---

## Gaze and face

| trap | what happens | fix |
|---|---|---|
| **no Eyes `LookAtPartRequest`** | `bodyPart = 'Eyes'` only names which part *leads*; authority is `suppress`, which lives on the part request. The head comes round and the eyes stay in the clip — off by exactly the orbit angle | list Eyes explicitly; the array holds **two** entries total |
| **`weight = 0.0` on Eyes** | on every other part 0.0 is a hard lock; on Eyes the scalar is `blendWeight`, so 0.0 blends nothing in — a guaranteed no-op | 1.0 on Eyes, ~0.05 on Head |
| **aiming the gaze at eye height** | the picture is rendered *from* the lens, so a gaze meets the viewer only if its ray passes through it. Eye height aims 11.8–15.6° above the lens and reads as looking over the viewer's head | target the camera entity, no offset |
| **a wrong head-forward axis** | the real forward lands in the pitch term, pitch saturates, and the eyes roll down and hold. On screen that reads as **eyes closed** rather than as a bad aim | measure the basis; refuse a non-upright candidate (a residual cannot tell a basis from its mirror) |
| **aiming before the basis is measured** | the scan needs a streamed body (~1.5 s); aiming through the default guess for that window slams the eyes into a corner at the start of every call | no aim until measured; centred eyes are the better wrong answer |
| **a photo on a fixed 1 s timer** | taken before the eye aim landed: a correct file of somebody staring into the middle distance, with nothing about it that looks broken | wait on a `Settled()` that names the missing half, with a ceiling |
| **binding the emotion before the face** | the emotion keys on the npcId and the bind is what ties that id to this body. Silent: the picture arrives, the face is not the one asked for | face bind first |
| **not stopping the previous face** | an npcId left registered keeps taking a per-frame solve on a body being deleted, and once the id moves on nothing can unregister it | stop the old one at the top of every bind |
| **one blink seed for a group** | three people blinking in lockstep in a photograph | derive the seed from the npcId |
| **a stale look-at** | the engine drops them | re-request on a ~5 s cycle, 1 s retry when it could not go out |

---

## Teardown and lifetime

| trap | what happens | fix |
|---|---|---|
| **calling an engine system at a session boundary** | every `Game.GetXxxSystem()` stub reads the world pointer off the GameInstance and AVs once it is null. **`pcall` catches none of it.** Two confirmed CTDs | a separate `OnSessionEnd` that forgets: halt timers, drop ids, reset state |
| **freeing the camera in the frame you disabled it** | render-thread AV inside `DynamicBuffer::ResizeBuffer`, no mod frames on the stack. `Toggle(false)` is a request, not a barrier, and `IsEnabled()` goes false on the first poll after it | defer the delete by a frame count |
| **leaking the forced-visible flag** | it outlives the delete | `(id, false)` **before** the ids are dropped |
| **tearing down only the lead** | extras' bodies are as real, and none of the lead's calls can see them | loop |
| **a tag-wide delete** | takes every body wearing the tag, companions included | keyed deletes, one per character |
| **sweeping a tag nothing ever streamed under** | `DeleteTagged` over a ghost, which arms the next `CreateEntity` to die | let a real entity vouch for the tag first |
| **no sweep at world-up** | crash debris — a pinned, forced-visible, always-drawn body — stays out there for the session | register the tags for a sweep |
| **assuming the subject survives a load** | `persistSpawn = false`, so the body is gone while your state still points at it | reset to "not built" on a load hook |
| **an untracked deferred timer** | a scan scheduled 1.5 s ago fires on a world that has since been torn down, and `FindEntityByID` on a dying world AVs | track and halt every timer |

---

## Lua-specific

| trap | what happens | fix |
|---|---|---|
| **`~` for bitwise XOR** | the game is **LuaJIT (5.1)**, where that operator does not exist. A headless test runner on 5.4 accepts it, so an FNV hash written this way passes luacheck *and* the whole suite and then fails to **compile in game** — taking the module and everything downstream with it | plain arithmetic (`h = (h * 33 + byte) % 2147483647`) |
| **a `[[wiki link]]` inside a `--[[ ]]` block comment** | the `]]` ends the comment early; the rest of the file parses as code and the module silently fails to load | keep double brackets on `--` line comments |
| **calling an injected dependency at init** | some frameworks inject after your init runs (Codeware's `NewProxy` did) | poll with a cap, or defer |
| **offline-green as evidence** | a headless harness with stubbed CET globals is blind to a whole class of load-time failure | it still has to load in game |

---

## Design-level

| trap | what happens |
|---|---|
| **a tuning lab with its own copy of the recipe** | numbers dialled in the lab cannot be consumed by the shipping path; every fix is applied twice or once in the wrong place |
| **`IsUp()` as the busy check** | false for the whole window between claiming the studio and the subject streaming in. A second spawn of the same person does its worst damage inside exactly that window |
| **"could not load the studio module" treated as busy** | one missing require refuses every spawn for the session |
| **framing as a property of the character** | the same person is a face on one call and a whole figure on the next. Framing belongs to the *shot* |
| **no free-form framing surface, and no note saying so** | a new framing becomes an edit plus a restart, and the next reader assumes a control exists |
