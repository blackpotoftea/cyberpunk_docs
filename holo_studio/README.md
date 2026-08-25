# Building a holo studio in Cyberpunk 2077

A **holo studio** is a room off-screen with a lit, animated NPC standing in it and a camera of your
own pointed at them. That camera renders into a texture instead of into the player's view, and your
UI shows the texture — while the player keeps playing. It is what a video holocall with an arbitrary
NPC is actually made of, and the same rig does in-UI portraits, NPC photos, security feeds, anything
that has to be a live picture of a person.

What follows is the engine primitives, the assets you have to bake yourself, and the code that
drives them. Nothing in it depends on another mod or a framework. Numbers and flags marked
**MEASURED** were established in game; the rest is marked design or untested.

Four parts, and each can be built and proven on its own:

```
  BAKE                         SPAWN                       DRIVE                    SHOW
  ────────────────────────────────────────────────────────────────────────────────────────────
  mymod_rt.dtex          ──►   camera.ent      ──► Toggle(true) ──┐
  (the render target)          (your copy of                      │
                                holocall_camera)                  ▼
  mymod_atlas.inkatlas   ─────────────────────────────────►  mymod_rt.dtex ──► inkImage
  (points at the dtex)                                      (live pixels)      SetAtlasResource
                                                                  ▲            SetTexturePart("whole")
  room.ent               ──►   the room        ─────────────┐     │
  (geometry + collision)                                    │     │
                                                            ▼     │
  lights.streamingsector ──►   always-loaded lights ──► a LIT ────┘
  (autoHideDistance ≫ 5)                                SUBJECT
                                                            ▲
                               NPC spawn ── alwaysSpawned ──┤ exists + draws at range
                                         ── SetForcedVisible┘ animates at range
```

## What it buys, and what it does not

| | |
|---|---|
| ✅ a second camera rendering **while gameplay continues** — no view takeover, no `.scene` | |
| ✅ **any** spawnable NPC record, on incoming and outgoing calls alike, writing nothing the game's own quest logic reads | |
| ✅ a lit body that renders and animates with the player kilometres away | |
| ❌ a picture of somewhere the player is not. The camera renders what is streamed around the player, so a studio in NE2 with the player in Watson renders an empty room — unless *you* own everything in shot | |
| ❌ a **still** that survives a save. The feed is live; freezing one frame to a PNG wants a `.dtex` readback in a RED4ext DLL, the only piece of this that is not script plus assets | |
| ❌ more than one live feed per render target. One `.dtex` = one camera drawing at a time | |

## Prerequisites

| tool | why |
|---|---|
| **Cyberpunk 2077 2.x** | measured against the Phantom Liberty–era builds; every resource named here is base game |
| **CET (Cyber Engine Tweaks)** | the Lua runtime the studio runs in |
| **Codeware** | `DynamicEntitySystem` / `DynamicEntitySpec`, which is how everything here gets into the world |
| **redscript** | the widget that shows the feed. Lua cannot create an `inkImage` |
| **ArchiveXL** | only if you ship a streaming sector for the lights (`.archive.xl`) |
| **WolvenKit CLI** | `extract` / `convert serialize` / `convert deserialize` / `pack` — the whole bake pipeline |

## Build order

Each step produces something you can *see* fail. Do not skip ahead: a broken step 3 and a broken
step 6 look identical from the couch: a black rectangle.

1. **Display first.** Put an `inkImage` on the HUD bound to *vanilla's* atlas
   (`base\gameplay\gui\widgets\phone\holocall_camera_texture_atlas.inkatlas`, part `whole`), over a
   magenta plate. Build nothing else yet — what you want out of this step is an instrument to
   debug the other nine with. → [04](04-showing-the-feed.md)
2. **Vanilla camera.** Spawn `base\cinematics\cameras\holocall_camera.ent` next to the player,
   pointed at anything, `Toggle(true)`. A picture in the card proves the whole render chain with
   zero assets of your own. → [01](01-engine-primitives.md) §1
3. **Your own render target.** Bake the dtex/atlas/ent trio at 1024². Flip the widget to your
   atlas. Sharper picture = your archive mounted. → [02](02-bake-the-assets.md) §2
4. **The subject.** Spawn an NPC in front of the lens *next to the player*. Confirm it renders.
   → [03](03-the-runtime.md) §4
5. **Range.** Walk away. Add `alwaysSpawned` (it stays) and `SetForcedVisible` (it moves).
   → [03](03-the-runtime.md) §4.2
6. **The room.** Bake it, spawn it, stand the subject in it. It will be **black** — that is correct,
   and it is the proof the room arrived. → [02](02-bake-the-assets.md) §3
7. **The lights.** Always-loaded sector with `autoHideDistance` raised. Now it is lit at range.
   → [02](02-bake-the-assets.md) §4
8. **Framing.** Solve the lens position from the shot instead of authoring it. → [03](03-the-runtime.md) §3
9. **Life.** Pose, look-at, blink. → [03](03-the-runtime.md) §6
10. **Teardown.** In order, from every exit, plus the session boundary. Do this before you ship
    anything, not after. → [03](03-the-runtime.md) §8

## The documents

| file | what is in it |
|---|---|
| [01-engine-primitives.md](01-engine-primitives.md) | the RTT camera, the `.dtex`, the atlas; what vanilla's holocall does and why script cannot drive it; the streaming and render-at-range rules |
| [02-bake-the-assets.md](02-bake-the-assets.md) | the three archives you have to build, field by field, plus the CR2W rules that make a bake correct rather than plausible |
| [03-the-runtime.md](03-the-runtime.md) | the CET service: spawn, solve, aim, enable, drive, guard, tear down |
| [04-showing-the-feed.md](04-showing-the-feed.md) | the redscript widget, aspect ratio, one-feed-at-a-time, and what a stored photo would take |
| [05-bringing-it-together.md](05-bringing-it-together.md) | sequencing a real call, ownership and lifetime, group shots, perf, and the bring-up checklist |
| [06-pitfalls.md](06-pitfalls.md) | symptom → cause → fix, for every trap that cost a working day |
| [snippets/](snippets/) | a reference `holostudio.lua`, a parameterised render-target bake, and the display widget |

## A note on provenance

The numbers here came out of building a CET/redscript mod that runs video calls with arbitrary
NPCs. They were taken off that stack running in game, from its logs, rather than read out of a
decompile. Anything nobody actually ran is marked untested.
