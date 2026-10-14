# Snippets

Reference implementations for the three sides of the feature. They are distilled from a shipping
implementation rather than run as-is: the recipes and the numbers in them are measured, the exact
text has never been compiled in this form. Port them, do not paste them.

| file | side | notes |
|---|---|---|
| [`holostudio.lua`](holostudio.lua) | CET | the service: spawn, solve, aim, enable, gaze, guard, tear down. Self-contained — it brings its own timer. Syntax-checked only. Uses `math.atan2`, which is LuaJIT (5.1) and therefore correct in game and absent in a 5.3+ harness |
| [`bake_render_target.py`](bake_render_target.py) | WolvenKit CLI | the dtex/atlas/ent trio at whatever resolution you want, with a verify pass. Edit the four constants at the top |
| [`HoloFeed.reds`](HoloFeed.reds) | redscript | the diagnostic feed card (magenta plate and all), plus the vanilla-phone-widget hide |

## What is not here

- **The room and light bakes.** Too specific to your geometry to be worth copying.
  [02 §3](../02-bake-the-assets.md) and [02 §4](../02-bake-the-assets.md) give the field lists, the
  pivot maths and the verify assertions, which is the part that is hard to rediscover.
- **A facial/eye driver.** That needs a RED4ext native; [03 §6.2](../03-the-runtime.md) describes the
  geometry it has to be given and the head-basis calibration it cannot skip.
- **The highest-LOD hold.** Native too: `holostudio.lua` spawns and animates the subject, but a cloth
  wearer or a `compiledEntityLODFlags = 0` character still comes out broken at range until a RED4ext
  plugin holds the body at `ScheduleEntitySetLOD(0x20)`. [01 §6](../01-engine-primitives.md) has the
  hashes, the pointer path and the call.
- **A `.dtex` readback.** Also native, and needed for nothing but stored stills
  ([04 §7](../04-showing-the-feed.md)).

## Before you run anything

1. Edit `WKIT`, `GAME` and `MOD` at the top of the Python file.
2. Change `mymod` to your own prefix everywhere — depot folder, tags, widget names, redscript
   globals. The widget-hide walk in `HoloFeed.reds` guards on that prefix so it never hides your own
   card; leave it as `mymod` while naming your widgets something else and you have re-opened exactly
   that door.
3. `.archive` mounts and redscript recompiles both need a **full game restart**.
