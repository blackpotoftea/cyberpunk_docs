# 5. Bringing it together

Chapters 2–4 build three independent things. This one is the seams: what waits on what, who owns
which entity, and the order to prove it all in.

---

## 1. The shape of a call

The picture and the conversation are two independent tracks that meet, and the most useful design
decision in the whole feature is to let them meet **in either order**.

```
  t=0     the line opens (dial placed / ring starts / a foreign call is seen)
          │
          ├─► startVideo(contact)          ── the studio starts NOW, not on answer
          │      spawn room ─► spawn lens ─► stream-in poll ─► Toggle(true) ─┐
          │      spawn subject ─► forced-visible ─► pose ────────────────────┤
          │                                                                 ▼
          │                                                     video.ready = true
          │
          └─► the conversation                          (≈2 s on a dial, up to 5.5 s adopted)
                 answered ─► active call ────────────────────────► call.active = true

                             attachVideo(): fires when BOTH are true, whichever lands last
                                 ├─ open the card
                                 ├─ hide vanilla's phone widgets (if riding them)
                                 └─ bind the face to the subject's body, by npcId
```

Start the studio at the earliest moment the call is *seen*, not when it is answered. That wait is
exactly the head start a spawn needs, and starting late puts the picture up mid-sentence. It is never
load-bearing: a slow spawn costs a picture that arrives a moment late, not a call.

**One `startVideo` for every lane.** Outgoing dial, incoming ring, and — if you adopt calls the
game's own phone places — the adopt lane, all through one function. The moment a second lane grows
its own copy, the shot rule, the pose lookup and the "a refusal is a voice call" contract start to
drift apart.

Guard the identity at attach time: compare the studio's subject against the call's contact before you
open the card. Every normal lane sets both from the same id. But a debug button that starts the studio
for whatever name is in its text box will happily hand you a card labelled one character over another
character's body, with the first character's TTS driving the second character's face. One comparison,
and a screenshot cannot diagnose the failure it blocks.

### The capability cascade

Per call, checked in order — no fiction logic, just capability:

1. **Video** — the character can be spawned. Your studio, any lane, any spawnable record.
2. **Portrait** — a still under the same UI. Cheap, and worth building; we never did, so a studio
   refusal drops straight to rung 3.
3. **Nothing** — bare voice call.

The one resource rule that constrains it: **one video at a time**.

### Direction, and an asymmetry that is not yours

In the base game, video holocalls only ever happen when an NPC calls the player. Every staged call
CDPR shipped is a scripted incoming call; when the player dials a contact, vanilla shows a portrait
and plays audio. There is no outgoing-video machinery to ride.

Ride vanilla for incoming and use your own studio for outgoing, and the same character looks
different depending on who dialled. Making both directions yours removes that — and since your studio
covers outgoing at all, it covers incoming too. Keep the ride available per call and as a default,
because for the staged cast it is genuinely better: the real story-outfitted singleton under CDPR's
lighting, which a spawned copy is not. Make yours the default anyway, for four reasons:

| | |
|---|---|
| the mutex | a ride takes `holo_setup_active`, which all 68 vanilla holocall phases respect, and it rides the save. A leaked one deadlocks every holocall in the game |
| story bookkeeping | each ride bumps `holo_<name>_calls_v_start_count`, which quest logic reads |
| coherence | see above |
| coverage | ~60 staged characters versus any spawnable NPC |

---

## 2. Ownership and lifetime

| thing | owner | lives for | dies by |
|---|---|---|---|
| the room `.ent` | you | one shoot | `Stop` (tagged delete) |
| the lens `.ent` | you | one shoot, or one framing | `Stop`, after a frame-count wait ([03 §8.2](03-the-runtime.md)) |
| the subject | you | one shoot | `Stop` — keyed delete, one call per character |
| the anim host | you | reused across shoots | its own tag |
| baked lights | the sector | forever (`AlwaysLoaded`) | never — which is why they must be *lights only*, nothing visible |
| the forced-visible flag | you | the subject's life | explicit `(id, false)` **before** the delete |
| the facial/eye registration | you | the subject's life | explicit clear, keyed on npcId |
| the hidden vanilla widgets | you | the card's life | restore on close; drop the list at session end |

Two rules fall out of that table. **Delete by key, never by "all of ours"** — a tag-wide delete takes
every body wearing the tag, the player's companions included if they share it, so a group shoot is a
*list* of keyed deletes. And a tag has to be vouched for before it is swept: if nothing under a tag
ever streamed in, a `DeleteTagged` on it runs over a ghost. Let the entity that definitely exists —
the room, or the lens when there is no room — be the thing that marks the tag live.

---

## 3. More than one subject

Everything above assumes a lead. A group shot is that path plus a loop, and it should be built
additively rather than by folding the lead into a list: the teardown, the guard and the settle logic
are the parts you least want to rewrite.

- **Solve the slots before anything spawns.** You choose the positions, so the centroid is known
  while the bodies are still requests: no stream wait, no reframe.
- **The anchor is the group's centre, and the camera aims at it.** The lead stands half a spacing off
  it. Frame against the anchor; framing against the lead crops everybody else out.
- **Lay them out across the FACING**, not a world axis: forward at yaw *t* is `(−sin t, cos t)`, so
  their right is `(cos t, sin t)`. A world-axis layout turns a group standing at any other yaw into a
  queue pointing at the lens.
- **Centre-out, lead first.** Sort the offsets by distance from centre and hand them out in call
  order, so the group stays centred and the lead is the last one a tightening frame loses.
