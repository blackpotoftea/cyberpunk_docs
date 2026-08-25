# 1. What the engine already gives you

Nothing in this chapter needs an asset of yours. It is CDPR's own machinery, how much of it script
can reach, and the two rules — streaming and culling — that decide the shape of everything after.

---

## 1. The render-to-texture camera

`base\cinematics\cameras\holocall_camera.ent` carries three components. The one that matters is
**`gameuiHolocallCameraComponent`**, which **extends `entRenderToTextureCameraComponent`** — the same
base class the engine's other render targets sit on, and equally reachable.

| field | vanilla value | meaning |
|---|---|---|
| `dynamicTextureRes` | `base\cinematics\cameras\holocall_camera_render_texture.dtex` | **the render target** — it renders into a texture, not into the player's view |
| `albedoDynamicTextureRes`, `depthDynamicTextureRes` | *(empty)* | spare output slots; `normals…` and `particles…` exist too, unread here |
| `features` | `entRenderToTextureFeatures` | `antiAliasing`/`reflections`/`SSAO` = `RTFP_All`, `renderParticles 1`, `renderDecals 1`, `contactShadows 1`, `localShadows 0` |
| `fov` | `35` | siblings ship `holocall_camera_fov_20.ent` / `_fov_25.ent` |
| `farPlaneOverride` | `1000` | |
| `streamingDistance` | `1` | see §5 — a red herring, but raise it anyway |
| `isEnabled` | `0` | **something has to flip this** |
| `backgroundColor` | `0,0,0,0` | transparent, as a composited holo wants |
| `resolutionWidth` / `resolutionHeight` | `256` | **bookkeeping only** — see §2 |

Also in that folder: `holocall_camera_placide.ent`, a per-character rig. Placide holo-calls V in the
Voodoo Boys line, so these are real staged setups and not debug leftovers. And
`base\entities\cameras\photo_mode_rt_camera.ent`, which is photo mode's *backdrop* feature rather
than a general capture path.

### Reaching it from script — MEASURED

The component is **registered in RTTI** and reachable by name on a spawned entity:

```
component "RenderToTextureCamera" found, class = gameuiHolocallCameraComponent
  Toggle(true) call: true
  IsEnabled(): false -> true
    fov 35   resolution 256x256   renderingMode Shaded (0)   dynamicTextureRes <live handle>
```

Two things fall out of that, and both are load-bearing:

- **Enable through the METHOD.** `entIComponent` exposes `Toggle(Bool)` and `IsEnabled()`. Writing
  `isEnabled` from Lua is silently dead. `Toggle` hands you a read-back, so the silent-write hazard
  never comes up.
- **`entIPlacedComponent` gives `SetLocalPosition` / `SetLocalOrientation` / `SetLocalTransform`**,
  so the lens can be aimed without teleporting its entity. Runtime aiming does work — see
  [03 §3.4](03-the-runtime.md) for why you may still want the aim baked into the spawn.

---

## 2. Where the resolution actually comes from

`resolutionWidth` / `resolutionHeight` are `Uint32` properties and writing them **succeeds** —
256 → 1024, reads back, survives a `Toggle` off/on cycle — and the picture does not change
(MEASURED). The allocation comes from the resource, which declares `width 256, height 256,
scaleToViewport 0`.

Resolution is therefore a bake. Ship your own `.dtex` at the size you want and point your own camera
`.ent` at it. → [02 §2](02-bake-the-assets.md)

---

## 3. The display end is an ordinary inkatlas

`base\gameplay\gui\widgets\phone\holocall_camera_texture_atlas.inkatlas`:

```
activeTexture        : DynamicTexture         isSingleTextureMode : 1
dynamicTextureSlot.texture -> base\cinematics\cameras\holocall_camera_render_texture.dtex
parts[0].partName    : "whole"   (full 0..1 UV rect)
```

Any `inkImage` shows it with the two calls you already make for vanilla shape atlases:

