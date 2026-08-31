import SwiftUI
import DecanterKit

/// All explanatory copy in one place. Hover text should say what the control
/// does *and* when you'd reach for it — a tooltip that only restates the label
/// is worse than none.
enum Help {

    // MARK: Graphics backends

    /// What to call a backend when the reader has never heard of Vulkan.
    ///
    /// Each name says what the thing *is*, never how well it works. The names
    /// used to be Apple / Standard / Compatibility, and both of the last two
    /// were quiet promises: "Compatibility" reads as the safe choice a stuck
    /// person should move to, when WineD3D is the slow fallback and a modern
    /// game may well do better on Apple's. Compatibility is not a slider with
    /// one backend at the top — it is per-game, which is the whole reason
    /// Decanter recommends rather than ranks.
    ///
    /// So the recommendation is shown *beside* these names instead of being
    /// baked into them, and the real names are kept as secondary text: someone
    /// following a forum thread needs to recognise "DXVK", and hiding it would
    /// make this app harder to get help with, not easier.
    /// Defined in DecanterKit so the app and the command line say the same
    /// word about the same setting.
    static func plainName(_ b: GraphicsBackend) -> String { b.plainName }

    /// Whether a backend is still proving itself. Kept apart from the name for
    /// the same reason the recommendation is: a name should say what a thing
    /// is, and every caveat that gets folded into a name stops being read.
    static func isExperimental(_ b: GraphicsBackend) -> Bool { b == .dxmt }

    /// The symbol beside each name. SF Symbols rather than emoji: emoji do not
    /// tint with the control and render differently in menus.
    static func symbol(_ b: GraphicsBackend) -> String {
        switch b {
        case .d3dmetal: "apple.logo"
        case .dxvk:     "bolt.fill"
        case .wined3d:  "wrench.and.screwdriver.fill"
        case .dxmt:     "cube.transparent.fill"
        }
    }

    /// One line, describing the thing rather than grading it. Anything longer
    /// belongs behind the info button.
    static func oneLiner(_ b: GraphicsBackend) -> String {
        switch b {
        case .d3dmetal: "Apple's own graphics translation. Only available on Apple's engine."
        case .dxvk:     "Draws the game through Vulkan. Available on either engine."
        case .wined3d:  "Wine's built-in graphics. Needs nothing extra installed."
        case .dxmt:     "Draws through Metal directly. Community-made, and needs a runtime that can host it."
        }
    }

    /// When to reach for one, phrased as a next move rather than a verdict.
    /// Only shown for the options Decanter did *not* pick.
    static func whenToTry(_ b: GraphicsBackend) -> String {
        switch b {
        case .d3dmetal: "Try if the game runs but feels slow."
        case .dxvk:     "Try if the game will not start, or draws nothing."
        case .wined3d:  "Try if neither of the others will run it, or if videos do not play."
        case .dxmt:     "Try for a Unity 6 game, which none of the others can start."
        }
    }

    /// What to call the thing a game runs on.
    ///
    /// Not "Windows version" — that is simply wrong, both provide the same
    /// Windows API level — and not "Engine", which this app already uses for
    /// Unity and Unreal. The control is labelled "Runs on" and the options are
    /// named, so no category noun has to be invented at all.
    static func runtimePlainName(_ kind: RuntimeKind) -> String {
        switch kind {
        case .gptk: "Apple's engine"
        case .wine: "Wine"
        }
    }

    static func runtimeOneLiner(_ kind: RuntimeKind) -> String {
        switch kind {
        case .gptk: "Apple's build. The only one that can use Apple graphics. Built on an older Wine, so a few newer games refuse it."
        case .wine: "The current Wine. Better with recent games and with older 32-bit ones. No Apple graphics — pair it with Vulkan or Wine graphics."
        }
    }

    static let runtimeWhich = """
    Two engines run the Windows side, and they are not versions of Windows — \
    both provide the same Windows APIs.

    **Apple's Game Porting Toolkit** is the only one that offers Apple \
    graphics, which is normally the fastest option and the right default for \
    modern 3D games. It is built on Wine 7.7 from 2022, so a game released \
    since then may not run on it.

    **Wine 11** is current. Reach for it when a game will not start on Apple's \
    build, when the game is 32-bit, or when it is recent. It has no Apple \
    graphics, so pair it with Vulkan or Wine graphics.

    Changing this rebuilds the game's Windows environment, which takes about \
    half a second. Saves are kept.
    """

