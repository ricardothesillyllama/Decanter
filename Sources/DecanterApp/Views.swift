import SwiftUI
import DecanterKit
import UniformTypeIdentifiers

enum Selection: Hashable {
    case game(UUID)
    case saves
    case storage
    case setup
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Selection?
    // Off by default. It answers "why did Decanter choose this?", which only
    // matters once something has gone wrong — showing detection weights to
    // someone opening the app for the first time is noise.
    @State private var showInspector = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            Group {
                switch selection {
                case .game(let id):
                    if let g = model.games.first(where: { $0.id == id }) {
                        GameDetail(game: g, showInspector: $showInspector)
                    } else { EmptyState() }
                case .storage:
                    StorageView()
                case .setup:
                    SetupView()
                case .saves:
                    SavesView()
                case nil:
                    EmptyState()
                }
            }
            .frame(minWidth: 480, minHeight: 380)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { addGame() } label: { Label("Add Game", systemImage: "plus") }
                    .help(Help.addGame)
            }
            // Only a game has evidence to inspect. On Setup, Saves and
            // Windows Environments the button toggled an empty panel, which
            // reads as something being broken.
            ToolbarItem {
                if case .game = selection {
                    Button { showInspector.toggle() } label: {
                        Label("Details", systemImage: "sidebar.trailing")
                    }.help(Help.inspectorToggle)
                }
            }
        }
        .overlay(alignment: .bottom) { BusyBar() }
        .safeAreaInset(edge: .top, spacing: 0) { StaleBuildBanner() }
        // First run lands on the Setup page rather than raising a sheet over
        // it. A sheet taller than the window spills past its edges, and it put
        // the same content in two places — the page has to exist anyway,
        // because "what am I missing?" is asked again every time a game
        // misbehaves.
        .onAppear { if model.setupNeeded && selection == nil { selection = .setup } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add(path: url) } }
                }
            }
            return true
        }
        .tint(Palette.accent(scheme))
    }

    private func addGame() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a game folder or its .exe"
        if panel.runModal() == .OK, let url = panel.url { model.add(path: url) }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: Selection?

    /// The sidebar carries the only always-visible signal that something is
    /// missing, so it has to distinguish "not ready" from "works, but a game
    /// could be faster".
    private var setupSymbol: String {
        guard let r = model.readiness else { return "gearshape" }
        if !r.ready { return "exclamationmark.circle.fill" }
        return r.missingOptional.isEmpty ? "gearshape" : "gearshape.fill"
    }
    private var setupTint: Color {
        guard let r = model.readiness, !r.ready else { return .secondary }
        return Palette.danger
    }
    /// Ready is ready. An earlier version painted this amber while any
    /// optional piece was missing, so a Mac that runs games perfectly wore a
    /// warning for as long as the user declined to fetch three graphics layers
    /// they had no use for. The symbol above still distinguishes the two; a
    /// caution colour claims something is wrong, and nothing is.
    private func footerTint(_ h: Engine.Health) -> Color {
        guard let r = model.readiness else { return h.rosetta ? Palette.running : Palette.danger }
        return r.ready ? Palette.running : Palette.danger
    }
    @State private var pendingRemoval: Game?
    @State private var keepSaves = true

    var body: some View {
        List(selection: $selection) {
            Section {
                if model.games.isEmpty {
                    Text("No games yet").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(model.gamesByRecency) { g in
                    GameRow(game: g).tag(Selection.game(g.id))
                        .contextMenu {
                            Button("Play") { model.play(g) }
                                .disabled(model.running.contains(g.id))
                            Button("Troubleshoot") { model.troubleshoot(g) }
                                .disabled(model.running.contains(g.id))
                            Divider()
                            Button("Copy Problem Report") { model.makeReport(g) }
                            Button("Diagnose Last Failure") { model.diagnose(g) }
                            Divider()
                            Button("Reveal Prefix in Finder") { model.revealPrefix(g) }
                            Divider()
                            Button("Remove Game…", role: .destructive) { pendingRemoval = g }
                        }
                }
            } header: {
                HStack(spacing: 5) {
                    Text("Library")
                    InfoButton(text: Help.librarySection, title: "Library")
                }
            }

            Section {
                Label("All Saves", systemImage: "externaldrive.badge.checkmark")
                    .tag(Selection.saves)
                    .help(Help.savesPane)
            }

            Section {
                // One entry, not one per game. Each game's Windows environment
                // is already on its own page under Graphics; listing every
                // prefix again here was the same settings in two places, and
                // "bottle" is a word nobody arrives knowing.
                Label("Windows Environments", systemImage: "internaldrive")
                    .tag(Selection.storage)
                    .help(Help.bottlesSection)

                // Permanent, not a one-time modal. "What is installed and what
                // is missing" is a question people ask again every time a game
                // misbehaves, and a wizard you cannot reopen cannot answer it.
                Label {
                    Text("Setup")
                } icon: {
                    Image(systemName: setupSymbol)
                        .foregroundStyle(setupTint)
                }
                .tag(Selection.setup)
                .help(Help.setupPage)
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(pendingRemoval.map { "Remove \($0.name)?" } ?? "Remove game?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove, Keep Saves", role: .destructive) {
                if let g = pendingRemoval { model.remove(g, keepSaves: true) }
                pendingRemoval = nil
            }
            Button("Remove and Delete Saves", role: .destructive) {
                if let g = pendingRemoval { model.remove(g, keepSaves: false) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This deletes the game's Windows environment and forgets it.\n\nYour actual game files are never touched — they live outside the prefix, wherever you downloaded them.")
        }
        .safeAreaInset(edge: .bottom) {
            if let h = model.health {
                HStack(spacing: 6) {
                    // The dot and the words beside it are one signal, so they
                    // have to agree. It used to report Rosetta alone, which
                    // showed a green dot next to "Not ready yet".
                    StatusDot(color: footerTint(h))
                        .help(h.rosetta
                              ? "Rosetta 2 is present. Wine is an x86_64 program, so nothing here runs without it."
                              : "Rosetta 2 is missing — Wine cannot run at all until it is installed.")
                    Text(model.readiness?.headline
                         ?? (h.pinnedRuntimes.isEmpty ? "Not set up yet" : "Ready"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(Help.runtimePinned)
                    Spacer(minLength: 0)
                    Button("Setup") { selection = .setup }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial)
            }
        }
    }
}

struct GameRow: View {
    @EnvironmentObject var model: AppModel
    let game: Game

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: model.running.contains(game.id) ? Palette.running : .secondary.opacity(0.5),
                      pulsing: model.running.contains(game.id))
            VStack(alignment: .leading, spacing: 1) {
                Text(game.name).lineLimit(1)
                Text(game.detection.engine.label)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BottleRow: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    var owner: String {
        model.games.first { $0.bottleID == bottle.id }?.name ?? "orphan"
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2").imageScale(.small).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(owner).lineLimit(1)
                Text("gen \(bottle.generation) · \(bottle.backend.label)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}


/// Wine outlives the app that started it, so a crashed or timed-out launch can
/// leave a process spinning at full CPU indefinitely. macOS blames Decanter for
/// the battery drain even when Decanter is not running, and Force Quit does not
/// list these — so the app has to say it plainly.
struct StrayWineCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let strays = model.leakedWine
        let worst = strays.max { $0.cpu < $1.cpu }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.trianglebadge.exclamationmark")
                Text("\(strays.count) leftover Wine process\(strays.count == 1 ? "" : "es")")
                    .font(.headline)
            }
            if let w = worst, w.cpu >= 50 {
                Text("\(w.displayName) has been using \(Int(w.cpu))% CPU for \(w.elapsed).")
            } else {
                Text("Left running by an earlier session. They keep using power even when Decanter is closed.")
            }
            Text("They do not appear in Force Quit, because they are not applications.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("End Them") { model.reapWine() }.buttonStyle(.borderedProminent)
                Text("This also stops any game you are playing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ReactionNote(key: "reap")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }
}


/// BepInEx status. Worth its own card because a mod loader fails in a way
/// nothing else in the app can see: the game launches, draws nothing, and dies,
/// while the actual reason sits in a log next to the .exe.
struct ModsCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var showAllPlugins = false

    var body: some View {
        let st = model.mods[game.id] ?? ModInspector.Status()
        return VStack(alignment: .leading, spacing: 10) {
            // No title here: this card is always inside a section already
            // called Mods, and the word appeared twice, four lines apart.
            HStack(spacing: 6) {
                Image(systemName: st.loaderRan ? "checkmark.seal" : "clock")
                Text("BepInEx\(st.loaderVersion.map { " \($0)" } ?? "")")
                Text(st.loaderRan ? "has run" : "has not written a log yet")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text("\(st.plugins.count) plugin\(st.plugins.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            if let n = st.note {
                Text(n).font(.caption).foregroundStyle(.secondary)
            }

            if !st.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(st.errors.count == 1
                         ? "One mod did not load"
                         : "\(st.errors.count) mods did not load")
                        .font(.callout.weight(.medium))
                    ForEach(Array(st.errors.enumerated()), id: \.offset) { _, e in
                        Text(ModInspector.explain(e))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The game usually still runs — the mods that failed just will not be active.")
                        .font(.caption).foregroundStyle(.secondary)
                    // The exact wording is what you paste when asking for help.
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(st.errors.enumerated()), id: \.offset) { _, e in
                                Text(e).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        Text("Exact message").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            // Things the game itself said, which is not what the mods did. The
            // loader's console is often the only place a game's own complaints
            // are visible at all.
            ForEach(Array(st.notices.enumerated()), id: \.offset) { _, n in
                VStack(alignment: .leading, spacing: 4) {
                    Text(n.summary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup {
                        Text(n.evidence).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 5)
                    } label: {
                        Text("Exact message").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            }

            // Red text in the log that no mod is responsible for. Shown, and
            // deliberately not counted as a failure: the loader writes one of
            // these on every start for some games, and counting it made every
            // one of them look broken.
            if !st.benign.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(st.benign.count == 1
                         ? "One error in the log is not a mod's fault"
                         : "\(st.benign.count) errors in the log are not a mod's fault")
                        .font(.callout.weight(.medium))
                    ForEach(Array(st.benign.enumerated()), id: \.offset) { _, b in
                        Text(ModInspector.whyBenign(b))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(st.benign.enumerated()), id: \.offset) { _, b in
                                Text(b).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        Text("Exact message").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            }

            if !st.plugins.isEmpty {
                DisclosureGroup(isExpanded: $showAllPlugins) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(st.plugins) { p in
                            HStack {
                                Text(p.fileName).font(.system(.caption, design: .monospaced))
                                Spacer()
                                // ByteCountFormatter renders 0 as "Zero KB",
                                // which reads as a bug rather than as a fact
                                // about the file. An empty plugin is a real
                                // thing to notice, so it says so.
                                Text(p.bytes == 0 ? "empty"
                                     : ByteCountFormatter.string(fromByteCount: Int64(p.bytes),
                                                                 countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(p.bytes == 0 ? Palette.caution : .secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Installed plugins").font(.callout)
                }
            }

            HStack(spacing: 8) {
                if st.pluginsDir != nil {
                    Button("Reveal Plugins") { model.revealPluginsFolder(game) }
                }
                if st.logPath != nil {
                    Button("Open Loader Log") { model.openLoaderLog(game) }
                }
            }
        }
    }
}


/// A button that shows what it is doing and what it did.
///
/// The old maintenance row was six bare buttons that went quietly disabled
/// while something ran: no indication of which one you pressed, no result, and
/// any error vanished the moment the next thing happened. Each action now owns
/// its progress state and carries a line saying what it is for, because a verb
/// alone ("Re-inspect") does not tell you when to reach for it.
struct ActionButton: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let systemImage: String
    let key: String
    let blurb: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        let mine = model.isRunning(key)
        let otherBusy = model.busy != nil && !mine
        // What happened last time this control was pressed, said here rather
        // than at the bottom of the page. The activity list answers "what has
        // been done"; that is a different question from "did the thing I just
        // clicked work", and it was answering the second one from six inches
        // away.
        let result = mine ? nil : model.reaction(key)
        return Button(role: role, action: action) {
            HStack(alignment: .top, spacing: 9) {
                Group {
                    if mine {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else if let r = result {
                        Image(systemName: r.succeeded ? "checkmark.circle.fill"
                                                      : "exclamationmark.triangle.fill")
                            .imageScale(.medium)
                            .foregroundStyle(r.succeeded ? Palette.running : Palette.danger)
                    } else {
                        Image(systemName: systemImage).imageScale(.medium)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mine ? "\(title)…" : title).font(.callout.weight(.medium))
                    // The result replaces the blurb rather than sitting under
                    // it: the blurb says when to reach for this, which is no
                    // longer the question once it has been reached for.
                    if let r = result {
                        let fallback: String = r.succeeded ? "Done." : "It did not work."
                        let line: String = r.detail ?? fallback
                        let tint: Color = r.succeeded ? .secondary : Palette.danger
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(tint)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    } else {
                        Text(blurb).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill(result, running: mine)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(edge(result), lineWidth: 0.5))
        .opacity(otherBusy ? 0.45 : 1)
        .disabled(model.busy != nil)
        .animation(.easeInOut(duration: 0.15), value: mine)
        .animation(.easeInOut(duration: 0.2), value: result?.succeeded)
    }

    private func fill(_ r: AppModel.Reaction?, running: Bool) -> Color {
        guard let r else { return Color.primary.opacity(running ? 0.09 : 0.04) }
        return (r.succeeded ? Palette.running : Palette.danger).opacity(0.10)
    }

    private func edge(_ r: AppModel.Reaction?) -> Color {
        guard let r else { return Color.primary.opacity(0.08) }
        return r.succeeded ? Palette.running.opacity(0.35) : Palette.danger.opacity(0.40)
    }
}

/// This window is running a Decanter that is no longer the one installed.
///
/// Installing over a running app replaces the bundle and leaves the process
/// alone, so the old build keeps drawing the old interface for as long as the
/// window stays open — and closing the window does not end it. Nothing said so,
/// and the result was four releases' worth of screenshots reported against
/// builds that had already fixed what they showed.
///
/// Deliberately not offered as a "Restart Now" button. Relaunching would
/// discard whatever is in flight, and the app has no business quitting itself
/// on the strength of a version string.
struct StaleBuildBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let newer = model.newerVersionInstalled {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Decanter \(newer) is installed. This window is still running \(Build.version).")
                    .font(.callout)
                Text("Quit and reopen — closing the window is not enough.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.caution.opacity(0.16))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.caution.opacity(0.35)).frame(height: 0.5)
            }
        }
    }
}

/// What to do about this game's setup — the whole of it, in one place.
///
/// This replaced three cards that appeared together: a warning that the game
/// was not known to run here, an offer to go back to the setup it last worked
/// on, and a recommendation to try something else. Each was drawn by a
/// different view from a different source, and on a game that had been moved
/// around they all appeared at once, saying the same thing three ways and
/// occasionally disagreeing about it. Three ways to say one thing is not three
/// times the help — it is a reader deciding which card to believe.
///
/// The decision itself is `Engine.advice(for:)`. This draws it and decides
/// nothing.
struct SetupCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let game: Game
    let advice: Engine.SetupAdvice

    private var tint: Color {
        switch advice.kind {
        case .stuck:    Palette.caution
        case .goBack:   Palette.running
        default:        Palette.accent(scheme)
        }
    }

    private var symbol: String {
        switch advice.kind {
        case .stuck:    "exclamationmark.octagon.fill"
        case .goBack:   "clock.arrow.circlepath"
        default:        "lightbulb.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(advice.headline).font(.headline)
                FactChip(text: advice.provenance.label)
                    .help(advice.provenance.detail)
                Spacer(minLength: 8)
                if let label = advice.actionLabel {
                    Button(label) {
                        if advice.isRestore { model.restoreKnownGood(game) }
                        else { model.applyRecommendation(game) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.busy != nil)
                    .help("Nothing is launched.")
                }
            }
            if !advice.explanation.isEmpty {
                Text(advice.explanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Why Decanter believes it. Below the answer, never instead of it.
            if !advice.evidence.isEmpty {
                DisclosureGroup("Why") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(advice.evidence.enumerated()), id: \.offset) { _, e in
                            Text("· \(e)").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)
                }
                .font(.caption)
            }
            if let c = advice.caution {
                Label(c, systemImage: advice.kind == .goBack ? "checkmark.shield" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(advice.kind == .goBack ? Color.secondary : Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ReactionNote(key: advice.isRestore ? "restore" : "recommend")
            if advice.kind == .stuck {
                Text("You can still press Play — this is what Decanter knows, not a rule it enforces.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
    }
}

/// Whether the setup this game is on has been vouched for, and — on a Mac that
/// holds a key — the means to vouch for it.
///
/// Two audiences, one control, and only one of them ever sees the second half.
/// The capability is simply having the key file, so there is no mode to enter
/// and nothing for anyone else to discover: with no key, this is a badge or it
/// is nothing at all.
struct EndorsementBadge: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var editing = false
    @State private var note = ""

    var body: some View {
        let endorsed = model.isEndorsed(game)
        let mayEndorse = model.canEndorse(game)
        if endorsed || mayEndorse {
            HStack(spacing: 6) {
                if endorsed {
                    Label("verified", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.running)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Palette.running.opacity(0.14)))
                        .help(model.endorsementNote(game)
                              ?? "Somebody ran this setup and signed for it. The signature proves a tier and carries no name.")
                }
                if mayEndorse {
                    Button(endorsed ? "Edit" : "Endorse") { note = model.endorsementNote(game) ?? ""; editing = true }
                        .controlSize(.small)
                        .disabled(model.busy != nil)
                        .help("Vouch for this setup. It travels with the knowledge base and carries no name.")
                }
            }
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Vouch for this setup").font(.headline)
                    Text("\(game.name) is on \(model.bottle(for: game).map { Help.plainName($0.backend) } ?? "this setup") graphics, and this Mac has seen it work. Signing says so to anyone who takes your knowledge.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("A line about what to expect (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    // The one free-text field that travels, and the only place
                    // a title could leave this Mac. Said plainly next to the
                    // box rather than buried in a document nobody opens.
                    Label("This text is signed and cannot be recalled once shared. Do not name the game in it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if model.isEndorsed(game) {
                            Button("Withdraw", role: .destructive) {
                                model.revokeEndorsement(game); editing = false
                            }
                            .help("Removes the vouching and the note. What was seen here stays recorded.")
                        }
                        Spacer()
                        Button("Cancel") { editing = false }
                        Button(model.isEndorsed(game) ? "Re-sign" : "Endorse") {
                            model.endorse(game, note: note); editing = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16).frame(width: 380)
            }
        }
    }
}

/// Settings that were only ever at the prompt, behind one door.
///
/// The charter's rule: one gated section, second click, behind an escape-hatch
/// sentence. The reason for the door is not secrecy — everything in here is
/// documented and reachable from `decanter` — it is that a switch someone does
/// not understand is worse than no switch, and the cost of showing it to the
/// wrong person is that they change something and cannot get back.
///
/// The interstitial is shown once and then never again. A warning that appears
/// every time is a warning people learn to click past, and then it is not there
/// when it matters.
struct AdvancedCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @AppStorage("advancedAcknowledged") private var acknowledged = false
    @State private var newDLL = ""
    @State private var newMode = "n,b"

    private var bottle: Bottle? { model.bottle(for: game) }

    var body: some View {
        if acknowledged { controls } else { doorway }
    }

    private var doorway: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("These change how the game starts", systemImage: "hand.raised")
                .font(.headline)
            Text("Everything below is a setting Decanter would otherwise choose for you. They exist because some games need one, and nothing on this page can work out which — you have to know, or be told by someone who does.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing here can lose a save or damage your Mac. It can stop a game starting, and Decanter will not always be able to say why.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("I understand — show them") { acknowledged = true }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Text("Asked once, not every time.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.caution.opacity(0.09)))
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Engine switches. The suggestions come from detection, so the list
            // is about this game rather than a catalogue of every flag.
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch switches").font(.callout.weight(.medium))
                let current = game.launchArguments ?? []
                Text(current.isEmpty ? "None. The game starts as it ships."
                                     : current.joined(separator: " "))
                    .font(.evidence).foregroundStyle(current.isEmpty ? .secondary : .primary)
                let suggestions = model.argumentSuggestions(for: game)
                if suggestions.isEmpty {
                    Text("Decanter knows no switches worth trying for this engine.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(suggestions, id: \.flag) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { current.contains(s.flag) },
                                set: { on in
                                    var next = current.filter { $0 != s.flag }
                                    if on { next.append(s.flag) }
                                    model.setLaunchArguments(game, next)
                                })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.flag).font(.evidence)
                                    Text(s.blurb).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.switch).controlSize(.mini)
                            .disabled(model.busy != nil)
                        }
                    }
                }
                if !current.isEmpty {
                    Button("Clear switches") { model.setLaunchArguments(game, []) }
                        .controlSize(.small).disabled(model.busy != nil)
                }
                ReactionNote(key: "args")
            }

            Divider()

            // Locale. Not really advanced for the person who needs it — a CJK
            // game crashing after its splash screen is a beginner's problem —
            // but it is meaningless to everyone else.
            VStack(alignment: .leading, spacing: 6) {
                Text("Language environment").font(.callout.weight(.medium))
                Text("Some Japanese, Chinese and Korean games crash just after the splash screen unless the environment says which language they are in.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(Engine.localePresets.keys.sorted(), id: \.self) { key in
                        Button(key.capitalized) { model.setLocalePreset(game, key) }
                            .controlSize(.small).disabled(model.busy != nil)
                            .help(Engine.localePresets[key]?.blurb ?? "")
                    }
                    if !game.envOverrides.isEmpty {
                        Button("Clear") { model.clearLocale(game) }
                            .controlSize(.small).disabled(model.busy != nil)
                    }
                }
                if !game.envOverrides.isEmpty {
                    Text(game.envOverrides.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  "))
                        .font(.evidence).foregroundStyle(.secondary)
                }
                ReactionNote(key: "locale")
            }

            Divider()

            // Which copy of a DLL Wine loads. Honoured by the launcher since it
            // existed and settable from nowhere — the same fault as a field
            // written twice and read never, with the halves swapped.
            VStack(alignment: .leading, spacing: 6) {
                Text("DLL overrides").font(.callout.weight(.medium))
                let proxies = model.modLoaderProxies(game)
                if !proxies.isEmpty {
                    Label("Mod loader proxy found: \(proxies.joined(separator: ", ")). Decanter already tells Wine to prefer \(proxies.count == 1 ? "it" : "them") at launch — you do not need to add \(proxies.count == 1 ? "it" : "them") here.",
                          systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("`n` loads the game's own copy, `b` loads Wine's built-in, `n,b` tries the game's first. Follow whatever a game's forum thread tells you.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(game.dllOverrides.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    HStack(spacing: 8) {
                        Text("\(entry.key) = \(entry.value)").font(.evidence)
                        Button("Remove") { model.setDLLOverride(game, dll: entry.key, mode: nil) }
                            .controlSize(.mini).disabled(model.busy != nil)
                    }
                }
                HStack(spacing: 6) {
                    TextField("winhttp", text: $newDLL).frame(width: 130)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $newMode) {
                        ForEach(["n", "b", "n,b"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 78)
                    Button("Add") {
                        model.setDLLOverride(game, dll: newDLL, mode: newMode)
                        newDLL = ""
                    }
                    .controlSize(.small)
                    .disabled(newDLL.trimmingCharacters(in: .whitespaces).isEmpty || model.busy != nil)
                }
                ReactionNote(key: "dll")
            }

            // The exact DXVK build. Only shown when the game is on DXVK and
            // there is more than one staged, because otherwise it is a picker
            // with one entry and no consequence.
            if bottle?.backend == .dxvk, model.stagedDXVKVersions.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vulkan graphics version").font(.callout.weight(.medium))
                    Text("DXVK 1.10.3 is the last version that works on macOS for most games; newer ones need Vulkan features MoltenVK does not have. Change this only if you know a game needs a different one.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("", selection: Binding(
                        get: { bottle?.dxvkVersion ?? model.stagedDXVKVersions.first ?? "" },
                        set: { model.setDXVKVersion(game, $0) })) {
                        ForEach(model.stagedDXVKVersions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                    .disabled(model.busy != nil)
                    ReactionNote(key: "dxvkVersion")
                }
            }
        }
    }
}

/// The result of a keyed action, for controls that are not `ActionButton`s.
///
/// Same rule as the buttons: what happened belongs beside what was pressed. A
/// success clears itself after a few seconds; a failure stays until something
/// else is pressed, because it is the thing still needing attention.
struct ReactionNote: View {
    @EnvironmentObject var model: AppModel
    let key: String

    var body: some View {
        if let r = model.reaction(key) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: r.succeeded ? "checkmark.circle.fill"
                                              : "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(r.succeeded ? Palette.running : Palette.danger)
                Text(r.detail ?? (r.succeeded ? "Done." : "It did not work."))
                    .font(.caption)
                    .foregroundStyle(r.succeeded ? Color.secondary : Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .transition(.opacity)
        }
    }
}

/// A running record of what was done and how it went.
///
/// Error recovery was the weak point: you could try four things, have the third
/// fail, and by the time the fourth finished there was nothing on screen saying
/// so. Entries survive navigation and keep full error text.
struct ActivityList: View {
    @EnvironmentObject var model: AppModel
    /// What to show. A game's page passes that game's history plus everything
    /// done to the Mac; this was global everywhere, so a report collected for
    /// one game sat on another game's page claiming to be about it.
    var entries: [AppModel.Activity]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(entries ?? model.activity) { a in
                HStack(alignment: .top, spacing: 8) {
                    icon(a)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.label.replacingOccurrences(of: "…", with: ""))
                                .font(.callout)
                            Text(a.started.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        if let d = a.detail {
                            Text(d)
                                .font(.caption)
                                .foregroundStyle(a.outcome == .failed ? Palette.danger : .secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func icon(_ a: AppModel.Activity) -> some View {
        switch a.outcome {
        case .running:   ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 14)
        case .succeeded: Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.running).imageScale(.small).frame(width: 14)
        case .failed:    Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.danger).imageScale(.small).frame(width: 14)
        }
    }
}

/// A collapsible section. Everything that is not "what is this and how do I
/// play it" lives inside one of these.
///
/// The game page used to show graphics settings, six maintenance buttons, mod
/// status and two paragraphs of prose all at once. For someone who has never
/// heard of Wine that reads as a control panel with no obvious entry point, so
/// the default is now closed and the primary path is one sentence and one
/// button. Sections open themselves when there is something wrong.
struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil
    var startsOpen = false
    @ViewBuilder var content: Content
    @State private var expanded: Bool?

    var body: some View {
        let isOpen = Binding(get: { expanded ?? startsOpen },
                             set: { expanded = $0 })
        return DisclosureGroup(isExpanded: isOpen) {
            content.padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage).imageScale(.medium).foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title).font(.headline)
                if let subtitle, !isOpen.wrappedValue {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}


/// Optional Windows pieces a game may demand by name.
///
/// Wine ships most of what games need, so this is deliberately not run by
/// default — installing everything "just in case" is how prefixes rot. It is
/// here because a game that says "MSVCP140.dll is missing" gives the user no
/// route forward otherwise.
struct ComponentsCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game

    struct Item: Identifiable {
        let id: String
        let title: String
        let blurb: String
        let verbs: [String]
    }

    static let items: [Item] = [
        .init(id: "vcrun", title: "Visual C++ runtime",
              blurb: "The usual answer when a game names a missing MSVC file.",
              verbs: ["vcrun"]),
        .init(id: "media", title: "Video and audio codecs",
              blurb: "For games with cutscenes, or with silent audio.",
              verbs: ["media"]),
        .init(id: "d3dcompiler", title: "Shader compiler",
              blurb: "Some Unity and Unreal games expect this to exist.",
              verbs: ["d3dcompiler"]),
        .init(id: "dotnet", title: ".NET Framework",
              blurb: "Slow to install and rarely needed. Try the others first.",
              verbs: ["dotnet"]),
    ]

    /// How many of the four are in this game's environment. Read by the
    /// section header so a closed section still says what is inside it — a
    /// collapsed door with no summary is a door people open to find out
    /// nothing has changed.
    static func installedCount(for game: Game, model: AppModel) -> Int {
        let applied = Set(model.bottle(for: game)?.appliedRecipes ?? [])
        return items.filter { $0.verbs.allSatisfy(applied.contains) }.count
    }

    var body: some View {
        let applied = Set(model.bottle(for: game)?.appliedRecipes ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            Text("Wine already provides most of what games need. Add these only when a game asks for one by name — installing everything is how a Windows environment goes wrong.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.componentToolingReady {
                Label("winetricks is not available, so these cannot be installed.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Palette.caution)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Self.items) { item in
                    let done = item.verbs.allSatisfy { applied.contains($0) }
                    ActionButton(title: done ? "\(item.title) ✓" : item.title,
                                 systemImage: done ? "checkmark.circle" : "shippingbox",
                                 key: "components",
                                 blurb: item.blurb) {
                        model.installComponents(game, item.verbs, label: item.title)
                    }
                    .disabled(!model.componentToolingReady || done)
                    .opacity(done ? 0.6 : 1)
                }
            }

            Text("These are downloaded from their publishers by winetricks. Everything else in Decanter works offline.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}



// MARK: - Game detail

struct GameDetail: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @Binding var showInspector: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var importing = false
    @State private var confirmRebuild = false

    var bottle: Bottle? { model.bottle(for: game) }
    var isRunning: Bool { model.running.contains(game.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                // Problems surface themselves. Everything else waits to be asked.
                // One card, one decision. This used to be three — a warning,
                // an offer to go back, and a recommendation — drawn from three
                // sources, stacked, all about the same question and free to
                // disagree with each other in front of the reader.
                // One card, the most urgent one. Five could apply at once —
                // a setup recommendation, stray Wine processes, a diagnosis,
                // an unanswered verdict and an unsound environment — and they
                // stacked, all about the same game, free to contradict each
                // other in front of the reader. That is the same fault 0.6.3
                // fixed inside the setup advice itself, one level up: three
                // cards from three sources became one decision. The others are
                // not lost; they come back as soon as this one is resolved,
                // which is also the order they should be dealt with in.
                topProblem

                // Three sections, grouped by when somebody needs them rather
                // than by what they are. There were five, all the same visual
                // weight, so nothing was primary and the whole page read as
                // homework: Graphics, Mods, Saves & Maintenance, Windows
                // Components, Advanced. Graphics and Windows Components are
                // both "how this game is set up" and were two doors; the
                // repair tools were filed under Saves, which is where nobody
                // looks when a game will not start.
                DetailSection(title: "How this game is set up", systemImage: "square.stack.3d.up",
                              subtitle: setupSubtitle) {
                    VStack(alignment: .leading, spacing: 22) {
                        graphics
                        ComponentsCard(game: game)
                    }
                }
                if model.mods[game.id]?.installed == true {
                    DetailSection(title: "Mods", systemImage: "wrench.and.screwdriver",
                                  subtitle: modsSubtitle,
                                  startsOpen: !(model.mods[game.id]?.errors.isEmpty ?? true)) {
                        ModsCard(game: game)
                    }
                }
                // Opens itself when there is something to open it for. Every
                // control in here is a repair, and a repair is only ever
                // wanted at one moment.
                DetailSection(title: "If something is wrong", systemImage: "stethoscope",
                              subtitle: "Troubleshoot, diagnose, rebuild, import saves",
                              startsOpen: hasProblem) {
                    VStack(alignment: .leading, spacing: 18) { maintenance; troubleshoot }
                }
                DetailSection(title: "Advanced", systemImage: "slider.horizontal.3",
                              subtitle: "Launch switches, language, graphics version") {
                    AdvancedCard(game: game)
                }
                let mine = model.activity(for: game.id)
                if !mine.isEmpty {
                    DetailSection(title: "Activity", systemImage: "clock.arrow.circlepath",
                                  subtitle: mine.first { $0.outcome != .running }?.detail) {
                        ActivityList(entries: mine)
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(game.name)
        .inspector(isPresented: $showInspector) {
            EvidenceInspector(game: game)
                .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.importSaves(game, from: url) }
        }

        .confirmationDialog("Start this game's Windows over?", isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Start Over", role: .destructive) { model.rederive(game) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Decanter never repairs a broken Windows environment — it replaces it with a clean one, which takes about half a second.\n\nAnything the game stored inside is erased, including saves that are not protected yet. Protect them first from the Saves page.")
        }
    }

    /// The single most urgent thing about this game, or nothing.
    ///
    /// Ranked by what has to be dealt with first rather than by what is most
    /// alarming. An unanswered verdict comes before everything: what happened
    /// last time is the fact most likely to change what should happen next,
    /// and every recommendation below it is formed without knowing the answer.
    /// A diagnosis of a real failure comes next, because it describes
    /// something that already went wrong rather than something that might. An
    /// unsound environment beats a setup recommendation, because a
    /// recommendation about graphics is beside the point in a Windows
    /// environment that is missing pieces. Stray Wine processes are last: they
    /// are a nuisance, not a cause.
    /// Everything currently true of this game. The order they are dealt with
    /// in is `Concern`'s, in the kit, where it can be tested.
    private var concerns: Set<Concern> {
        var out: Set<Concern> = []
        if model.pendingVerdict?.gameID == game.id { out.insert(.unansweredVerdict) }
        if !(model.diagnosis[game.id]?.isEmpty ?? true) { out.insert(.diagnosis) }
        if let id = bottle?.runtimeID, let h = model.runtimeSoundness[id], !h.isSound {
            out.insert(.unsoundEnvironment)
        }
        if model.advice(for: game)?.kind != .settled, model.advice(for: game) != nil {
            out.insert(.setupAdvice)
        }
        if !model.leakedWine.isEmpty { out.insert(.strayProcesses) }
        return out
    }

    @ViewBuilder private var topProblem: some View {
        switch Concern.mostUrgent(of: concerns) {
        case .unansweredVerdict:
            if let p = model.pendingVerdict { VerdictCard(pending: p) }
        case .diagnosis:
            if let rep = model.diagnosis[game.id] { DiagnosisCard(report: rep) }
        case .unsoundEnvironment:
            if let id = bottle?.runtimeID, let health = model.runtimeSoundness[id] {
                EnvironmentHealthCard(runtimeID: id, report: health, game: game)
            }
        case .setupAdvice:
            if let a = model.advice(for: game) { SetupCard(game: game, advice: a) }
        case .strayProcesses:
            StrayWineCard()
        case nil:
            EmptyView()
        }
    }

    /// Whether the repair section should open itself, so the tools are in
    /// front of somebody at the one moment they are wanted.
    private var hasProblem: Bool {
        if let c = Concern.mostUrgent(of: concerns), c.callsForRepairTools { return true }
        return model.blocker(for: game) != nil
    }

    /// What the setup section says while closed: the two facts inside it.
    private var setupSubtitle: String? {
        guard let b = bottle else { return nil }
        let installed = ComponentsCard.installedCount(for: game, model: model)
        let graphics = Help.plainName(b.backend)
        return installed == 0 ? graphics
             : "\(graphics) · \(plural(installed, "component")) added"
    }

    /// Collapsed summary for the Mods section: a failure is the only thing
    /// worth pulling someone's attention to.
    private var modsSubtitle: String? {
        guard let st = model.mods[game.id], st.installed else { return nil }
        if !st.errors.isEmpty { return plural(st.errors.count, "mod failed", "mods failed") }
        return plural(st.plugins.count, "plugin")
    }

    private var header: some View {
        let problem = !(model.diagnosis[game.id]?.isEmpty ?? true)
        let onRec = model.isOnRecommended(game)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(game.name).font(.system(size: 30, weight: .semibold)).lineLimit(2)
                // Beside the name, because it is a fact about this game's
                // setup rather than a step in getting it running. It had no
                // home in the app at all: the strongest thing Decanter can say
                // about a setup could only be read at the prompt.
                EndorsementBadge(game: game)
            }

            // One sentence saying where this game stands, before any control.
            HStack(spacing: 7) {
                let blocked = model.blocker(for: game) != nil
                StatusDot(color: isRunning ? Palette.running
                            : blocked ? Palette.caution
                            : problem ? Palette.danger
                            : onRec ? Palette.running : Palette.caution,
                          pulsing: isRunning)
                Text(Help.status(running: isRunning, onRecommended: onRec, hasProblem: problem,
                                 knownUnsupported: blocked))
                    .font(.title3)
                if let d = game.lastPlayed, !isRunning {
                    Text("· last played \(d.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.play(game)
                } label: {
                    Label(isRunning ? "Running" : "Play", systemImage: isRunning ? "waveform" : "play.fill")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRunning || model.busy != nil)
                .help(isRunning ? Help.running : Help.play)

                if isRunning {
                    Button {
                        model.stop(game)
                    } label: {
                        Label(model.isRunning("stop") ? "Stopping" : "Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                    .disabled(model.busy != nil)
                    .help(Help.stop)
                }
            }

            // What the game *is* — useful, but not the first thing anyone needs.
            HStack(spacing: 6) {
                FactChip(text: game.detection.engine.label, icon: "cube.transparent")
                    .help("The game engine Decanter identified from the files next to the executable.")
                FactChip(text: game.detection.bitness.label)
                    .help(Help.architecture)
                if game.detection.modded {
                    FactChip(text: "modded", icon: "wrench.and.screwdriver")
                        .help("A mod loader sits next to this game. Its mods load through winhttp.dll.")
                }
            }
            executablePicker
        }
    }

    private var graphics: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let b = bottle {
                // A row per option rather than a segmented control, because
                // the recommendation is no longer part of the name. The old
                // labels — Standard, Compatibility — each smuggled a claim
                // about which works with more games, and "Compatibility" sent
                // stuck people to the slowest one. Compatibility is per-game,
                // so the recommendation is a badge beside the name and the
                // name only says what the thing is.
                VStack(spacing: 0) {
                    ForEach(availableBackends, id: \.self) { bk in
                        BackendRow(backend: bk,
                                   selected: b.backend == bk,
                                   recommended: bk == model.recommendation(for: game)?.backend,
                                   disabled: model.busy != nil) {
                            model.setBackend(game, bk)
                        }
                        if bk != availableBackends.last { Divider().padding(.leading, 38) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.hairline))
                .frame(maxWidth: 460)

                HStack(spacing: 6) {
                    Text("Decanter marks the option it expects to work. There is no setting here that is best for every game.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    InfoButton(text: Help.backendPicker, title: "Graphics explained")
                }

                // What is missing from the list, and why. The picker showed
                // only what this build provides and said nothing about the
                // rest, so "where is Metal graphics?" had no answer in the app
                // — while `decanter bench` had measured one and written it
                // down. These are not choices, so they are not rows: they are
                // the reason a row is not there.
                let absent = model.unavailableBackends(for: game)
                if !absent.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Not offered on this Wine build")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(absent, id: \.backend) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "minus.circle")
                                    .imageScale(.small).foregroundStyle(.tertiary)
                                Text("**\(Help.plainName(item.backend)) graphics** — \(item.reason)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                }

                if b.backend == .dxvk && !dxvkReallyPresent {
                    Label("This game is set to Vulkan graphics, but its Windows environment has Wine's built-in graphics instead. Rebuild it under Saves & Maintenance.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Everything below is for people who already know what it means.
                // Deliberately not promoted to the main surface. Someone who
                // does not know what Wine 11 is has no use for the choice, and
                // putting it in front of them costs attention that Play and
                // Graphics need. Someone who does know goes looking — so it is
                // one click away, and it keeps the real names rather than being
                // translated into something they would have to translate back.
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.pinnedRuntimes.count > 1 {
                            HStack(spacing: 6) {
                                // "Runs on", not "Engine" — this app already
                                // uses Engine for Unity and Unreal, and using
                                // one word for two things in one window is how
                                // a picker gets misread as a game setting.
                                Text("Runs on").font(.callout)
                                Picker("", selection: Binding(get: { b.runtimeID },
                                                              set: { model.setRuntime(game, $0) })) {
                                    ForEach(model.pinnedRuntimes) { rt in
                                        Text(runtimeLabel(rt)).tag(rt.id)
                                    }
                                }
                                .labelsHidden().frame(width: 240)
                                .disabled(model.busy != nil)
                                InfoButton(text: Help.runtimeWhich, title: "What does it run on?")
                            }
                            if let rt = model.pinnedRuntimes.first(where: { $0.id == b.runtimeID }) {
                                Text(Help.runtimeOneLiner(rt.kind))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Graphics layer", value: Help.backendTechnicalName(b.backend))
                            LabeledContent("Runs on", value: b.runtimeID)
                            LabeledContent("Prefix", value: b.prefixPath.lastPathComponent)
                                .textSelection(.enabled)
                            Button("Reveal in Finder") { model.revealPrefix(game) }
                                .controlSize(.small).padding(.top, 4)
                        }
                        .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } label: {
                    // Same weight as every other section header. It was set in
                    // small secondary text, which read as a footnote rather
                    // than as a place to go — hiding the one control someone
                    // who does know Wine actually came for.
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .imageScale(.medium).foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("Advanced").font(.headline)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }

    /// Game folders routinely hold launchers, config tools and prerequisite
    /// installers beside the real game. The automatic pick is a guess, so it
    /// has to be overridable — and the other executables are often worth
    /// running once in the same prefix.
    @ViewBuilder private var executablePicker: some View {
        let state = model.executableState(game)
        let choices: [Detector.ExecutableChoice] = if case .loaded(let c) = state { c } else { [] }
        // "unknown" must never render as "only executable": we have not looked.
        let scanning = { if case .loaded = state { false } else { true } }()
        HStack(spacing: 6) {
            Image(systemName: "doc.badge.gearshape").imageScale(.small).foregroundStyle(.secondary)
            Text(game.exePath.lastPathComponent)
                .font(.evidence).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)

            // Always say something. Rendering nothing while the scan was in
            // flight — or after it was invalidated — made the control look like
            // it came and went at random.
            if scanning {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("checking folder…").font(.caption).foregroundStyle(.tertiary)
            } else if choices.count > 1 {
                Menu("Change") {
                    // Only plausible games at the top level. A large install
                    // can hold thirty executables and listing them all three
                    // times — launch, run once, add — made the menu unusable
                    // exactly when there were most to choose between.
                    Section("Launch this game with") {
                        ForEach(choices.filter { $0.kind == .game }) { c in
                            Button {
                                model.setExecutable(game, c.url)
                            } label: {
                                Text(c.url == game.exePath ? "\(c.relativePath)  ✓" : c.relativePath)
                            }
                        }
                    }
                    let others = choices.filter { $0.kind != .game }
                    if !others.isEmpty {
                        Menu("Other programs here (\(others.count))") {
                            ForEach(others) { c in
                                Button {
                                    model.setExecutable(game, c.url)
                                } label: {
                                    Text(c.note.map { "\(c.relativePath) — \($0)" } ?? c.relativePath)
                                }
                            }
                        }
                    }
                    Divider()
                    Menu("Run once, without changing the game") {
                        ForEach(choices.filter { $0.url != game.exePath }) { c in
                            Button(c.note.map { "\(c.relativePath) — \($0)" } ?? c.relativePath) {
                                model.runOther(game, c.url)
                            }
                        }
                    }
                    // Decanter cannot tell a second game from a config tool, so
                    // this is offered rather than detected.
                    Menu("Add another game from this folder") {
                        ForEach(choices.filter { $0.url != game.exePath }) { c in
                            Button(c.relativePath) { model.addAsSeparateGame(c.url) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Help.executablePicker)
                .disabled(model.busy != nil)
                Text(choices.filter { $0.kind == .game }.count > 1
                     ? "\(choices.filter { $0.kind == .game }.count) could be the game"
                     : "\(choices.count) programs here")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("only executable in this folder")
                    .font(.caption).foregroundStyle(.tertiary)
                    .help(Help.executablePicker)
            }
            Spacer()
        }
        // Keyed on the game: SwiftUI reuses this view when you pick a
        // different one in the sidebar, and a plain .task would not re-run —
        // leaving the new game's picker stuck saying "checking folder…".
        .task(id: game.id) { model.loadExecutables(game) }
    }


    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                // One control where there were two. "Test Launch" checked
                // without launching; "Troubleshoot Launch" launched with a
                // verbose log. Four words apart, opposite behaviours. This
                // checks first and stops if the check names something that
                // would prevent the game starting — otherwise it starts it
                // with the log running, because at that point the only way to
                // learn more is to watch it happen. The blurb says a window
                // may appear, rather than leaving that to be discovered.
                ActionButton(title: "Troubleshoot", systemImage: "checkmark.shield",
                             key: "check",
                             blurb: "Checks first. If nothing would stop it, starts the game with full logging.") {
                    model.troubleshoot(game)
                }
                ActionButton(title: "Import Saves", systemImage: "square.and.arrow.down",
                             key: "import",
                             blurb: "Bring in saves from a backup, or from another copy of the game.") { importing = true }
                ActionButton(title: "Rebuild Environment", systemImage: "arrow.triangle.2.circlepath",
                             key: "rebuild",
                             blurb: "Start this game's Windows over from clean. Saves are kept.") { confirmRebuild = true }
                ActionButton(title: "Diagnose", systemImage: "stethoscope",
                             key: "diagnose",
                             blurb: "Look at what happened the last time this game ran.") { model.diagnose(game) }
                ActionButton(title: "Re-inspect", systemImage: "magnifyingglass",
                             key: "redetect",
                             blurb: "Check the game again after installing mods or an update.") { model.redetect(game) }
                // The blurb carries the diagnosis when there is one. An action
                // with no diagnosis beside it is a button pressed on a hunch,
                // which then reports afterwards that it did nothing.
                ActionButton(title: "Fix Fonts", systemImage: "textformat",
                             key: "fonts",
                             blurb: model.fontStatus[game.id]
                                 ?? "For when text is missing but the buttons are the right size.") {
                    model.fixFonts(from: game)
                }
            }
        }
    }

    private var troubleshoot: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Something looks wrong?").font(.headline)
                InfoButton(text: Help.troubleshootPane, title: "Reporting a graphics problem")
            }
            Text("If the game runs but renders badly, a normal log proves nothing. Launch it in troubleshoot mode, then collect a report while it is on screen.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    model.play(game, verbose: true)
                } label: {
                    Label("Troubleshoot Launch", systemImage: "ladybug")
                }
                .help(Help.troubleshootLaunch)
                .disabled(isRunning || model.busy != nil)

                Button {
                    model.makeReport(game)
                } label: {
                    Label("Copy Problem Report", systemImage: "doc.on.clipboard")
                }
                .help(Help.copyReport)
                .disabled(model.busy != nil)

                if model.lastReport != nil {
                    Button("Show Files") { model.revealReport() }
                        .help("Open the report and screenshot in Finder.")
                }
            }

            if let note = model.reportNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Palette.running)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("If the problem is visual, take a screenshot yourself: Command-Shift-4, Space, click the window — then attach it to the report.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dxvkReallyPresent: Bool {
        guard let b = bottle else { return false }
        return FileManager.default.fileExists(
            atPath: b.prefixPath.appending(path: "drive_c/windows/system32/d3d11.dll.wine-builtin").path)
    }

    private func runtimeLabel(_ rt: RuntimeSpec) -> String {
        switch rt.kind {
        case .wine: "Wine \(rt.version) — newest"
        case .gptk: "Game Porting Toolkit (Wine \(rt.version))"
        }
    }

    private var availableBackends: [GraphicsBackend] {
        guard let b = bottle,
              let rt = model.pinnedRuntimes.first(where: { $0.id == b.runtimeID })
        else { return [.dxvk, .wined3d] }
        return rt.backends
    }
}

struct DiagnosisCard: View {
    let report: Diagnostics.Report
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This game exited early", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(Palette.caution)
            ForEach(Array(report.findings.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.summary).font(.callout)
                    Text(f.suggestion).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = report.logPath {
                Text(p.path).font(.evidence).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.caution.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.caution.opacity(0.30), lineWidth: 0.5))
    }
}

/// The one thing Decanter could not see for itself.
///
/// Shown only after a launch it refused to judge. A clean launch is recorded
/// and asks nothing — a prompt that appears when the answer is already obvious
/// is a prompt people learn to dismiss without reading, and then it is not
/// there when it matters.
struct VerdictCard: View {
    @EnvironmentObject var model: AppModel
    let pending: Verdict.Pending
    @Environment(\.colorScheme) private var scheme
    @State private var why: Knowledge.Failure = .unspecified
    @State private var instead: Verdict.SwitchReason = .unstated
    @State private var saying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Did that work?", systemImage: "questionmark.circle.fill")
                .font(.headline).foregroundStyle(Palette.accent(scheme))
            Text(pending.question)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if saying {
                // Only asked once the answer is "no". Someone whose game worked
                // should never be made to classify anything.
                Picker("What happened", selection: $why) {
                    ForEach(Knowledge.Failure.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.menu).controlSize(.small)
                if let q = pending.switchQuestion {
                    Text(q).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Why this setup", selection: $instead) {
                        ForEach(Verdict.SwitchReason.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.menu).controlSize(.small)
                }
                HStack {
                    Button("Record This") {
                        model.answerVerdict(worked: false, failure: why,
                                            reason: pending.switchQuestion == nil ? nil : instead)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { saying = false }.controlSize(.small)
                }
            } else {
                HStack {
                    Button("It Worked") { model.answerVerdict(worked: true) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("It Did Not") { saying = true }.controlSize(.small)
                    Spacer()
                    // Not answering has to be as easy as answering, or the
                    // answers stop being worth anything.
                    Button("Skip") { model.skipVerdict() }
                        .buttonStyle(.plain).controlSize(.small)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
    }
}


/// What a Wine build is missing, and what can be done about it here.
///
/// Named for the consequence, never for the libraries: "video will not play"
/// is something to decide about, and a list of dylib names is not.
struct EnvironmentHealthCard: View {
    @EnvironmentObject var model: AppModel
    let runtimeID: String
    let report: RuntimeAudit.Report
    /// Who asked. The repair is to a runtime several games may share; the
    /// report of it belongs on the page it was started from.
    var game: Game? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Something is missing from this game's Windows", systemImage: "puzzlepiece.extension.fill")
                .font(.headline).foregroundStyle(Palette.caution)
            ForEach(Array(report.consequences.enumerated()), id: \.offset) { _, c in
                Text(c).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Fix This") { model.repairRuntime(runtimeID, from: game) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.busy != nil)
                    .help("Copies the missing pieces from builds already on this Mac. Nothing is downloaded, and it can be undone.")
                Text("Nothing is downloaded — the pieces come from builds already here.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ReactionNote(key: "repair")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.caution.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.caution.opacity(0.30), lineWidth: 0.5))
    }
}

// MARK: - Inspector


/// Disk and housekeeping for every game's Windows environment.
///
/// This replaced a per-game "Bottles" list. Each game's environment is already
/// configured on its own page, so listing them all again showed the same
/// settings twice — and "bottle" is a word nobody arrives knowing.
struct StorageView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Windows Environments").font(.largeTitle).bold()
                    Text("Every game runs inside its own private copy of Windows. They are cloned, so a second copy costs almost no disk — and no game can see another's files.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.games) { g in
                        if let b = model.bottle(for: g) {
                            HStack(spacing: 10) {
                                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.name).font(.callout.weight(.medium))
                                    Text("\(Help.plainName(b.backend)) graphics · \(b.generation <= 1 ? "never rebuilt" : "rebuilt \(b.generation - 1) time\(b.generation == 2 ? "" : "s")")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show Files") { model.revealPrefix(g) }
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Housekeeping").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                        GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ActionButton(title: "Clean Up Leftovers", systemImage: "trash",
                                     key: "gc",
                                     blurb: "Delete Windows environments left behind by games you removed.") { model.gc() }
                        // `decanter saves gc` did this and the app did not, so
                        // snapshots accumulated with nothing on any screen
                        // offering to stop them.
                        ActionButton(title: "Prune Old Snapshots", systemImage: "clock.badge.xmark",
                                     key: "savesGC",
                                     blurb: "Keep the recent save snapshots for each game and delete the rest.") { model.pruneSnapshots() }
                    }
                    .frame(maxWidth: 660)
                }

                if !model.globalActivity.isEmpty {
                    DetailSection(title: "Activity", systemImage: "clock.arrow.circlepath",
                                  subtitle: model.globalActivity.first { $0.outcome != .running }?.detail) {
                        ActivityList(entries: model.globalActivity)
                    }
                    .frame(maxWidth: 640)
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Windows Environments")
    }
}

struct EvidenceInspector: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    var body: some View {
        Form {
            // Status first. The pane used to open with detection weights, which
            // answer a question nobody has yet — "how is this game doing right
            // now" is the one they do have.
            // What this game is, right now, in the order somebody wants it:
            // what it is running on, whether that has been vouched for, whether
            // its environment is sound, and what state its saves are in. The
            // pane used to open with detection weights — the answer to "how did
            // Decanter identify this?", asked once, ever — and led with
            // confidence to two decimal places, which is not a fact anyone acts
            // on. The thing it never said at all was which runtime and graphics
            // layer the game is actually on, and that is the first thing
            // anybody looks for.
            Section {
                LabeledContent("State") {
                    Text(model.running.contains(game.id) ? "Running" : "Not running")
                }
                if let b = model.bottle(for: game) {
                    LabeledContent("Graphics") {
                        Text(Help.plainName(b.backend)
                             + (b.backend == .dxvk ? (b.dxvkVersion.map { " \($0)" } ?? "") : ""))
                    }
                    .help(Help.backend(b.backend))
                    LabeledContent("Runs on", value: b.runtimeID)
                        .help("The Wine build this game's Windows environment was made from.")
                    LabeledContent("Environment") {
                        Text("\(b.health.label) · generation \(b.generation)")
                            .foregroundStyle(b.health == .healthy ? Color.primary : Palette.caution)
                    }
                    .help(Help.generation)
                }
                if model.isEndorsed(game) {
                    LabeledContent("Vouched for") {
                        Label("verified", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Palette.running).font(.callout)
                    }
                    .help(model.endorsementNote(game)
                          ?? "Somebody ran this setup and signed for it.")
                }
                if let st = model.mods[game.id], st.installed {
                    LabeledContent("Mods") {
                        Text(st.errors.isEmpty ? "\(st.plugins.count) loaded"
                             : "\(st.errors.count) failed")
                            .foregroundStyle(st.errors.isEmpty ? Color.primary : Palette.caution)
                    }
                }
                if let ov = model.saveOverview[game.id] {
                    LabeledContent("Saves") {
                        Text(ov.files == 0 ? "none yet"
                             : "\(plural(ov.files, "file")) · \(ByteCountFormatter.string(fromByteCount: Int64(ov.bytes), countStyle: .file))")
                    }
                    LabeledContent("Snapshots", value: "\(ov.snapshots)")
                        .help("Copies Decanter took before anything destructive.")
                    LabeledContent("Protected") {
                        Text(model.externalised.contains(game.id) ? "yes" : "not yet")
                            .foregroundStyle(model.externalised.contains(game.id)
                                             ? Palette.running : Palette.caution)
                            .font(.callout)
                    }
                    if !model.externalised.contains(game.id), ov.files > 0 {
                        Button("Protect Saves") { model.externaliseSaves(game) }
                            .controlSize(.small).disabled(model.busy != nil)
                    }
                }
                if let d = game.lastPlayed {
                    LabeledContent("Last played") {
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            } header: {
                Text("Right now")
            }
            Section {
                LabeledContent("Confidence", value: String(format: "%.2f", game.detection.confidence))
                    .help(Help.confidence)
                LabeledContent("Engine", value: game.detection.engine.label)
                    .help("Identified from the files sitting next to the executable.")
                LabeledContent("Architecture", value: game.detection.bitness.label)
                    .help(Help.architecture)
                if !game.detection.graphicsAPIs.isEmpty {
                    LabeledContent("Graphics") {
                        Text(game.detection.graphicsAPIs.joined(separator: ", ")).font(.evidence)
                    }
                    .help(Help.graphicsAPIs)
                }
            } header: {
                HStack(spacing: 5) { Text("Detection"); InfoButton(text: Help.confidence, title: "Confidence") }
            }

            Section {
                // Closed by default. It answers "why did Decanter decide
                // this?", which is worth having and is asked about once per
                // game — and it is long enough to push everything anybody looks
                // at regularly off the bottom of the pane.
                DisclosureGroup("How Decanter decided") {
                    ForEach(Array(game.detection.signals.enumerated()), id: \.offset) { _, sig in
                        HStack(alignment: .top, spacing: 6) {
                            Text(String(format: "%.2f", sig.weight))
                                .font(.evidence).foregroundStyle(.tertiary)
                            Text(sig.rule).font(.caption)
                        }
                        .help("Weight \(String(format: "%.2f", sig.weight)) — heavier evidence counted for more.")
                    }
                    Text(Help.inspectorPane)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            } header: {
                HStack(spacing: 5) { Text("Evidence"); InfoButton(text: Help.evidenceWeights, title: "Evidence weights") }
            }

            Section {
                ForEach(Array(game.scopes.enumerated()), id: \.offset) { _, sc in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(sc.letter.uppercased()):\(sc.readOnly ? "  read-only" : "")").font(.factLabel)
                        Text(sc.hostPath.path).font(.evidence).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    .help("Mapped as drive \(sc.letter.uppercased()): inside Windows.\n\(sc.hostPath.path)")
                }
                Text("No other part of your Mac is visible to this game.")
                    .font(.caption).foregroundStyle(.tertiary)
            } header: {
                HStack(spacing: 5) { Text("Allowed folders"); InfoButton(text: Help.allowedFolders, title: "Scoped access") }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Bottles

struct BottleDetail: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle

    var owner: Game? { model.games.first { $0.bottleID == bottle.id } }

    private func backendsFor(_ b: Bottle) -> [GraphicsBackend] {
        model.pinnedRuntimes.first { $0.id == b.runtimeID }?.backends ?? [.dxvk, .wined3d]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(owner?.name ?? "Orphaned bottle")
                    .font(.system(size: 26, weight: .semibold))
                HStack(spacing: 6) {
                    FactChip(text: "generation \(bottle.generation)").help(Help.generation)
                    FactChip(text: bottle.runtimeID, icon: "shippingbox").help(Help.runtimePinned)
                    FactChip(text: bottle.backend.label).help(Help.backend(bottle.backend))
                }
                GroupBox("Prefix") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bottle.prefixPath.path).font(.evidence).textSelection(.enabled)
                        Text("Health: \(bottle.health.label)").font(.caption).foregroundStyle(.secondary)
                            .help(Help.bottleHealth)
                        if !bottle.appliedRecipes.isEmpty {
                            Text("Recipes: \(bottle.appliedRecipes.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                                .help(Help.recipes)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let g = owner {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("Graphics settings live on the bottle").font(.callout).bold()
                                InfoButton(text: Help.graphicsAreBottleScoped, title: "Why bottle-scoped?")
                            }
                            Picker("Backend", selection: Binding(
                                get: { bottle.backend },
                                set: { model.setBackend(g, $0) })) {
                                ForEach(backendsFor(bottle), id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .help(Help.backendPicker)
                            Picker("Runtime", selection: Binding(
                                get: { bottle.runtimeID },
                                set: { model.setRuntime(g, $0) })) {
                                ForEach(model.pinnedRuntimes) { rt in Text(rt.id).tag(rt.id) }
                            }
                            .help(Help.runtimePicker)
                            Text(Help.backend(bottle.backend))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(model.busy != nil)
                }

                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([bottle.prefixPath])
                    }.help(Help.revealPrefix)
                    if owner == nil {
                        Button("Clean Up Orphans") { model.gc() }.help(Help.orphanBottle)
                    }
                }
                Text("A broken prefix is never repaired here — it is thrown away and re-derived from the golden template, which takes about half a second.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(owner?.name ?? "Bottle")
    }
}

// MARK: - Chrome

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "drop.degreesign")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text("Drop a game folder anywhere in this window")
                .font(.title3).foregroundStyle(.secondary)
            Text("Decanter inspects the binary, picks a runtime, and clones it a private prefix.")
                .font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BusyBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 6) {
            if let e = model.lastError {
                Label(e, systemImage: "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(Palette.danger)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .onTapGesture { model.lastError = nil }
            }
            if let b = model.busy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(b).font(.callout)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.18), value: model.busy)
        .animation(.easeInOut(duration: 0.18), value: model.lastError)
    }
}
