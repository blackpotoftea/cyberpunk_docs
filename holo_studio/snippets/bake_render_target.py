#!/usr/bin/env python3
r"""Bake your own render target for a render-to-texture camera (see ../02-bake-the-assets.md §2).

The vanilla holocall camera renders into
`base\cinematics\cameras\holocall_camera_render_texture.dtex`, and that resource declares
`width 256, height 256`, so 256x256 is what gets allocated. Measured in game: writing the
component's `resolutionWidth`/`resolutionHeight` to 1024 SUCCEEDS -- reads back 1024, survives a
Toggle off/on cycle -- and the picture stays soft. The property is component-side bookkeeping and
the texture comes from the resource, so a bigger picture means shipping your own resource.

Three files, each a copy of a vanilla one with a single meaningful change:

    <mod>\<dir>\rt.dtex        <- the dtex, width/height raised
    <mod>\<dir>\atlas.inkatlas <- the atlas, dynamicTextureSlot.texture -> our dtex
    <mod>\<dir>\camera.ent     <- the camera, dynamicTextureRes -> our dtex

Nothing vanilla is edited or overridden. Three files are ADDED under your own depot folder and you
spawn yours instead, which keeps the vanilla path working -- and that is what makes an A/B possible
when the picture changes.

CR2W HAS NO "FIELD ABSENT": a node authored with a subset of fields round-trips with the rest
materialised as defaults. So this never CONSTRUCTS a node. It serializes the real vanilla file and
mutates the two or three values that matter, leaving every other field exactly as CDPR cooked it,
and `--verify` re-serializes what was produced and asserts the values -- "the script did not crash"
is not evidence that the bytes say what you meant.

Components are found by walking for `"$type": "gameuiHolocallCameraComponent"` rather than by a
hardcoded JSON path. An .ent stores components in a place that differs by file, and a path that
silently matches nothing would bake a file that looks fine and changes nothing. The .ent carries
TWO camera components, one per appearance; both are patched.

Usage:
    python bake_render_target.py                            # 1024x1024
    python bake_render_target.py --width 1280 --height 720  # 16:9, for a photo rather than a bust
    python bake_render_target.py --name vision --width 1017 --height 573
    python bake_render_target.py --verify
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

# ---- EDIT THESE ------------------------------------------------------------------------------
WKIT = Path(r"C:\Modding\WolvenKit\WolvenKit.CLI.exe")
GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077")
MOD  = "mymod"                       # your depot folder, and the archive name prefix
OUT  = Path(__file__).resolve().parent / "build"
# ----------------------------------------------------------------------------------------------

CONTENT = GAME / "archive" / "pc" / "content"

SRC_DTEX  = r"base\cinematics\cameras\holocall_camera_render_texture.dtex"
SRC_ATLAS = r"base\gameplay\gui\widgets\phone\holocall_camera_texture_atlas.inkatlas"
SRC_ENT   = r"base\cinematics\cameras\holocall_camera.ent"

CAMERA_COMPONENT = "gameuiHolocallCameraComponent"


def run(*args):
    r = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit(f"failed: {' '.join(str(a) for a in args)}")
    return r.stdout


def walk(node):
    """Every dict in the tree, in no particular order."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def find_typed(root, type_name):
    hits = [n for n in walk(root) if n.get("$type") == type_name]
    if not hits:
        raise SystemExit(f"no {type_name} node found -- the file's shape changed, bake aborted")
    return hits


def set_depot(ref, path):
    """Point a resource reference at a depot path, keeping its Flags."""
    ref["DepotPath"] = {"$type": "ResourcePath", "$storage": "string", "$value": path}


def extract_one(depot_path: Path, cache: Path):
    """Pull one vanilla resource out of the archives and serialize it to json."""
    out = cache / depot_path
    if not out.exists():
        run(WKIT, "extract", CONTENT, "-w", f"*{depot_path.name}", "-o", cache)
    if not out.exists():
        raise SystemExit(f"could not extract {depot_path} from {CONTENT}")
    js = out.with_suffix(out.suffix + ".json")
    if not js.exists():
        run(WKIT, "convert", "serialize", out)
    return json.loads(js.read_text(encoding="utf-8"))


