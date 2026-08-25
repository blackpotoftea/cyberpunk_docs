// HoloFeed.reds -- put a render-to-texture camera's output on the HUD, so a human can SEE whether
// a camera you enabled yourself is actually drawing. See ../04-showing-the-feed.md.
//
// The display path is not special: a .dtex is exposed as an ordinary inkatlas with one part named
// "whole" (full 0..1 UV), so any inkImage shows it with the same two calls you already make for
// vanilla shape atlases. Nothing to bind engine-side, no new asset to author.
//
// The magenta backdrop is the point of the probe. "I saw nothing" has three very different causes
// -- the card never built, the image drew nothing, the camera rendered an empty frame -- and a
// bare panel cannot tell them apart. So the card is framed and titled (that means it built), a
// magenta plate sits behind the feed image (magenta means the image is transparent, i.e. drawing
// nothing), and anything else on screen is the render itself. BLACK means it IS drawing and the
// frame is empty, which is a real result rather than a failure to observe. GREY means the camera
// is out of bounds -- fog and skybox, i.e. the room did not spawn.
//
// SetTexturePart returns Bool, and that return is the atlas-load answer. It goes back to Lua
// rather than being dropped: a false there means the part name or the atlas path is wrong, and no
// amount of staring at the card would say so.
//
// DEPLOY: redscript recompiles on a FULL game restart only, never on "reload all mods". Make the
// Lua side degrade to a log line when these functions are absent.

public class MyModFeedSystem extends ScriptableSystem {
    private let m_root: ref<inkCanvas>;
    private let m_parent: wref<inkCompoundWidget>;
    private let m_open: Bool;
    // The vanilla phone/call widgets hidden while our card carries the picture. Weak refs,
    // restored on unhide; a session end drops the widgets and this list together.
    private let m_hidden: array<wref<inkWidget>>;

    private func OnAttach() -> Void {
        this.m_open = false;
    }

    // Returns a DIAGNOSTIC STRING rather than a bare Bool, and every early return names which
    // link of the chain was missing. The caller logs it.
    //
    // feedPx is the DISPLAY size, which is not the render size -- ask for 512 off a 256 target and
    // you get an upscale, not more detail. Deliberate: a soft 512 card is the baseline against
    // which "did the bigger .dtex actually do anything" can be SEEN.
    //
    // An empty `atlas` falls back to VANILLA's, the known-good control. Keep both reachable, since
    // flipping straight back to the vanilla path when the picture changes is what makes the change
    // attributable to your bake and not to anything else.
    public func Open(feedPx: Float, atlas: String) -> String {
        if this.m_open { this.Teardown(); };

        let inkSystem = GameInstance.GetInkSystem();
        if !IsDefined(inkSystem) { return "no inkSystem"; };
        let layer = inkSystem.GetLayer(n"inkHUDLayer");
        if !IsDefined(layer) { return "no inkHUDLayer"; };
        let controller = layer.GetGameController() as inkGameController;
        if !IsDefined(controller) { return "no HUD game controller"; };
        let hudRoot = controller.GetRootCompoundWidget();
        if !IsDefined(hudRoot) { return "no HUD root widget"; };

        let diag = this.Build(hudRoot, feedPx, atlas);
        this.m_open = true;
        return diag;
    }

    private func Build(parent: ref<inkCompoundWidget>, feedPx: Float, atlas: String) -> String {
        let font = "base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily";
        // Atlas paths are written INLINE at every call, never bound to a local first: that is the
        // shape known to compile for a ResRef literal.

        let card = new inkCanvas();
        card.SetName(n"myModFeed");
        card.SetAnchor(inkEAnchor.TopLeft);
        card.SetSize(Vector2(feedPx + 44.0, feedPx + 96.0));
        card.SetMargin(inkMargin(80.0, 140.0, 0.0, 0.0));
        card.SetInteractive(false);
        card.Reparent(parent);
        this.m_root = card;
        this.m_parent = parent;

        let bg = new inkImage();
        bg.SetName(n"bg");
        bg.SetAnchor(inkEAnchor.Fill);
        bg.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        bg.SetTexturePart(n"rect_shape_bg");
        bg.SetNineSliceScale(true);
        bg.SetTintColor(new HDRColor(0.02, 0.03, 0.05, 1.0));
        bg.SetOpacity(0.94);
        bg.Reparent(card);

        let fg = new inkImage();
        fg.SetName(n"fg");
        fg.SetAnchor(inkEAnchor.Fill);
        fg.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        fg.SetTexturePart(n"rect_shape_fg");
        fg.SetNineSliceScale(true);
        fg.SetTintColor(new HDRColor(0.98, 0.70, 0.15, 1.0));
        fg.SetOpacity(0.85);
        fg.Reparent(card);

        let title = new inkText();
        title.SetName(n"title");
        title.SetFontFamily(font, n"Medium");
        title.SetFontSize(24);
        title.SetLetterCase(textLetterCase.UpperCase);
        title.SetTintColor(new HDRColor(1.0, 0.78, 0.22, 1.0));
        title.SetText("Holo feed");
        title.SetAnchor(inkEAnchor.TopLeft);
        title.SetMargin(inkMargin(22.0, 16.0, 0.0, 0.0));
        title.Reparent(card);

        // The "you are looking at nothing" plate. If you can read magenta, the feed image drew
        // nothing at all -- a different bug from a black render.
        let plate = new inkImage();
        plate.SetName(n"plate");
        plate.SetAnchor(inkEAnchor.TopLeft);
        plate.SetSize(Vector2(feedPx, feedPx));
        plate.SetMargin(inkMargin(22.0, 56.0, 0.0, 0.0));
        plate.SetAtlasResource(r"base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas");
        plate.SetTexturePart(n"rect_shape_bg");
        plate.SetNineSliceScale(true);
        plate.SetTintColor(new HDRColor(0.85, 0.05, 0.75, 1.0));
        plate.Reparent(card);

        // The feed itself, over the plate. Same two calls as every other atlas.
        let feed = new inkImage();
        feed.SetName(n"feed");
        feed.SetAnchor(inkEAnchor.TopLeft);
        feed.SetSize(Vector2(feedPx, feedPx));
        feed.SetMargin(inkMargin(22.0, 56.0, 0.0, 0.0));
        if NotEquals(atlas, "") {
            feed.SetAtlasResource(ResRef.FromString(atlas));
        } else {
            feed.SetAtlasResource(r"base\\gameplay\\gui\\widgets\\phone\\holocall_camera_texture_atlas.inkatlas");
        };
        let partOk: Bool = feed.SetTexturePart(n"whole");
        feed.Reparent(card);

        let hint = new inkText();
        hint.SetName(n"hint");
        hint.SetFontFamily(font, n"Medium");
        hint.SetFontSize(18);
        hint.SetTintColor(new HDRColor(0.64, 0.70, 0.76, 1.0));
        hint.SetText("magenta = image drew nothing");
        hint.SetAnchor(inkEAnchor.TopLeft);
        hint.SetMargin(inkMargin(22.0, feedPx + 60.0, 0.0, 0.0));
        hint.Reparent(card);

        return s"built  display=\(feedPx)px  atlas=\(atlas)  SetTexturePart(whole)=\(partOk)";
    }