```swift
img.SetAtlasResource(r"base\\gameplay\\gui\\widgets\\phone\\holocall_camera_texture_atlas.inkatlas");
img.SetTexturePart(n"whole");     // -> Bool: the atlas-load answer. Log it.
```

So there is no engine-side binding to arrange and no new asset needed just to display a feed. Your
own widget can show it, and so can a message bubble, and so can a screen in the world. The phone's
`HudPhoneAvatarController.m_HolocallRenderTexture` only ever calls `SetVisible`/`SetSize` on its
image — it never binds content, which is exactly what you would expect if the pixels arrive from an
engine-side target.

The chain, end to end, no native code anywhere in it:

```
holocall_camera.ent -> gameuiHolocallCameraComponent.Toggle(true)
                    -> holocall_camera_render_texture.dtex
                    -> holocall_camera_texture_atlas.inkatlas   (one part, "whole")
                    -> any inkImage: SetAtlasResource + SetTexturePart
```

One shared `.dtex` means **one live feed at a time**. If you want a capture target as well as a call
feed, that is a second trio of resources — not a second camera on the same one.

How routine this is in the engine is worth knowing: the shipped `.dtex` list includes TV studio
channels, streaming cameras, the Delamain screen, portal streams, braindance targets, the photo-mode
backdrop, and several quest live-feeds. Camera-to-surface is normal work here.

---

## 4. What vanilla's holocall actually does (and why you cannot run it)

A camera that renders is half a holocall. The other half is **a place with a lit actor in it**, and
that half is the hard one — not for rendering reasons, for lifetime ones.

### 4.1 The studio

Out of bounds in the NE2 quadrant at **(5894.686, 6133.506)**. Its sector is
`base\worlds\03_night_city\_compiled\default\quest_ec82d0423d8f1435.streamingsector`, and every node
in it hangs off `$/03_night_city/ne2/#holocalls_studio`.

| | |
|---|---|
| shell | 6 x `engine\meshes\editor\box.w2mesh` — **floor at z −1.03, ceiling at 4.75**, walls at 1.86 |
| inner | 7 x `q110_black_box.mesh` |
| lighting | **270** `worldStaticLightNode`, radius 1–5, intensity 20–150 |
| actors | 90 `worldAISpotNode` (`deep_delamain_holocall_workspot`, `angry_…` — one per emotional state) |
| camera rig | `#holocall_camera`, `#holocall_camera_av_coach`, `#holocall_camera_sitting_driving`, plus `#holocall_look_left_entity` / `#holocall_look_straight_entity` as gaze targets |
| also | a fog volume, a light-channel volume, a reflection probe, a population spawner, 8 collision nodes |

Two of those cost time if you have to rediscover them. **The collision slab the world inspector
reports first, at z 4.753, is the CEILING** — the floor is −1.03. And **there is no interior area
and no occluder anywhere in the sector**: the room does not keep rain out, it is simply never lit,
so nothing inside it is ever visible.

The actor is separate, and does not live in the quest sector at all:

```
worldCompiledCommunityAreaNode   $/SpawnSet/#delamain_holo
    sector  base\worlds\03_night_city\_compiled\default\always_loaded_1.streamingsector
worldStaticMarkerNode            #holocall_marker
    sector  always_loaded_2.streamingsector      position 5894.173, 6135.749, 0.035
```

**Persistence is a property of the SECTOR, not of the body.** `always_loaded_*` sectors are never
unloaded, so anything in one is resident wherever the player is. No flag on the puppet is doing it.
`always_loaded_1` also carries an inactive holo community entry for ~60 characters (`#panam_holo`,
`#judy_holo`, `#takemura_holo`, …), each `entryActiveOnStart: 0`, each pointing at a normal
character record with a normal appearance.

### 4.2 How a call builds it

Walked out of `base\quest\holocalls\<name>\<name>_holocall.scene`:

