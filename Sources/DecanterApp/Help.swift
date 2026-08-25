import SwiftUI
import DecanterKit

/// All explanatory copy in one place. Hover text should say what the control
/// does *and* when you'd reach for it — a tooltip that only restates the label
/// is worse than none.
enum Help {

    // MARK: Graphics backends

    static func backend(_ b: GraphicsBackend) -> String {
        switch b {
        case .dxvk:
            "Translates Direct3D 9/10/11 into Vulkan, which MoltenVK then runs on Metal. The best default: it is the most mature layer and handles the widest range of games. Start here."
        case .d3dmetal:
            "Apple's own translation — Direct3D 11/12 straight to Metal, no Vulkan in between. Usually the fastest for demanding DirectX 12 titles, but it only exists inside the Game Porting Toolkit runtime, which is built on an older Wine."
        case .wined3d:
            "Wine's built-in Direct3D, running on OpenGL. Slowest for 3D, but it needs no Vulkan and has the fewest moving parts. The right choice for 2D games and the thing to try when the others crash or show a black screen."
        }
    }

    static func whenToChoose(_ b: GraphicsBackend) -> String {
        switch b {
        case .dxvk:     "Best for: Unity, Godot, Unreal, and anything that already ran under Whisky, Proton or Steam Deck."
        case .d3dmetal: "Best for: modern DirectX 12 games that DXVK renders badly or refuses to start."
        case .wined3d:  "Best for: Ren'Py, RPG Maker and other 2D games — and as the fallback when a game shows a black screen."
        }
    }

    static let backendPicker = """
    Which layer translates the game's DirectX calls to Metal.

    Rule of thumb: leave it on DXVK. If the game crashes at startup or shows a black \
    screen, try WineD3D. If it is a modern DirectX 12 title that runs badly, move it to \
    the Game Porting Toolkit runtime and choose D3DMetal.

    Only backends the game's current runtime can actually provide are listed.
    """

    static let runtimePicker = """
    Which Wine build runs this game.

    Wine 11 is modern and has the newer WoW64, so it is the safer choice for 32-bit and \
    indie games. The Game Porting Toolkit is based on Wine 7.7 from 2022, but it is the \
    only runtime that offers D3DMetal.

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

    static let play = "Launch the game in its own isolated prefix."
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

    static let addGame = "Add a game from a folder or an .exe. Decanter inspects the binary, identifies the engine, and clones it a private prefix."

    static let inspectorToggle = "Show or hide the evidence pane, which explains how this game was configured."

    static let librarySection = """
    Your games, most recently played first.

    Right-click any of them for the quick path: play, troubleshoot launch, copy a problem     report, or open its Windows environment in Finder.

    You can also drop a game folder or .exe anywhere in this window to add it.
    """

    static let bottlesSection = """
    One isolated Windows environment per game.

    Each is cloned from a shared golden template using APFS copy-on-write, so creating one     is instant and costs almost no disk. Isolation being free is the point: no game can     break another by installing a conflicting dependency.

    Graphics backend and runtime are set here, because they are properties of the     environment rather than of the game.
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

    static let externaliseAll = "Move every game's saves out of their prefixes, so rebuilding a prefix can never destroy progress."

    static let protectedBadge = "This game's saves live outside its prefix. Rebuilding cannot lose them."

    static let restoreSnapshot = "Copy this snapshot's files back over the current saves, and merge its registry keys."

    static let savesSearch = "Search file paths across every game's saves at once — useful when you know the filename but not which game wrote it."

    // MARK: Troubleshooting

    static let troubleshootPane = """
    For when the game starts but looks wrong.

    A game that renders badly without crashing writes almost nothing to its log, which is     why there is never anything useful to send. Troubleshoot Launch turns on the graphics     chatter — Direct3D, DXGI, Vulkan, DXVK and MoltenVK all start reporting — and Copy     Problem Report bundles that together with your hardware, the chosen runtime and     backend, the detection evidence, and a screenshot of the window.

    The whole bundle goes on your clipboard, ready to paste.
    """

    static let troubleshootLaunch = """
    Launch with verbose graphics logging (WINEDEBUG=+d3d,+dxgi,+vulkan, DXVK log level     info, and an on-screen DXVK overlay showing the driver and API in use).

    Run this, reproduce the problem, then use Copy Problem Report while the game is still     on screen so the screenshot is included.
    """

    static let copyReport = """
    Collect everything needed to debug this and copy it to the clipboard.

    Includes: macOS and GPU details, runtime and backend actually in use, DXVK version,     detection evidence, an automatic diagnosis, every graphics-related log line, and the     tail of the log. If the game is on screen and permission allows, a screenshot of the     window is saved next to it.
    """

    static let graphicsAreBottleScoped = """
    Yes — the backend and runtime belong to the bottle, not the game.

    That is deliberate: DXVK is not a setting, it is a set of DLLs physically installed     inside the prefix. Since every game gets its own bottle, changing it here and changing     it on the game page are the same act — this is simply the other door into it.
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

    static let generation = "How many times this prefix has been rebuilt. Each re-derive starts a fresh generation."

    static let bottleHealth = "Whether this prefix is usable, still installing dependencies, or broken and in need of a rebuild."

    static let recipes = "Dependencies installed into this prefix beyond the base template, such as Visual C++ runtimes."

    static let orphanBottle = "No game points at this prefix any more. Cleaning up deletes it and reclaims the space."

    static let runtimePinned = """
    The Wine build this prefix uses, copied into Decanter's own store.

    Runtimes are pinned rather than borrowed from Homebrew: a cask upgrade or a deleted \
    upstream release cannot break an installed game. That is precisely how Whisky stopped \
    working.
    """
}

/// A small "?" that opens a popover. Used where a hover tooltip would be too
/// long to read comfortably.
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
            VStack(alignment: .leading, spacing: 8) {
                if let title { Text(title).font(.headline) }
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}