    // Hide (or restore) the vanilla phone/call HUD widgets -- only needed if you ride vanilla's
    // holocall or run over the real phone. Match is by NAME SUBSTRING on the shallow HUD tree
    // ("phone"/"call", never our own prefix); the return string reports what was hidden AND every
    // top-level name seen, so a wrong guess is correctable from the log instead of by a restart.
    // Measured hit list on a 2.x HUD: TopLeftPhone, incomming_call_*, holoaudio_call_*,
    // phone_notifications_*, phone_icon_*, songbird_phone.
    public func PhoneHide(hide: Bool) -> String {
        if !hide {
            let i = 0;
            while i < ArraySize(this.m_hidden) {
                if IsDefined(this.m_hidden[i]) { this.m_hidden[i].SetVisible(true); };
                i += 1;
            };
            ArrayClear(this.m_hidden);
            return "restored";
        };
        let inkSystem = GameInstance.GetInkSystem();
        if !IsDefined(inkSystem) { return "no inkSystem"; };
        let layer = inkSystem.GetLayer(n"inkHUDLayer");
        if !IsDefined(layer) { return "no inkHUDLayer"; };
        let controller = layer.GetGameController() as inkGameController;
        if !IsDefined(controller) { return "no HUD game controller"; };
        let hudRoot = controller.GetRootCompoundWidget();
        if !IsDefined(hudRoot) { return "no HUD root widget"; };
        let seen: String = "";
        let hid: String = "";
        this.HideWalk(hudRoot, 0, seen, hid);
        return s"hid:[\(hid)] seen:[\(seen)]";
    }

    private func HideWalk(parent: ref<inkCompoundWidget>, depth: Int32,
                          out seen: String, out hid: String) -> Void {
        let n = parent.GetNumChildren();
        let i = 0;
        while i < n {
            let w = parent.GetWidgetByIndex(i);
            if IsDefined(w) {
                let name = NameToString(w.GetName());
                let lower = StrLower(name);
                if depth == 0 { seen += name + ","; };
                if !StrContains(lower, "mymod")
                   && (StrContains(lower, "phone") || StrContains(lower, "call")) {
                    // Shallowest match wins: hide the container, do not descend into it.
                    w.SetVisible(false);
                    ArrayPush(this.m_hidden, w);
                    hid += name + ",";
                } else {
                    if depth < 2 {
                        let c = w as inkCompoundWidget;
                        if IsDefined(c) { this.HideWalk(c, depth + 1, seen, hid); };
                    };
                };
            };
            i += 1;
        };
    }

    private func Teardown() -> Void {
        if IsDefined(this.m_root) {
            if IsDefined(this.m_parent) { this.m_parent.RemoveChild(this.m_root); };
            this.m_root = null;
            this.m_parent = null;
        };
        this.m_open = false;
    }

    public func CloseNow() -> Void { this.Teardown(); }
    public func IsOpen() -> Bool  { return this.m_open; }
}

// --- Global wrappers, callable from CET Lua as Game.MyMod_FeedOpen() etc. ---

public static func MyMod_FeedOpen(sizePx: Float, atlas: String) -> String {
    let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
              .Get(n"MyModFeedSystem") as MyModFeedSystem;
    if IsDefined(sys) { return sys.Open(sizePx, atlas); };
    return "MyModFeedSystem not found";
}

public static func MyMod_FeedClose() -> Void {
    let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
              .Get(n"MyModFeedSystem") as MyModFeedSystem;
    if IsDefined(sys) { sys.CloseNow(); };
}

public static func MyMod_FeedIsOpen() -> Bool {
    let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
              .Get(n"MyModFeedSystem") as MyModFeedSystem;
    if IsDefined(sys) { return sys.IsOpen(); };
    return false;
}

public static func MyMod_PhoneHide(hide: Bool) -> String {
    let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
              .Get(n"MyModFeedSystem") as MyModFeedSystem;
    if IsDefined(sys) { return sys.PhoneHide(hide); };
    return "MyModFeedSystem not found";
}