    /// Swaps backend names for the words the controls use.
    ///
    /// The engine writes "switch to WineD3D" because the CLI should say that.
    /// In the app the control beside it says "Wine", and one warning naming a
    /// setting that appears nowhere on screen is worse than none. Only applied
    /// to text on the primary path — the Why section and Advanced keep the
    /// real names, because the people reading those want them.
    static func plainify(_ text: String) -> String {
        var out = text
        for b in GraphicsBackend.allCases {
            out = out.replacingOccurrences(of: backendTechnicalName(b),
                                           with: plainName(b) + " graphics")
            out = out.replacingOccurrences(of: rawTechnicalName(b),
                                           with: plainName(b) + " graphics")
        }
        return out
    }

    /// Just the product name, with no parenthetical.
    static func rawTechnicalName(_ b: GraphicsBackend) -> String {
        switch b {
        case .d3dmetal: "D3DMetal"
        case .dxvk:     "DXVK"
        case .wined3d:  "WineD3D"
        case .dxmt:     "DXMT"
        }
    }

    /// The name people will meet in forum threads and bug reports.
    static func backendTechnicalName(_ b: GraphicsBackend) -> String {
        switch b {
        case .d3dmetal: "D3DMetal (Direct3D to Metal)"
        case .dxvk:     "DXVK (Direct3D to Vulkan)"
        case .wined3d:  "WineD3D (Direct3D to OpenGL)"
        case .dxmt:     "DXMT (Direct3D 11 to Metal)"
        }
    }

    /// A plain-language state for the top of the game page.
    /// The one sentence at the top of a game's page.
    ///
    /// The blocker is asked before anything else and carries its own wording,
    /// because "Ready to play" was being printed over a game whose files had
    /// been deleted and over games that ship a kernel anti-cheat. A status
    /// line that cannot say "no" is not a status line.
    static func status(running: Bool, onRecommended: Bool, hasProblem: Bool,
                       blocker: AppModel.Blocker? = nil) -> String {
        if running { return "Running" }
        if let b = blocker { return b.status }
        if hasProblem { return "Last run had a problem" }
        if onRecommended { return "Ready to play" }
        return "Ready to play — a better setup is available"
    }

    static func backend(_ b: GraphicsBackend) -> String {
        switch b {
        case .dxvk:
            "Translates Direct3D 9/10/11 into Vulkan, which MoltenVK then runs on Metal. The best default: it is the most mature layer and handles the widest range of games. Start here."
        case .d3dmetal:
            "Apple's own translation — Direct3D 11/12 straight to Metal, no Vulkan in between. Usually the fastest for demanding DirectX 12 titles, but it only exists inside the Game Porting Toolkit runtime, which is built on an older Wine."
        case .wined3d:
            "Wine's built-in Direct3D, running on OpenGL. Slowest for 3D, but it needs no Vulkan and has the fewest moving parts. The right choice for 2D games and the thing to try when the others crash or show a black screen."
        case .dxmt:
            "Direct3D 11 straight to Metal, from the DXMT project rather than from Apple. It implements the interfaces Unity 6 asks for and the other layers here do not. It is young, it covers Direct3D 11 only, and it loads solely on a Wine whose Mac driver hands out a Cocoa view — so Decanter offers it only where that is true."
        }
    }

    static func whenToChoose(_ b: GraphicsBackend) -> String {
        switch b {
        case .dxvk:     "Best for: Unity, Godot, Unreal, and anything that already ran under Whisky, Proton or Steam Deck."
        case .d3dmetal: "Best for: modern DirectX 12 games that DXVK renders badly or refuses to start."
        case .wined3d:  "Best for: Ren'Py, RPG Maker and other 2D games — and as the fallback when a game shows a black screen."
        case .dxmt:     "Best for: Unity 6 games, which need Direct3D 11 interfaces no other layer here provides."
        }
    }