```
questCallContact_NodeType                      (quest, questIPhoneManagerNodeType)
    prefabNodeRef = #holocalls_studio           <- the call node spawns the room
    caller / addressee / phase / mode / visuals / showAvatar / isRejectable

questTogglePrefabVariant_NodeTypeParams
    prefabNodeRef = #holocalls_studio_lighting  <- per-character lighting, as prefab VARIANTS

questSpawnManagerNodeDefinition
    questSpawnSet_NodeType { action: Activate, entryName: panam_holo,
                             phaseName: panam_holo, reference: #panam_holo }

questUseWorkspotNodeDefinition                 <- mounts the pose
```

The studio is a quest prefab. The lighting is a second prefab whose *variant* is switched per
character, which is what "each NPC has their own lighting setup" turns out to mean. The body is a
community entry a quest node activates, and the camera is a node in the same sector. Setting the
phone fact by itself does nothing — the fact drives the scene, and the *scene* carries the prefab
refs.

### 4.3 The dead ends — from script, at runtime

Everything in this list is about the **runtime scripting surface**: what CET Lua and redscript can
reach while the game is running. None of it says these nodes are unusable.

The distinction to hold on to: **you define these nodes in WolvenKit and ship them in a resource.
What you cannot do is create one at runtime from script and run it.** Authoring is a supported
workflow and §4.3.1 walks it; dynamic construction plus execution is the part with no door.

Script sits alongside the quest system rather than inside it — facts in, listeners out. The scene
system is the same shape: `SceneSystem` gives script fast-forward and rewind, no playback and no
actor acquisition. Quest nodes also own sockets, lifetimes and phase-scoped state, which is why one
fired in isolation may not behave; that machinery needs a graph to live in.

1. **You cannot run these nodes from script at runtime.** CET and redscript can *build* one in
   memory — `questTogglePrefabVariant_NodeType` and `questCallContact_NodeType` are both in RTTI,
   so you can construct the exact object the game uses and fill in `#holocalls_studio` — but
   nothing in script executes it. What executes it is a phase graph — which you define in WolvenKit
   and ship. Both classes expose only properties, and every method on them is inherited
   `ISerializable`. (They are also not nodes; see §4.3.1 for what they are.)
2. **`QuestsSystem` is facts-only** — `GetFact`/`SetFact`/`GetFactStr`/`SetFactStr`/listeners. No
   `StartQuest`, no phase evaluation.
3. **The "scripted quest" API is the journal.** `CreateScriptedQuestFromTemplate` lives on
   `JournalManager` beside `SetScriptedQuestObjectiveDescription` — it creates quest-log entries and
   map pins, and runs no graph.
4. **Script cannot flip a community entry.** The live `gameCommunitySystem` exposes crowd null-areas
   and density and nothing else (MEASURED against the instance, not read off the decompile).

#### 4.3.1 The door that is open: author a phase

WolvenKit has a quest phase graph editor, and it knows these node types. As of 8.19 it ships
`QuestPhaseGraphView` with ~70 node wrappers, among them `questPhoneManagerNodeDefinition`,
`questWorldDataManagerNodeDefinition`, `questSpawnManagerNodeDefinition`,
`questUseWorkspotNodeDefinition`, `questPauseConditionNodeDefinition` and
`questFactsDBManagerNodeDefinition` — which is every node vanilla's holocall chain is built from.

Point 1 above is narrower than it looks, and the class hierarchy is why. `questCallContact_NodeType`
derives from `questIPhoneManagerNodeType`, and `questTogglePrefabVariant_NodeType` from
`questIWorldDataManagerNodeType`. Neither is a node. They are **payloads carried by** a node
definition — `questPhoneManagerNodeDefinition.type` is a `CHandle<questIPhoneManagerNodeType>` — so
"the node types are data" is a literal description of what those two classes are, and the thing that
executes them is the phase graph that owns them.

So the shape of the authoring route is: build the graph, ship it as a `.questphase` in your archive,
attach it with ArchiveXL's `quest: phases:` key parented to `cyberpunk2077.quest` (the bare name is
an alias that patches every known root quest at once), and gate it on a fact of your own. Your script
then has exactly one lever — `SetFactStr` — and the quest system does the rest. That is a real,
working route; the implementation this guide is drawn from built it and ran it.