def deserialize_into(doc, name: str, depot_dir: Path, scratch: Path):
    """Write json to a scratch dir, convert it to CR2W, and land it at its depot path.

    The json is written OUTSIDE the depot tree on purpose: `pack` ships everything inside the
    folder it is given, and a stray .json is dead weight in the archive.
    """
    scratch.mkdir(parents=True, exist_ok=True)
    depot_dir.mkdir(parents=True, exist_ok=True)
    js = scratch / (name + ".json")
    js.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    run(WKIT, "convert", "deserialize", js, "-o", depot_dir)
    made = depot_dir / name
    if not made.exists():
        raise SystemExit(f"deserialize produced no {name} in {depot_dir}")
    return made


def paths(args):
    d = args.name
    return {
        "dtex":    fr"{MOD}\{d}\rt.dtex",
        "atlas":   fr"{MOD}\{d}\atlas.inkatlas",
        "ent":     fr"{MOD}\{d}\camera.ent",
        "folder":  (MOD, d),
        "archive": f"{MOD}_{d}",
    }


def bake(args):
    P = paths(args)
    build = OUT
    cache, scratch = build / "vanilla", build / "json"
    depot = build / P["archive"]
    if depot.exists():
        shutil.rmtree(depot)
    out_dir = depot.joinpath(*P["folder"])
    w, h = args.width, args.height

    # ---- 1. the render target ----------------------------------------------------------------
    dtex = extract_one(Path(SRC_DTEX), cache)
    root = dtex["Data"]["RootChunk"]
    was = (root.get("width"), root.get("height"))
    root["width"], root["height"] = w, h
    if args.scale_to_viewport:
        root["scaleToViewport"] = 1
    print(f"dtex   {was[0]}x{was[1]} -> {w}x{h}")
    deserialize_into(dtex, Path(P["dtex"]).name, out_dir, scratch)

    # ---- 2. the atlas the widget binds -------------------------------------------------------
    atlas = extract_one(Path(SRC_ATLAS), cache)
    slot = find_typed(atlas["Data"]["RootChunk"], "inkDynamicTextureSlot")[0]
    set_depot(slot["texture"], P["dtex"])
    parts = [p.get("partName", {}).get("$value") for p in slot.get("parts", [])]
    if "whole" not in parts:
        raise SystemExit(f"atlas part 'whole' vanished (parts={parts}) -- the widget binds it by name")
    print(f"atlas  texture -> {P['dtex']}   parts={parts}")
    deserialize_into(atlas, Path(P["atlas"]).name, out_dir, scratch)

    # ---- 3. the camera entity ----------------------------------------------------------------
    ent = extract_one(Path(SRC_ENT), cache)
    comps = find_typed(ent["Data"]["RootChunk"], CAMERA_COMPONENT)
    for c in comps:
        set_depot(c["dynamicTextureRes"], P["dtex"])
        c["resolutionWidth"], c["resolutionHeight"] = w, h
        if args.fov is not None:
            c["fov"] = args.fov
        # Vanilla ships streamingDistance = 1, which is plenty for a camera that only ever framed
        # a bust standing next to its own scene. Yours has to keep rendering a subject the player
        # walked away from, so this is the first thing to suspect when the feed dies a few metres
        # out -- even though the real mechanism is streaming, not distance.
        if args.streaming_distance:
            c["streamingDistance"] = args.streaming_distance
    print(f"ent    {len(comps)}x {CAMERA_COMPONENT}: dynamicTextureRes -> {P['dtex']}, {w}x{h}")
    deserialize_into(ent, Path(P["ent"]).name, out_dir, scratch)

    # ---- 4. pack -----------------------------------------------------------------------------
    run(WKIT, "pack", depot, "-o", build)
    archive = build / f"{P['archive']}.archive"
    if not archive.exists():
        raise SystemExit(f"pack produced no {P['archive']}.archive in {build}")
    print(f"\npacked {archive.name} ({archive.stat().st_size} bytes)")
    print("Copy it to <game>\\archive\\pc\\mod\\ -- an .archive only mounts on a FULL restart.")


