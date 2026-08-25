# 2. The assets you have to bake

Three archives. None of them overrides anything vanilla — every file is **added** under your own
depot folder, so the vanilla path stays working and an A/B is always one flag away.

| archive | ships | why it cannot be done at runtime |
|---|---|---|
| `mymod_holo.archive` | `mymod\holo\rt.dtex` + `atlas.inkatlas` + `camera.ent` | the render target's size is declared by the resource; the component property is bookkeeping ([01 §2](01-engine-primitives.md)) |
| `mymod_room.archive` | `mymod\holo\room.ent` | `DynamicEntitySpec` has **no scale**, and the room is made of heavily scaled slabs |
| `mymod_lights.archive` + `.archive.xl` | `mymod\holo\lights.streamingsector` + `.streamingblock` | dynamic lights are emission-culled at range; only a sector-owned static light survives |

**An `.archive` only mounts on a FULL game restart.** A "reload all mods" will not do it and
neither will a CET reload.
Budget for it in every iteration loop — it is the main reason to keep light *tuning* out of the bake
if you can (§3.5).

---

## 1. The CR2W rules that make a bake correct

These are not style preferences. Each one is a bug that shipped.

### 1.1 CR2W has no "field absent"

A node authored with a subset of fields round-trips with the rest materialised as **defaults**. So
**never construct a node.** Serialize a real cooked file, mutate the two or three values that
matter, leave every other field exactly as CDPR cooked it.

Where you genuinely have no donor — a light node in a sector you are authoring from scratch — copy a
real one field for field out of a serialized vanilla sector and change only what you mean to.

### 1.2 Find nodes by `$type`

An `.ent` stores components in a place that differs by file, and a hardcoded path that silently
matches nothing bakes a file that looks fine and changes nothing.

```python
def walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values(): yield from walk(v)
    elif isinstance(node, list):
        for v in node: yield from walk(v)

hits = [n for n in walk(root) if n.get("$type") == "gameuiHolocallCameraComponent"]
if not hits:
    raise SystemExit("shape changed — bake aborted")   # a miss must be loud
```

**Patch every hit, not the first.** `holocall_camera.ent` carries **two** camera components, one per
appearance; patch one and you ship a camera that is yours in one appearance and vanilla's in the
other.

### 1.3 An `.ent` carries its component graph TWICE

`components`, and the cooked `compiledData.Data.Chunks` the engine actually reads. Replace only the
first and you get a file that looks right in JSON and **spawns the donor** at runtime — a corridor
lamp instead of a room.

The rule that works: **write into `components` only, and let WolvenKit rebuild the cooked side on
`deserialize`.** Writing the chunk list by hand produces invalid CR2W, because those entries are
linked by `HandleId` and do not survive being swapped out. Your verify step will then count each
component **twice**; that doubling is the file being right, not the room being built twice.

### 1.4 A handle is a pointer

In `components`, a collider's shape is stored as `{"HandleRefId": "2"}` — a pointer. The real
`physicsColliderBox` with the `halfExtents` exists once, elsewhere in the file. Copy the reference,
write `halfExtents` onto it, and you have written onto a dict that has no such field, silently:
every slab ends up sharing the donor's 16 cm lamp box.

Give each instance its own inline copy of the real node.

### 1.5 `HandleId`s are unique per FILE

Thirteen colliders all claiming `"0"` is not valid CR2W and `deserialize` refuses the whole thing.

### 1.6 Verify by re-serializing what you produced

"The script did not crash" is not evidence that the bytes say what you meant. Every bake in this
guide ends the same way: copy the produced file to a scratch dir, `convert serialize` it, assert the
values, refuse to deploy on a failure. One subprocess call, and it catches a field lost in the
round-trip — which is otherwise a black feed you debug for a day.

---

## 2. Bake 1 — your own render target

Three files, each a copy of a vanilla one with a single meaningful change.

```
mymod\holo\rt.dtex        <- copy of holocall_camera_render_texture.dtex, width/height raised
mymod\holo\atlas.inkatlas <- copy of holocall_camera_texture_atlas.inkatlas, slot -> our dtex
mymod\holo\camera.ent     <- copy of holocall_camera.ent, dynamicTextureRes -> our dtex
```