    static let backendPicker = """
    Which piece of software turns the game's drawing instructions into \
    something your Mac's graphics chip understands.

    There is no option here that is best for every game — if there were, \
    Decanter would just use it. Which one wins depends on the game, which is \
    why Decanter marks the one it expects to work and leaves the rest \
    available.

    **Apple** (D3DMetal) is Apple's own translation, and normally the fastest \
    for modern 3D games. It cannot play video, and it only exists on Apple's \
    engine.

    **Vulkan** (DXVK) goes through Vulkan and works on either engine. It is \
    the most common choice, not because it is universally better, but because \
    it is available in the most situations.

    **Wine** (WineD3D) is Wine's own, and needs nothing installed. It is the \
    slowest, and the one to try when the others will not run at all.

    Only the options this game's engine can actually provide are listed.
    """

    static let setupPage = """
    What Decanter needs, what it has, and where to get the rest.

    Decanter never downloads any of it. That is the point: Whisky's installed \
    copies stopped working when the runtime it fetched was deleted upstream. \
    You fetch each piece once and hand it over — drop it anywhere on the \
    window — and Decanter keeps its own copy from then on.
    """

    static let runtimePicker = """
    Which Wine build runs this game.

    Wine 11 is modern and has the newer WoW64, so it is the safer choice for 32-bit and \
    indie games. Apple's engine is based on Wine 7.7 from 2022, but it is the only one \
    that offers Apple graphics.

    Switching keeps the prefix and your saves. Moving to an older runtime can make the \
    prefix complain — run a preflight check afterwards.
    """

    // MARK: Inspector

    static let inspectorPane = """
    Evidence for how this game was set up.

    Decanter reads the executable and the files next to it, then decides which runtime, \
    graphics backend and dependencies to use. This pane shows exactly what it found, so \
    a wrong guess is visible rather than mysterious.
    """

    static let confidence = """
    How sure the detection is, from 0 to 1.

    It is the sum of the evidence weights below. Above about 0.85 the guess is reliable. \
    A low score does not mean the game is broken — only that fewer recognisable markers \
    were found, so you may need to pick the backend yourself.
    """

    static let evidenceWeights = """
    Each line is one thing Decanter found, and how much it counted toward the decision.

    Heavier weights are stronger evidence: a GameAssembly.dll (0.40) identifies the engine \
    outright, while a mod loader (0.15) only colours the picture.
    """

    static let allowedFolders = """
    The only parts of your Mac this game can reach, mapped as Windows drive letters.

    H: is the game's own folder. G: is your shared ~/Games folder, read-only. There is \
    deliberately no Z: drive — Whisky mapped your entire filesystem into every bottle, \
    which let any Windows binary read your Documents, SSH keys and iCloud files.
    """

    static let architecture = """
    Whether the game is a 32-bit or 64-bit Windows program, read from its PE header.

    This matters more than it sounds: 32-bit games need a runtime with WoW64 support. \
    Decanter will not put a 32-bit game on a runtime that cannot run it.
    """

    static let graphicsAPIs = """
    The Direct3D versions this game's binaries reference.

    Treat these as hints, not promises — Unity and Unreal both link Direct3D 12 while \
    actually rendering with Direct3D 11, so Decanter does not switch to D3DMetal on that \
    evidence alone.
    """

    // MARK: Actions

    static let play = "Start the game in its own private copy of Windows."
    static let running = "This game is running. The dot in the sidebar pulses while it lives."

    static let importSaves = """
    Restore save data into this game's prefix.

    Point it at a folder of extracted saves. Files are copied to the matching location \
    inside the prefix, the Windows user name is remapped if the saves came from another \
    machine, and any .reg fragments are merged — which matters because Unity keeps its \
    settings and some progress in the registry, not in files.
    """

    static let rebuildPrefix = """
    Throw this game's Windows environment away and rebuild it from the golden template.

    This is the repair button: Decanter never patches a broken prefix, it re-derives a \
    clean one, which takes about half a second thanks to APFS cloning.

    It also erases anything stored inside the prefix — including saves. Import them again \
    afterwards.
    """

    static let diagnose = """
    Read this game's last launch log and explain why it stopped.

    Recognises missing DLLs, Vulkan being unavailable, blocked folder access, architecture \
    mismatches and crashes — and suggests what to change.
    """