def verify(args):
    """Re-serialize what we produced and assert it, rather than trusting the write."""
    P = paths(args)
    build = OUT
    out_dir = (build / P["archive"]).joinpath(*P["folder"])
    if not out_dir.exists():
        raise SystemExit("nothing baked yet -- run without --verify first")
    tmp = build / "verify"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)

    def reread(name):
        f = tmp / name
        shutil.copy2(out_dir / name, f)
        run(WKIT, "convert", "serialize", f)
        return json.loads((tmp / (name + ".json")).read_text(encoding="utf-8"))

    ok = True

    d = reread(Path(P["dtex"]).name)["Data"]["RootChunk"]
    got = (d.get("width"), d.get("height"))
    hit = got == (args.width, args.height)
    ok &= hit
    print(f"[{'ok' if hit else 'FAIL'}] dtex is {got[0]}x{got[1]} "
          f"(wanted {args.width}x{args.height})")

    a = reread(Path(P["atlas"]).name)["Data"]["RootChunk"]
    slot = find_typed(a, "inkDynamicTextureSlot")[0]
    got = slot["texture"]["DepotPath"].get("$value")
    hit = got == P["dtex"]
    ok &= hit
    print(f"[{'ok' if hit else 'FAIL'}] atlas -> {got}")

    e = reread(Path(P["ent"]).name)["Data"]["RootChunk"]
    comps = find_typed(e, CAMERA_COMPONENT)
    for c in comps:
        got = c["dynamicTextureRes"]["DepotPath"].get("$value")
        hit = (got == P["dtex"]
               and (c.get("resolutionWidth"), c.get("resolutionHeight")) == (args.width, args.height))
        ok &= hit
        print(f"[{'ok' if hit else 'FAIL'}] ent  dynamicTextureRes -> {got}  "
              f"resolution {c.get('resolutionWidth')}x{c.get('resolutionHeight')}")
    # BOTH appearances, not one: a single patched component ships a camera that is yours in one
    # appearance and vanilla's in the other.
    ok &= len(comps) >= 2
    print(f"[{'ok' if len(comps) >= 2 else 'FAIL'}] {len(comps)} camera components patched")

    if not ok:
        raise SystemExit("verify FAILED -- do not deploy this archive")
    print("\nverify ok")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--name", default="holo",
                   help="which target set: 'holo' = the live feed a widget shows; a second set "
                        "(e.g. 'vision') is the capture target nothing is bound to. One .dtex is "
                        "one feed at a time, so a capture must never toggle the feed's camera.")
    p.add_argument("--size", type=int, default=1024, help="square render target (default 1024)")
    p.add_argument("--width", type=int, help="explicit width (overrides --size)")
    p.add_argument("--height", type=int, help="explicit height (overrides --size)")
    p.add_argument("--fov", type=float, help="override the camera fov (vanilla is 35)")
    p.add_argument("--streaming-distance", type=float, default=200.0,
                   help="camera streamingDistance in metres (vanilla ships 1; 0 = leave vanilla's)")
    p.add_argument("--scale-to-viewport", action="store_true",
                   help="track the viewport instead of a fixed size (UNTESTED)")
    p.add_argument("--verify", action="store_true", help="re-serialize the bake and assert it")
    a = p.parse_args()
    a.width = a.width or a.size
    a.height = a.height or a.size

    if not WKIT.exists():
        raise SystemExit(f"WolvenKit CLI not found at {WKIT} -- edit the constants at the top")
    if a.verify:
        verify(a)
    else:
        bake(a)
        verify(a)


if __name__ == "__main__":
    main()