### 2.1 The pipeline, in four CLI calls

```bash
WolvenKit.CLI.exe extract "<game>\archive\pc\content" -w "*holocall_camera*" -o build\vanilla
WolvenKit.CLI.exe convert serialize   build\vanilla\...\holocall_camera.ent      # -> .ent.json
#   ... mutate the json in Python ...
WolvenKit.CLI.exe convert deserialize build\json\camera.ent.json -o build\mymod_holo\mymod\holo
WolvenKit.CLI.exe pack build\mymod_holo -o build                                # -> mymod_holo.archive
```

Write the intermediate `.json` **outside** the depot tree. `pack` ships everything inside the folder
it is given, and a stray `.json` is dead weight in the archive.

### 2.2 What to change

| file | field | value | note |
|---|---|---|---|
| `.dtex` | `width`, `height` | `1024` / `1024` | or `1280 x 720` for a photo rather than a bust |
| `.dtex` | `scaleToViewport` | `1` (optional) | tracks the viewport instead of a fixed size. **Untested** |
| `.inkatlas` | `inkDynamicTextureSlot.texture.DepotPath` | your `.dtex` | assert `parts[0].partName == "whole"` survived — the widget binds it by name |
| `.ent` | `dynamicTextureRes.DepotPath` (**every** camera component) | your `.dtex` | |
| `.ent` | `resolutionWidth` / `resolutionHeight` | match the dtex | cosmetic, but it keeps a dump honest |
| `.ent` | `fov` | leave at 35 | you will write it at runtime anyway ([03 §3.5](03-the-runtime.md)) |
| `.ent` | `streamingDistance` | `200` | vanilla ships `1`, which is fine for a camera that never left its own scene. Yours has to keep rendering a subject the player walked away from |

Reference implementation: [`snippets/bake_render_target.py`](snippets/bake_render_target.py).

### 2.3 Bake TWO sets if you also want captures

One `.dtex` is one feed at a time. A *call feed* (a widget shows it live) and a *capture target*
(nothing bound to it; its job is to be read back out of D3D12) have to be separate resources, or a
capture blanks the picture the player is looking at.

If you do go on to write a readback native, give the capture target a resolution nothing else in the
engine would pick. The readback identifies its texture by size, and at 1024x1024, 43 unrelated
textures matched in seven seconds (MEASURED). Something like `1017 x 573` is deliberately odd.

---

## 3. Bake 2 — the room, as ONE entity

### 3.1 Why the room ships as one entity

The vanilla studio is not an entity and cannot be spawned. It is ~20 `worldStaticMeshNode`s plus a
few hundred `worldStaticLightNode`s baked into a **quest** sector that only exists while a real
holocall is running.

Nor can it be rebuilt by spawning entities, because the room is made of heavily scaled slabs —
`box.w2mesh` at **17.05 x 0.40 x 15.40** — while `DynamicEntitySpec` carries a position and an
orientation and no scale. Spawn the raw mesh entity and you get a unit cube. (The classic symptom:
"a random wall appeared".)

An `.ent` has no such limit: `entMeshComponent` has both a `localTransform` **and** a `visualScale`.
So read the exact node transforms out of the sector, rebase them around a chosen origin, and emit
one entity carrying the whole room. Then it spawns anywhere, any time, no quest sector involved.

### 3.2 Sourcing the geometry

Either dump CDPR's studio sector (`quest_ec82d0423d8f1435.streamingsector`) and copy its slabs, or
author your own box out of the same two meshes. If you copy:

```python
ORIGIN = (5894.69, 6133.51, -1.03)     # the FLOOR SLAB'S CENTRE — local space starts here
ROOM   = dict(xmin=5884, xmax=5904, ymin=6124, ymax=6144, zmin=-2.5, zmax=6.0)
ROOM_MESHES = {"box.w2mesh", "q110_black_box.mesh"}     # the shell only
```