    static let revealPrefix = "Open this game's Windows environment in Finder — its C: drive, registry files and logs."

    static let addGame = "Add a game from a folder or an .exe. Decanter inspects the program, identifies the engine, and gives it a private copy of Windows."

    static let inspectorToggle = "Show or hide the evidence pane, which explains how this game was configured."

    static let librarySection = """
    Your games, most recently played first.

    Right-click any of them for the quick path: play, troubleshoot launch, copy a problem report, or open its Windows environment in Finder.

    You can also drop a game folder or .exe anywhere in this window to add it.
    """

    static let bottlesSection = """
    One isolated Windows environment per game.

    Each is cloned from a shared golden template using APFS copy-on-write, so creating one is instant and costs almost no disk. Isolation being free is the point: no game can break another by installing a conflicting dependency.

    Graphics backend and runtime are set here, because they are properties of the environment rather than of the game.
    """

    // MARK: Saves

    static let savesPane = """
    Every game's saves in one place, so you never have to walk into a bottle and guess a \
    vendor folder name.

    Decanter finds them by comparing the prefix against the clean template it was built \
    from: anything present that the template does not have was written by the game. That \
    works for any engine, and it catches the registry too, where Unity keeps its settings.
    """

    static let snapshotAll = "Take a snapshot of every game's saves right now. Snapshots are APFS clones, so they are near-instant and cost almost no disk."

    static let snapshotNow = "Capture this game's saves as a restorable point in time."

    static let externaliseOne = """
    Move this game's saves out of the prefix and symlink them back in.

    Once protected, rebuilding the prefix no longer erases them — the files live in \
    Decanter's store and the fresh prefix is simply re-attached to them.
    """

    static let externaliseAll = "Move every game's saves somewhere a rebuild cannot reach, so starting a game over can never lose progress."

    static let protectedBadge = "These saves are stored outside the game's Windows environment, so rebuilding cannot lose them."

    static let restoreSnapshot = "Copy this snapshot's files back over the current saves, and merge its registry keys."

    static let savesSearch = "Search file paths across every game's saves at once — useful when you know the filename but not which game wrote it."

    // MARK: Troubleshooting

    static let troubleshootPane = """
    For when the game starts but looks wrong.

    A game that renders badly without crashing writes almost nothing to its log, which is why there is never anything useful to send. Troubleshoot Launch turns on the graphics chatter — Direct3D, DXGI, Vulkan, DXVK and MoltenVK all start reporting — and Copy Problem Report bundles that together with your hardware, the chosen runtime and backend, the detection evidence, and a screenshot of the window.

    The whole bundle goes on your clipboard, ready to paste.
    """

    static let troubleshootLaunch = """
    Launch with verbose graphics logging (WINEDEBUG=+d3d,+dxgi,+vulkan, DXVK log level info, and an on-screen DXVK overlay showing the driver and API in use).

    Run this, reproduce the problem, then use Copy Problem Report while the game is still on screen so the screenshot is included.
    """

    static let copyReport = """
    Collect everything needed to debug this and copy it to the clipboard.

    Includes: macOS and GPU details, runtime and backend actually in use, DXVK version, detection evidence, an automatic diagnosis, every graphics-related log line, and the tail of the log. If the game is on screen and permission allows, a screenshot of the window is saved next to it.
    """

    static let graphicsAreBottleScoped = """
    Yes — the backend and runtime belong to the bottle, not the game.

    That is deliberate: DXVK is not a setting, it is a set of DLLs physically installed inside the Windows environment. Since every game gets its own, changing it here and changing it on the game page are the same act — this is simply the other door into it.
    """

    static let stop = """
    Ends this game and nothing else.

    A hung Windows game often cannot be quit from its own window, and Force \
    Quit will not list it — Wine's processes are not applications, so macOS \
    does not show them there. This shuts down the Wine session for this \
    game's prefix only; anything else you have running is untouched.

    Unsaved progress is lost, the same as force-quitting anything.
    """

