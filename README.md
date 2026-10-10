# cyberpunk_docs

Working notes on Cyberpunk 2077 modding, written up as guides once the thing they describe
actually ran. They are aimed at someone who has to build the same feature and would rather not
rediscover where the bodies are buried.

The bias throughout is towards what was observed rather than what the decompile implies. A field
name read out of a header tells you it exists; it does not tell you that writing it succeeds,
reads back, and changes nothing on screen. Where these documents give a number, somebody watched
it happen in game with logs on. Where nobody ran it, it says so.

## Guides

| | |
|---|---|
| [holo_studio/](holo_studio/) | Building a holo studio: a render-to-texture camera filming a spawned, lit NPC off-screen into your own UI. The basis of a video holocall with an arbitrary NPC, and of in-UI portraits, NPC photos, or any other live picture of a person. Seven documents plus reference `.lua` / `.py` / `.reds`. |
| [follower_elevator/](follower_elevator/) | A follower who rides the elevator with V instead of being left on the floor it departed from: mount them to the lift entity the way CDPR's own quest scenes do, from CET alone. One guide plus a reference `.lua`. |

## Conventions

**MEASURED** means it was run and observed. *Untested* and *unproven* mean what they say, and they
are used often — a guide that hides its edges is worse than one that names them, because the reader
finds them anyway and at a worse moment.

Guides are framework-independent. They name engine types, resources and API calls, and they do not
depend on any particular mod being installed. Where a snippet needs a depot path or a tag it uses a
`mymod` placeholder for you to replace.

Code under `snippets/` is a reference implementation distilled from something that shipped. It is
syntax-checked, not runtime-tested in the form given — port it, do not paste it.

The tooling assumed across all of this: CET for Lua, redscript for UI, Codeware for
`DynamicEntitySystem`, ArchiveXL where a streaming sector is involved, and the WolvenKit CLI for
anything that has to be baked into an `.archive`.