**Filter by mesh name, not just by bounds.** A box drawn round the studio also catches a
Japanese-themed set sitting beside it in the same sector — lanterns, a cloth, a side table — which
duly appear inside your studio as "Chinese ornaments with paper lamps". The room is exactly two
meshes; everything else inside those bounds belongs to somebody else's scene.

Geometry worth writing down, since it invalidates two days of guesses: the slab at z 4.75 that the
world inspector reports first is the **CEILING**, the floor is at z **−1.03**, the interior runs
−1.03 to 4.75 for about 5.4 m of headroom, and so a body belongs at roughly z −0.8 in room-local
terms — not 0, and certainly not 4.75.

Make local coordinates relative to the **floor centre**, so that spawning the entity at a point puts
the floor there.

### 3.3 The donor

Any entity that ships a real `entMeshComponent` **and** a real `gameLightComponent` side by side.
`base\gameplay\devices\lighting\residential\corridor_light\corridor_light_a.ent` works.

### 3.4 Per slab: one mesh component, one collider

```python
c = deepcopy(mesh_donor)
c["name"]           = cname(f"studio_mesh_{i:02d}")
c["mesh"]           = res(m["mesh"])
c["localTransform"] = world_transform(*m["pos"], m["quat"])   # WorldPosition is FIXED POINT:
c["visualScale"]    = vec3(*m["scale"])                       #   Bits = metres * 2**17
c["meshAppearance"] = deepcopy(m["node"].get("meshAppearance") or cname("default"))
c["isEnabled"]      = 1
```

**Take the NODE's appearance, not the donor's.** Inherit the lamp's appearance name and you put an
appearance on a box mesh that does not have it; the engine then substitutes something arbitrary and
the floor comes out as a strange, watery material. The sector says `default` for every one of these.

A mesh component is visual only. Vanilla's room gets its solidity from 8 separate
`worldCollisionNode`s, which are not meshes and so are never in this bake. Without colliders the
room is scenery you fall straight through — and so does the subject standing in it.

**Read the rest of this section as the bake-side recipe, not as a solved room.** The colliders below
are emitted and they verify offline, and the pivot correction is real and was measured. But the last
word in our own notes is that the shipped room is still not solid — "NO collision — teleporting in
warns *you WILL fall*". Whether that is a fault in this recipe, in the collider donor, or in
something else about a dynamically spawned `entColliderComponent` was never run to ground. Treat a
solid room as untested.

**A collider needs the mesh's PIVOT, not just its size.** Both shell meshes are unit cubes, but only
one is centred on its origin:

| mesh | bounding box min | max | pivot |
|---|---|---|---|
| `box.w2mesh` | −0.5, −0.5, −0.5 | 0.5, 0.5, 0.5 | centred |
| `q110_black_box.mesh` | −1.0, −1.0, 0.0 | 0.0, 0.0, 1.0 | **in a corner** |

Size the box and nothing else and the outer shell comes out solid while every inner wall is
walk-through, because its box sits half a slab away from the geometry. So:

```python
size = [(hi[j] - lo[j]) * scale[j] for j in range(3)]
mid  = [(hi[j] + lo[j]) / 2.0 * scale[j] for j in range(3)]
box["halfExtents"] = vec3(size[0]/2, size[1]/2, size[2]/2)
box["localToBody"] = transform(position=vec4(*mid), orientation=identity)   # shift onto the geometry
box_wrapper["HandleId"] = str(9000 + i)                                     # unique per FILE (§1.5)
```

### 3.5 Lights in the room entity, or not

You can bake the studio's own `worldStaticLightNode`s in as `gameLightComponent`s. Copy only the
fields the sector actually specifies (`type`, `radius`, `intensity`, `innerAngle`, `outerAngle`,
`color`, `temperature`, `areaShape`, `areaRectSideA/B`, `EV`, `unit`) and set `isEnabled = 1`,
`turnOnByDefault = 1`; everything else keeps the donor's cooked value rather than a guess.

What that costs you is iteration. A baked light needs a re-bake *and a full game restart* to retune,
and tuning a key light takes many iterations, none of them worth a restart. Either keep the room as
geometry and put the lights in a separate sector (§4), which is what you want while you are still
tuning, or fold them into the room once the rig is settled — the room spawn is then the whole
studio, with fewer moving parts at runtime.