Two things about it that are not obvious, both of which cost a session:

- **Strip `phasePrefabs` from a copied phase.** Copy a vanilla `.questphase` as a starting point and
  leave that field populated, and saves stall at 75% on reload. Nothing looks wrong until somebody
  reloads.
- **Never attach an ungated phase to the root quest.** `cyberpunk2077.quest` is always running, so an
  unconditional phase puts your test scaffolding in every save from the load screen. Gate on your own
  fact, which defaults to 0, and a fresh save contains nothing of yours.

Prove the attachment before you prove the logic: ship an empty phase, in socket straight to out, and
confirm the game still loads a save. A phase that never ran and a phase whose condition never fired
look identical from the outside. Entry sockets must be `In1`/`Out1`, waits must be
`questPauseConditionNodeDefinition`, and a node with an unconnected In does **not** auto-start.

This guide does not take that route, because for a body **you** spawn it is not needed at all (§6).
It is the route to CDPR's own staged body, and to anything else that wants the quest system's
lifetime handling rather than your own.

There is one exception and it is a large one: Codeware 1.20.3 exposes
**`QuestsSystem.ExecuteNode(questNodeDefinition)`**, which runs an arbitrary quest node against the
root phase from script. Together with `WorldStateSystem` (prefab hold, variant toggle, community
activate) that makes the whole staging chain reachable from Lua with no archive at all — with one
caveat nobody has measured. One-shot execution against the root phase suits fire-and-forget action
nodes, but a node that expects to own a lifetime may not survive it, and the prefab *hold* is scoped
to a phase instance. That hold is the part most likely still to need a baked phase, so do not assume
the archive disappears until somebody measures it. (Verified against the installed 1.20.3; earlier
versions untested.) This guide
does not take that route — §6 says why — but it exists, and it is the shortest path to *CDPR's own
staged body*.

### 4.4 Riding vanilla instead

Every staged character has an always-armed quest phase driven by two facts:

```lua
Game.GetQuestsSystem():SetFactStr("holo_<name>_calls_v_start_activate", 1)   -- start
Game.GetQuestsSystem():SetFactStr("holo_<name>_calls_v_end_activate", 1)     -- hang up
```

That runs the **entire** pipeline: studio prefab held, per-character lights, community Activate,
workspot mount, RTT camera on, phone HUD. MEASURED with the player across the city — lit, animated,
visible in a feed of your own.

What it costs, and why this guide does not build on it:

| cost | detail |
|---|---|
| the phone HUD takes over | ring, pickup flow, call screen. It is a real call, not a service |
| a global mutex | `holo_setup_active` (staging) and `holo_setup_started` (duration) are respected by all 68 vanilla call phases. **A leaked `holo_setup_active` rides the save and deadlocks every holocall in the game**, CDPR's included |
| story bookkeeping | each trigger bumps `holo_<name>_calls_v_start_count`, which quest logic reads |
| coverage | ~60 staged characters, and only ever *incoming* — there is no outgoing-video machinery in the game to ride |

Against all that: for the staged cast the ride is genuinely better. It is the real story-outfitted
singleton under CDPR's own lighting, which a spawned copy is not. Keep it reachable behind a flag
and do not make it the default.

Enumerating the cast, if you want it: walk `archive\pc\content` for `*_holocall.scene` (157 exist);
per scene read the start/end facts (`questFactsDBCondition` names matching `holo_<name>_calls_v_*`)
and the mode — `questCallContact_NodeType.mode = Video` with a nonzero `prefabNodeRef` is a staged
body, `Audio` rows stage nothing. Cross-check against the studio sector's 65 `#<char>_holocall_setup`
child prefabs; a video-staged character has to appear in both.

---

## 5. Streaming: the wall that does not move

**The engine renders what is streamed around the player.** A camera pointed at a motel in Santo
Domingo while the player is in Watson renders nothing — no geometry, no NPC. This is not a missing
hook and no knob reaches it.