    static let mods = """
    BepInEx is a mod loader that hooks the game through a proxy DLL
    (winhttp.dll). Decanter enables that override automatically when it sees a
    BepInEx folder next to the .exe, so mods normally just work.

    The status line is honest about one thing that matters: "has run" means
    BepInEx wrote its own log, not merely that the folder exists.

    Failures shown here come from that log. A broken plugin does not stop
    BepInEx printing a cheerful startup banner, so a game can load the loader
    and still die on launch — and the reason only ever appears in this
    log, never in the game window, which is gone by then.
    """

    static let fixFonts = """
    Some games draw their whole interface in a font that only exists on \
    Windows — MS PGothic and Segoe UI are the common ones. macOS has no such \
    font and Wine invents no substitute, so the game asks for it, gets \
    nothing back, and draws no text at all. The layout still reserves the \
    space, so you get blank buttons and empty lists rather than anything that \
    looks like a font error.

    This maps those names onto the closest face your Mac actually has \
    (Hiragino Sans for Japanese, PingFang and Songti for Chinese, Arial for \
    Segoe UI) for every bottle at once. It only edits the registry, so \
    nothing is launched and it is safe to run again.

    Fonts your Mac genuinely has are never touched.
    """

    static let redetect = """
    Inspect the game again using the current rules.

    The evidence shown here is a snapshot from when the game was added. If \
    Decanter has learned something since — such as how to tell whether a game \
    plays video — re-inspecting picks it up and the recommendation updates.
    """

    static let executablePicker = """
    Choose which program this game launches.

    A game folder usually holds more than one executable — a launcher, a \
    configuration tool, a crash reporter, sometimes a prerequisite installer. \
    Decanter guesses, and the guess is marked, but you can overrule it.

    The second section runs a different executable once inside the same \
    prefix without changing the game — useful for a settings tool, or for the \
    redistributable installer many Unreal games ship in Extras/Redist.
    """

    static let markWorking = """
    Remember this setup as working.

    Decanter stores it against this game's profile — engine, architecture, \
    whether it plays video — so the next game of the same kind starts here \
    instead of making you try combinations by hand.
    """

    // MARK: Bottles

    static let generation = "How many times this Windows environment has been replaced with a clean one."

    static let bottleHealth = "Whether this Windows environment is usable, still setting itself up, or broken and needing a rebuild."

    static let recipes = "Extra Windows components installed into this environment, such as Visual C++ runtimes."

    static let orphanBottle = "No game uses this Windows environment any more. Cleaning up deletes it and reclaims the space."

    static let runtimePinned = """
    The Wine build this prefix uses, copied into Decanter's own store.

    Runtimes are pinned rather than borrowed from Homebrew: a cask upgrade or a deleted \
    upstream release cannot break an installed game. That is precisely how Whisky stopped \
    working.
    """
}

/// A small "?" that opens a popover. Used where a hover tooltip would be too
/// long to read comfortably.
/// Renders a runtime string as Markdown.
///
/// `Text("**bold**")` parses Markdown only because a *literal* becomes a
/// LocalizedStringKey. `Text(someString)` does not, and every explanation in
/// this app arrives as a stored constant — so the bold markers were being
/// printed as asterisks in every popover.
struct Markdown: View {
    let text: String
    var body: some View {
        Text(attributed)
    }
    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct InfoButton: View {
    let text: String
    var title: String? = nil
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("What is this?")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let title {
                        Text(title).font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Markdown(text: text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            // A popover inherits the environment of whatever it is anchored
            // to. Anchored to a `List` Section header — which is where the
            // Library one lives — that meant the header's own styling came
            // with it: secondary colour, upper-casing, and a single-line
            // limit. The Library help rendered washed out and truncated to
            // one line while every other popover in the app was fine, because
            // every other one hangs off an ordinary control.
            .foregroundStyle(.primary)
            .textCase(nil)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            // Narrower than the 340 it was, so it still fits beside a sidebar
            // pinned to the left edge of a small window, and capped in height
            // so a long entry scrolls instead of running off the screen.
            .frame(width: 320)
            .frame(maxHeight: 440)
        }
    }
}

/// Proper plurals. "1 failure(s)" is the sort of thing that makes an app feel
/// unfinished, and it was in every result message.
func plural(_ n: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
    "\(n) " + (n == 1 ? singular : (pluralForm ?? singular + "s"))
}