What does **not** work either way: spawning light *entities* from Lua and expecting them to light a
subject the player is not standing next to. → [01 §6](01-engine-primitives.md)

---

## 4. Bake 3 — lights that survive range

### 4.1 The one field

Vanilla's studio lights are `worldStaticLightNode`, sector-owned — and the reason they never show in
a feed either is `autoHideDistance: 5`. CDPR's rig hides itself past five metres.

Clone their nodes field for field, re-base them onto your subject spot, and **raise
`autoHideDistance`** — 1000 is effectively never. That one field is the whole of it. Intensity is not
(15000 lm measured dark), and neither is `SetForcedVisible`.

### 4.2 The sector, the block, and the `.archive.xl`

```python
sector["Data"]["RootChunk"].update(
    category="AlwaysLoaded", level=0, nodes=nodes, nodeRefs=[])
sector["Data"]["RootChunk"]["nodeData"]["Data"] = instances

descriptor.update(category="AlwaysLoaded", level=0, numNodeRanges=1,
                  data=res(r"mymod\holo\lights.streamingsector"),
                  streamingBox=box(min=-FLT_MAX, max=+FLT_MAX))
```

```yaml
# mymod_lights.archive.xl
streaming:
  blocks:
    - mymod\holo\lights.streamingblock
```

Use an existing mod's sector/block as the structural template. Hand-assembling one is a long way to
find out which unknown field mattered.

### 4.3 The node instance shape

Per light, one entry in `nodeData.Data`:

| field | value |
|---|---|
| `NodeIndex` | index into `nodes` |
| `Position`, `Orientation` | world position, quaternion |
| `Scale` | 1,1,1 |
| `Bounds` | `Min = Max = Position` (a point) |
| `MaxStreamingDistance` | `FLT_MAX` (3.40282347e38) |
| `UkFloat1` | tracks `autoHideDistance` — raise it **with** the field, do not copy it blind |
| `Uk10` / `Uk11` | `288` / `512` for light nodes (an AI spot's `65280` is a different shape) |

### 4.4 Aiming, and the yaw convention

**A light's forward is its local +Y axis rotated by its quaternion.** Verified rather than assumed:
+Y is the only axis that lands on the subject for all three vanilla studio lights, within 4 cm, and
the runners-up miss by 6–66 cm.

Yaw follows the engine convention **forward = (−sin yaw, cos yaw)**, so pointing at a delta is
`atan2(-dx, dy)` and not `atan2(dx, dy)`. Invisible at yaw 0; turns everything the wrong way at any
other angle. (A spotlight *entity* from a third-party lighting mod may use a different convention —
CharLi's is `(sin yaw, cos yaw)`. Do not carry one across to the other.)

Compose the orientation as `qz(yaw) * qx(pitch)`; roll is meaningless for a cone:

```python
def euler_to_quat(yaw_deg, pitch_deg):
    y, p = radians(yaw_deg) * 0.5, radians(pitch_deg) * 0.5
    cz, sz, cx, sx = cos(y), sin(y), cos(p), sin(p)
    return (cz*sx, sz*sx, sz*cx, cz*cx)
```

**Verify the aim; do not trust it.** A wrong quaternion does not throw. It ships a light pointed at
a wall, and the only symptom is a dark body on a feed nobody is looking at while it bakes. Compute
where each light's cone crosses the subject's vertical axis and assert **the miss distance** rather
than the height — the height of a ray aimed at nothing is meaningless:

```python
def aim_point(pos, quat, feet):
    f = rotated_y(quat)
    dx, dy = feet[0]-pos[0], feet[1]-pos[1]
    flat = f[0]**2 + f[1]**2
    if flat < 1e-9:  return None, inf            # straight up/down
    t = (dx*f[0] + dy*f[1]) / flat
    if t <= 0:       return None, inf            # pointing away
    return pos[2] + t*f[2] - feet[2], hypot(dx - t*f[0], dy - t*f[1])   # (height, MISS)
```

Assert `miss < 0.10` for every light in the sector.

### 4.5 What rig to build

CDPR's three studio lights are a **bust rig**. Measured off their own quaternions, they aim at
1.43 / 1.79 / 1.63 m above the subject's feet, because a vanilla holocall is never framed wider than
a bust. Below the chest their studio is black.

| light | what it is |
|---|---|
| `light_060` | warm spot, 50 lm, front-above — the key |
| `light_062` | wide soft, 5 lm, top-down onto the face |
| `light_189` | blue accent, 30 lm, side at face height |

A whole-figure shot needs light their rig does not have. Author those in **your** frame (subject at
the origin facing +Y) with four numbers each — bearing off their facing, ground distance, height,
and the height the cone aims at — and solve the intensity instead of guessing at it:

```python
KEY_LUX  = 50.0 / (0.66 ** 2)                      # vanilla's key: 50 lm at 0.66 m
cone     = (sin(radians(outer/2)) / sin(radians(65/2))) ** 2   # solid-angle ratio vs the 65-deg base
intensity = KEY_LUX * dist**2 * cone * punch       # `punch` is the role: 1.0 key, 0.5 fill, 0.9 rim
```

A workable three-light figure rig, on top of the cloned bust rig:

| name | bearing | dist | height | aims at | cone | punch |
|---|---|---|---|---|---|---|
| figure key | +58° | 2.05 | 1.85 | 0.85 | 100° | 1.00 |
| leg fill | −42° | 1.70 | 0.55 | 0.55 | 100° | 0.50 |
| rim (behind, blue) | +163° | 1.45 | 2.15 | 1.15 | 70° | 0.90 |

The fill is at half strength on purpose — a fill that matches the key just flattens the figure
again. The rim is there because a whole person against a black room reads as a silhouette without
one.

### 4.6 Brightness, and which rebase you shipped

- Vanilla's 50/5/30 lumens were authored for a feed with the phone's holo shader over the top, so a
  raw camera reads them dim. One global `INTENSITY_SCALE` at bake time (x4 worked) is easier to
  reason about than editing three numbers.
- If you re-base CDPR's rig onto your own spot, know what angle you are turning it by. Their subject
  does not face −Y: the AI spot's quaternion is yaw −132°, so a faithful rebase is a 132° turn, not
  180°. Using 180 puts their cross-key on the camera's own side, and the feed reads flatter and more
  evenly lit than theirs. Not necessarily wrong — just know which one you shipped.

---

## 5. Optional bakes

| bake | when you want it |
|---|---|
| **a holo appearance** (`meshAppearance = "holo"` per mesh) | self-lit subject, no room, no lights. Needs all three: the `.app` definition, an `.ent` patch for name resolution (the `.app` alone spawns a fallback), and a `holo` mesh-appearance entry in **every** mesh |
| **an anim host** — an invisible device `.ent` carrying workspot resources | posing the subject without a `.scene`; `WorkspotSystem:PlayInDeviceSimple(host, npc, …)` then drives the whole authored performance. `workspotResource` on the component is also writable at runtime |
| **an AI spot / marker sector** | only if you go the community/quest route ([01 §4](01-engine-primitives.md)) |

---

## 6. Where to put the studio

Somewhere out of bounds, and clear of CDPR's own — they are at 5894.69, 6133.51 — so that a real
vanilla holocall can never overlap yours. 20 m is enough.

Once you have picked the spot, two things are pinned to it. The light bake is authored **around** it,
so moving the studio means re-running the light bake. And the subject offset above the room origin
is per room: if your origin is the floor slab's centre and the slab is 0.4 thick, the subject stands
at origin + ~0.2. Carrying another room's number across put a subject 0.9 m in the air.

Two runtime notes belong here too, because they are properties of the *bake*. The room has no
interior area and no occluder, so it does not keep weather out — light it properly and you also
light the rain. And spawning the room is not the same as being able to stand in it: the
colliders of §3.4 are meant to fix that and the shipped room was still reported non-solid, so if
anything has to stand on that floor rather than merely be filmed above it, prove it first.