Measured by walking away from an enabled camera pointed at a doorway NPC:

| what | when it goes |
|---|---|
| **the camera** | never, once `alwaysSpawned = true`. Any distance, across sector boundaries |
| **crowd NPCs** | first, and **by view angle** — keep looking their way and they survive a long walk; cross into a new streaming sector and they all go at once |
| lights | flicker in and out somewhere between (LOD) |
| **geometry** | last, much further out |

The camera is never the problem: `streamingDistance` 1 -> 200 changed nothing, because the mechanism
is not distance. (Raise it anyway. It costs nothing and it removes a suspect.) That it is
direction-dependent is the proof it is not a radius — two metres through a doorway kills a subject
that thirty metres down a corridor does not. And when the content goes the feed does not: after a
sector change the picture is still live, showing a world with nobody in it.

Backdrops are cheap; actors have to be owned. A crowd NPC you merely found belongs to the streaming
system and it will take them back. A body you spawned with your own `DynamicEntitySpec` does not.

---

## 6. Render at range — the two calls that are the whole lever

**MEASURED.** If you read one thing in this guide, read these two lines.

```lua
-- 1. it EXISTS and DRAWS at range, because we registered it ourselves
spec.alwaysSpawned = true          -- DynamicEntitySpec -> PopulationEntityRegisterRequest

-- 2. it MOVES at range: this releases anim-graph culling
Game.GetAnimationSystem():SetForcedVisible(entityID, true)   -- pair with (id, false) at teardown
```

With both, a body spawned at the studio rendered **and animated** in a render-to-texture feed with
the player **8.7 km away**. Without (1) the entity is created, never becomes a body, and the only
symptom is an `onFailed` five seconds later. Without (2) it stands frozen.

None of this holds for a body the game owns. With vanilla's quest chain fully staged and its
community entry Activated, Codeware's community wrapper read
`entry panam_holo: spawned=0 reserved=0 active=true` — the Activate held, and the population system
kept **no body** at range. For a game-owned body, existence at range is scene-only.

A `.scene` is the only route to CDPR's own story-outfitted singleton, and nothing in this guide
takes it. If you do: set `forceMaxVisibility` on the params struct your actor's `acquisitionPlan`
names — each of the eight structs carries its own copy of the field and seven are inert — because
CDPR set it on every staged body in that room but one. No script can set it, so it is a scene-
authoring decision or nothing.

A body you spawn yourself therefore needs no scene, no community entry and no quest hold, which is
why this guide is script plus assets rather than a `.questphase`.

Two more that have the same shape:

- **Dynamic lights are emission-culled at range** no matter what you do. Entity spawned, component
  on, intensity 15000, `SetForcedVisible` called — the feed stays dark until the player walks in
  (MEASURED). Static light nodes owned by a sector do render, and the reason vanilla's studio lights
  never show either comes down to one field: `autoHideDistance: 5`. -> [02 §4](02-bake-the-assets.md)
- **Vanilla light *fixtures* do not emit.** `corridor_light_a` ships `intensity 0` +
  `turnOnByDefault 0`; it spawns perfectly and lights nothing, and "spawned" in a log reads
  identically either way.

---

## 7. The hologram *look* is free

The in-world holograms (`Character.Hologram_NPC_Base`, `q105_hologram_evelyn`, the q001 crime-scene
ghosts) are ordinary appearance definitions in
`base\characters\appearances\special\special__hologram_{ma,wa}.app` whose components are the
character's **normal meshes with `meshAppearance = "holo"`** — a material variant every character
mesh already carries.

Which means those characters are spawnable today and are **self-lit: no lights, no room**. If
ghost-blue is the look you want, [02 §3](02-bake-the-assets.md) and
[02 §4](02-bake-the-assets.md) are both skippable.

Vanilla holocalls do not use this. Their studio body is the character's normal appearance under real
lights, and the holo tint comes from the phone UI shader on top.
