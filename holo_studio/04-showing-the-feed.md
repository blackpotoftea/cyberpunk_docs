# 4. Showing the feed

The display end is the least exotic part of the whole feature: an `inkImage`, two calls, done. It is
also the **first** thing to build, because until you can see the render target you are debugging a
render pipeline by inference.

Reference implementation: [`snippets/HoloFeed.reds`](snippets/HoloFeed.reds).

---

## 1. The two calls

```swift
let feed = new inkImage();
feed.SetAtlasResource(r"mymod\\holo\\atlas.inkatlas");
let partOk: Bool = feed.SetTexturePart(n"whole");     // -> Bool. LOG IT.
feed.Reparent(card);
```

`SetTexturePart` returns the atlas-load answer. A `false` there means the part name or the atlas path
is wrong, and no amount of staring at the card would say so. Return it to Lua as part of a diagnostic
string rather than dropping it.

Lua cannot create widgets, so this lives in redscript with global wrappers:

```swift
public static func MyMod_FeedOpen(sizePx: Float, atlas: String) -> String {
    let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
              .Get(n"MyModFeedSystem") as MyModFeedSystem;
    if IsDefined(sys) { return sys.Open(sizePx, atlas); };
    return "MyModFeedSystem not found";
}
```

**Redscript recompiles on a FULL game restart only**, not on "reload all mods". Make the Lua side
degrade to a log line when these functions are absent, so that a redscript compile error does not
take your whole mod down with it.

---

## 2. Build the diagnostic version first

"I saw nothing" has three very different causes and a bare panel cannot tell them apart. So the probe
card is framed, titled, and sits over a magenta plate:

| what you see | what it means |
|---|---|
| **nothing at all** | the card never built. Read the diagnostic string |
| **magenta** | the card built and the feed image drew **nothing** — bad atlas path, bad part name, no texture bound |
| **black** | the image IS drawing and the frame is empty. A real result: the camera is off, aimed at nothing, or the scene is unlit |
| **grey** | the camera is out of bounds — fog/skybox. The room did not spawn |
| **a picture** | done |

The grey/black distinction is worth internalising. Grey means no room around the camera; black means
inside the box, unlit. Two failures that look identical in a screenshot, told apart at a glance.

Keep the vanilla atlas reachable as a second option in the same widget. When the picture changes,
being able to flip straight back to the known-good path is what makes the change attributable to your
bake and not to anything else.

---

## 3. Sizing and aspect

- The **display** size is not the render size. Asking for a 512 px card off a 256² target shows an
  upscale, not more detail — which is what you want early on, because judging "did raising the
  resolution do anything" in a 256 px box is not possible.
- The atlas part `whole` is a full 0..1 UV rect, so the image stretches to whatever box you give it.
  Square target in a 16:9 card = a stretched face. Either keep the card square or bake a non-square
  `.dtex` ([02 §2.2](02-bake-the-assets.md)).
- If your feed lands in a **square, cropping** container — a message bubble, say — the visible width
  is the *shot's* `frameH`, and none of a wider capture survives. Frame for the container, not for
  the target.

---

## 4. Production card vs. probe

Keep them separate. The probe is a magenta-backed instrument that never changes; the production card
is UI. Ours shares nothing with the probe but the atlas.

What the production card taught:

- **A dumb `inkImage` tree survives context changes.** Vanilla's own call widgets hide themselves
  when a modal popup context is pushed (a typing box does this), so a card built out of vanilla's
  call widgets goes blank the moment the player types. A card with no context listeners does not.
- **Take vanilla's visual language, not vanilla's widgets.** Read the colours and parts out of
  `incoming_call.inkwidget` — the accent red `HDR(1.176, 0.381, 0.348)`, the dark cell plate
  `(0.055, 0.055, 0.09)`, the caller name at the top, the corner glyph from
  `hud_widget_holder.inkatlas` — and rebuild them in your own tree.
- Position and size are parameters. Placement tuned from Lua is a number change; placement baked into
  redscript is another full restart.

---

## 5. Hiding vanilla's phone HUD

Only needed if you ride vanilla's holocall ([01 §4.4](01-engine-primitives.md)) or run your call over
the real phone. What works is a shallow walk of the HUD tree matching on name substring, storing weak
refs so you can restore them:

```swift
if !StrContains(lower, "mymod") && (StrContains(lower, "phone") || StrContains(lower, "call")) {
    w.SetVisible(false);              // shallowest match wins: hide the container, do not descend
    ArrayPush(this.m_hidden, w);
}
```

Guard on your own prefix so you never hide your own card. Depth 2 is enough. Return a diagnostic
naming both what was hidden and every top-level name seen, so that a wrong guess is correctable from
the log instead of by another restart. Measured hit list on a 2.x HUD: `TopLeftPhone`,
`incomming_call_*` (CDPR's spelling), `holoaudio_call_*`, `phone_notifications_*`, `phone_icon_*`,
`songbird_phone`.

Restore on close, and drop the list at a session boundary — the widgets die with the world.

---

## 6. One feed at a time

One `.dtex` = one camera drawing into it. Toggle a second camera onto the same target and the first
picture is gone. What follows from that:

- a photo capture must **not** reuse the call feed's camera or target — bake a second trio
  ([02 §2.3](02-bake-the-assets.md));
- centralise the enable. If exactly one function in your codebase calls `Toggle(true)` on any lens,
  then any "a camera is drawing again" invariant has exactly one place to be maintained;
- if you keep a "capture is quiesced / safe to read" latch anywhere, clear it at that same point.

---

## 7. What a stored still would take

The feed is **live**: an `inkImage` bound to the atlas keeps updating. Freezing one frame into a PNG
that survives a save needs a `.dtex` readback in a RED4ext DLL — copy the D3D12 resource to a staging
buffer, encode, write. That is the only piece of this whole feature that is not script plus assets.
Identify the texture by size, and make that size something nothing else in the engine would pick: at
1024², 43 unrelated textures matched in seven seconds.

Two alternatives that need no native code:

- **Photo mode's own screenshots.** `GetPathHash(path: String) -> Uint32` is a native script call,
  and `GameScreenshotInfo` already carries `path`, `creationDate` and `pathHash`.
  `RequestGameScreenshotByHash` then paints that PNG into any `inkImage` during normal gameplay —
  apartment picture frames do exactly this and persist only the `Uint32`, which is the co-save model
  you want. Resolve the Pictures folder rather than hardcoding it (OneDrive redirects it); a 4K shot
  is 10–13 MB.
  One trap: a frame grab taken at `Present` captures the UI *and* any fade overlay, so "hide the shot
  under a sleep fade" fights the grab and you get black. Either grab before UI compositing, or do not
  hide it — let the camera swing to frame the subject for a beat and swing back, which reads as the
  player taking a photo.
- **A prebaked library** — shoot it at dev time, ship real pixels, fixed set. Arbitrary locations,
  zero runtime cost, no novelty.