- **A refused extra is not a failed shoot** — log it and shoot the rest. But drop the row: a ghost row
  is something your `Settled` waits on forever, burning the full ceiling on somebody who is not
  coming. Both doors need closing, the synchronous refusal and the spawn that is accepted and then
  reports failure five seconds later.
- **Per-body state stays per body.** Face id, gaze state, blink seed, "has the eye aim gone out". A
  shared blink seed puts three people blinking in lockstep in a photograph.
- **~0.65 m spacing.** Three people span ~1.80 m; a 2.05 m frame holds them, a 1.05 m bust does not.
- **Refuse a duplicate name up front.** If your copy registry is keyed per character, two copies of
  one person share a registry slot and a tag: the second overwrites the first's id and the teardown's
  keyed delete takes both bodies. Lower-case the keys before comparing, or the guard has a door in it.

---

## 4. Performance and safety

- **A second shaded render pass is not free**, and we never measured it properly. Do that before
  shipping anything that keeps the camera running during normal play.
- The feed and the forced-visible flag should live exactly as long as someone is looking. One
  unexplained render-thread AV followed ~3.5 minutes of unattended remote rendering.
- **Never toggle a camera off and free it in the same frame** ([03 §8.2](03-the-runtime.md)).
- **Never call an engine system from a dying world** ([03 §8.3](03-the-runtime.md)). This is the one
  that produces reproducible CTDs.
- Sweep your tags at world-up. Crash debris is drawn forever otherwise.

---

## 5. Bring-up checklist

Each line is independently provable. Do not proceed on inference.

| # | do | proof |
|---|---|---|
| 1 | HUD card on **vanilla's** atlas, magenta plate behind | you see magenta |
| 2 | spawn vanilla `holocall_camera.ent` near the player, `Toggle(true)` | the magenta is replaced by a picture |
| 3 | bake your dtex/atlas/ent trio, flip the card to your atlas | the picture is sharper; the component reports your resolution |
| 4 | spawn an NPC in front of the lens, near the player | you see them |
| 5 | walk away | they vanish |
| 6 | add `alwaysSpawned` | they stay, frozen |
| 7 | add `SetForcedVisible(id, true)` | they move |
| 8 | bake and spawn the room | the feed goes **black** (this is success) |
| 9 | bake the light sector, restart | the feed is lit at range |
| 10 | solve the lens from a SHOTS row | the log's rig line matches the picture; FLAT and FACE differ as expected |
| 11 | pose + look-at | they hold a pose and face the lens |
| 12 | teardown from every exit; then save/load; then crash-and-restart | nothing is left standing, and `Settled`/`InUse` read free |

---

## 6. Triage table

When it is wrong, this is the order to ask questions in.

| symptom | first suspect | how to tell |
|---|---|---|
| card blank / nothing on screen | the widget never built | the diagnostic string from the open call |
| **magenta** | atlas path or part name | `SetTexturePart` returned false |
| **grey** | the room did not spawn — the camera is out of bounds | spawn the room alone and look for it in the world inspector |
| **black** | the room is there and unlit | disable the room: if the subject is now visible against the skybox, it is the lights |
| black on an angled shot, fine on FLAT | placement, not the camera | the rig log line: check the sign of the yaw |
| picture is soft | you are showing vanilla's 256² atlas | the component's `resolutionWidth` read-back |
| subject not there at all | id 0 at spawn, or no `alwaysSpawned` | the `CreateEntity -> id=` log line |
| subject frozen | no `SetForcedVisible` | it is one call; add it |
| subject there but dark below the chest | you cloned a bust rig | the light bake's aim heights: three at 1.4–1.8, nothing low |
| lens at the stock wide fov | `fov` written before `Toggle(true)` | read the component back after enabling |
| "she isn't looking at camera" | the Eyes part has no `LookAtPartRequest` | the head is right and the gaze is off by exactly the orbit angle |
| eyes look shut | wrong head-forward axis; pitch saturated | the basis scan's residual per candidate |
| a picture of somebody staring past you | shot taken before the eye aim landed | `Settled()` said no and nobody asked |
| the studio spawned the same person twice | asked `IsUp()` instead of `InUse()` | the gap between claim and stream-in |
| CTD on load or on quit | teardown ran against a dead world | the crash address is inside an engine system stub, no mod frames |
| CTD a few frames after hanging up | camera freed in the same frame it was disabled | same shape — render thread, `DynamicBuffer::ResizeBuffer` |
| every holocall in the game is dead | a leaked `holo_setup_active` from a vanilla ride | read the fact back |

---

## 7. What we would build differently

Honest notes from the far side of it:

- **Build the teardown and the session boundary first.** They are the only parts that crash, and
  every fun part is reachable without them.
- **Do not build a tuning lab with its own copy of the recipe.** Ours spawned a second studio with
  its own tags and its own shot model, so numbers dialled there could not be consumed by the shipping
  path. One service, driven by the panel.
- **Build the portrait rung.** It is cheap, and without it a studio refusal falls all the way to a
  voice call.
- **Head-tracked framing is still open.** Each shot carries a fixed `aimZ` measured off a standing
  body, so a seated or leaning pose frames itself wrong. The fix is to read the head bone per tick and
  express `aimZ` as an offset from it — which, since reframing respawns the lens, is a cadence
  decision and not just a write.
- **Run the A/B you keep postponing.** Ring the same staged character both ways — vanilla's body
  under vanilla's lights against your spawned copy in your room — on one save. If the copy reads
  cheap beside theirs, the staged cast should go back to riding and coherence is the price. We never
  ran it.
